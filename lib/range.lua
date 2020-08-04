local ffi = require("ffi")
local inspect = require("inspect")

local C = ffi.C

local RANGE_NOT_SATISFIABLE = 416
local PARTIAL_CONTENT = 206

local _M = {
  VERSION = "0.0.1"
}

local function empty_body_reader()
  return nil
end

local function get_fixed_field_metatable_proxy(proxy)
  return {
    __index =
      function(t, k) -- luacheck: no unused
        return proxy[k] or
          error("field " .. tostring(k) .. " does not exist", 2)
      end,
    __newindex =
      function(t, k, v)
        if proxy[k] then
          return rawset(t, k, v)
        else
          error("attempt to create new field " .. tostring(k), 2)
        end
      end,
  }
end

local function str_split(str, delim)
  local pos, endpos, prev, i = 0, 0, 0, 0 -- luacheck: ignore pos endpos
  local out = {}
  repeat
      pos, endpos = string.find(str, delim, prev, true)
      i = i+1
      if pos then
          out[i] = string.sub(str, prev, pos-1)
      else
          if prev <= #str then
              out[i] = string.sub(str, prev, -1)
          end
          break
      end
      prev = endpos +1
  until pos == nil

  return out
end

local function randomhex(length)
  local len = math.floor(length / 2)

  local bytes = ffi.new("uint8_t[?]", len)
  C.RAND_pseudo_bytes(bytes, len)
  if not bytes then
      return nil, "error getting random bytes via FFI"
  end

  local hex = ffi.new("uint8_t[?]", len * 2)
  C.ngx_hex_dump(hex, bytes, len)
  return ffi.string(hex, len * 2)
end

local function co_wrap(func)
  local co = coroutine.create(func)
  if not co then
    return nil, "could not create coroutine"
  else
    return function(...)
      if coroutine.status(co) == "suspended" then
        -- Handle errors in coroutines
        local ok, val1, val2, val3 = coroutine.resume(co, ...)
        if ok == true then
          return val1, val2, val3
        else
          return nil, val1
        end
      else
        return nil, "can't resume a " .. coroutine.status(co) .. " coroutine"
      end
    end
  end
end

function _M.new()
  return setmetatable({
      ranges = {},
      boundary_end = "",
      boundary = "",
  }, get_fixed_field_metatable_proxy(_M))
end

local function header_has_directive(header, directive, without_token)
  if header then
    if type(header) == "table" then header = table.concat(header, ", ") end

    local pattern = [[(?:\s*|,?)(]] .. directive .. [[)\s*(?:$|=|,)]]
    if without_token then
      pattern = [[(?:\s*|,?)(]] .. directive .. [[)\s*(?:$|,)]]
    end

    return ngx.re.find(header, pattern, "ioj") ~= nil
  end
  return false
end

local function get_header_token(header, directive)
  if header_has_directive(header, directive) then
      if type(header) == "table" then header = table.concat(header, ", ") end

      -- Want the string value from a token
      local value = ngx.re.match(
          header,
          directive .. [[="?([a-z0-9_~!#%&/',`\$\*\+\-\|\^\.]+)"?]],
          "ioj"
      )
      if value ~= nil then
          return value[1]
      end
      return nil
  end
  return nil
end

local function req_byte_ranges()
  local bytes = get_header_token(ngx.req.get_headers().range, "bytes")
  local ranges = nil

  if bytes then
    ranges = str_split(bytes, ",")
    if not ranges then ranges = { bytes } end
    for i, r in ipairs(ranges) do
      local from, to = string.match(r, "(%d*)%-(%d*)")
      ranges[i] = { from = tonumber(from), to = tonumber(to) }
    end
  end

  return ranges
end

local function sort_byte_ranges(first, second)
  if not first.from or not second.from then
    return nil, "Attempt to compare invalid byteranges"
  end
  return first.from <= second.from
end

function _M.handle_range_request(self, res)
  local range_request = req_byte_ranges()
  res.size = #res.body

  if range_request and type(range_request) == "table" and res.size then
    -- Don't attempt range filtering on non 200 responses
    if res.status ~= 200 then
      return res, false
    end

    local ranges = {}

    for _, range in ipairs(range_request) do
      local range_satisfiable = true

      if not range.to and not range.from then
        range_satisfiable = false
      end

      -- A missing "to" means to the "end".
      if not range.to then
        range.to = res.size - 1
      end

      -- A missing "from" means "to" is an offset from the end.
      if not range.from then
        range.from = res.size - (range.to)
        range.to = res.size - 1

        if range.from < 0 then
          range_satisfiable = false
        end
      end

      -- A "to" greater than size should be "end"
      if range.to > (res.size - 1) then
        range.to = res.size - 1
      end

      -- Check the range is satisfiable
      if range.from > range.to then
        range_satisfiable = false
      end

      if not range_satisfiable then
        -- We'll return 416
        res.status = RANGE_NOT_SATISFIABLE
        res.body_reader = empty_body_reader
        res.header.content_range = "bytes */" .. res.size

        return res, false
      else
        -- We'll need the content range header value
        -- for multipart boundaries: e.g. bytes 5-10/20
        range.header = "bytes " .. range.from ..
                        "-" .. range.to ..
                        "/" .. res.size
        table.insert(ranges, range)
      end
    end

    local numranges = #ranges
    if numranges > 1 then
      -- Sort ranges as we cannot serve unordered.
      table.sort(ranges, sort_byte_ranges)

      -- Coalesce overlapping ranges.
      for i = numranges,1,-1 do
        if i > 1 then
          local current_range = ranges[i]
          local previous_range = ranges[i - 1]

          if current_range.from <= previous_range.to then
            -- extend previous range to encompass this one
            previous_range.to = current_range.to
            previous_range.header = "bytes " ..
                                    previous_range.from ..
                                    "-" ..
                                    current_range.to ..
                                    "/" ..
                                    res.size
            table.remove(ranges, i)
          end
        end
      end
    end

    self.ranges = ranges

    if #ranges == 1 then
      -- We have a single range to serve.
      local range = ranges[1]

      local size = res.size

      res.status = PARTIAL_CONTENT
      ngx.header["Accept-Ranges"] = "bytes"
      res.header["Content-Range"] = "bytes " .. range.from ..
                                      "-" .. range.to ..
                                      "/" .. size

      return res, true
  else
      -- Generate boundary
      local boundary_string = randomhex(32)
      local boundary = {
        "",
        "--" .. boundary_string,
      }

      if res.header["Content-Type"] then
        table.insert(
          boundary,
          "Content-Type: " .. res.header["Content-Type"]
        )
      end

      self.boundary = table.concat(boundary, "\n")
      self.boundary_end = "\n--" .. boundary_string .. "--"

      res.status = PARTIAL_CONTENT
      -- TODO: No test coverage for these headers
      res.header["Accept-Ranges"] = "bytes"
      res.header["Content-Type"] = "multipart/byteranges; boundary=" ..
                                   boundary_string

      return res, true
    end
  end
end

function _M.get_range_request_filter(self, reader)
  local ranges = self.ranges
  local boundary_end = self.boundary_end
  local boundary = self.boundary

  if ranges then
    return co_wrap(function(buffer_size)
      local playhead = 0
      local num_ranges = #ranges

      while true do
        local chunk, err = reader(buffer_size)
        if err then ngx.log(ngx.ERR, err) end
        if not chunk then break end

        local chunklen = #chunk
        local nextplayhead = playhead + chunklen

        for _, range in ipairs(ranges) do
          if range.from >= nextplayhead or range.to < playhead then -- luacheck: ignore 542
            -- Skip over non matching ranges (this is
            -- algorithmically simpler)
          else
            -- Yield the multipart byterange boundary if
            -- required and only once per range.
            if num_ranges > 1 and not range.boundary_printed then
              coroutine.yield(boundary)
              coroutine.yield("\nContent-Range: " .. range.header)
              coroutine.yield("\n\n")
              range.boundary_printed = true
            end

            -- Trim range to within this chunk's context
            local yield_from = range.from
            local yield_to = range.to
            if range.from < playhead then
              yield_from = playhead
            end
            if range.to >= nextplayhead then
              yield_to = nextplayhead - 1
            end

            -- Find relative points for the range within this chunk
            local relative_yield_from = yield_from - playhead
            local relative_yield_to = yield_to - playhead

            -- Ranges are all 0 indexed, finally convert to 1 based
            -- Lua indexes, and yield the range.
            coroutine.yield(
              string.sub(
                chunk,
                relative_yield_from + 1,
                relative_yield_to + 1
              )
            )
          end
        end

        playhead = playhead + chunklen
      end

      -- Yield the multipart byterange end marker
      if num_ranges > 1 then
        coroutine.yield(boundary_end)
      end
    end)
  end

  return reader
end

return _M