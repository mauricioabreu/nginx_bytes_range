local range = require("range").new()
local range_controller = {}

local function read_body(response)
  local body = ""
  repeat
    local chunk, err = response.body_reader()
    if chunk then
      body = body .. chunk
    end
  until not chunk
  return body
end

range_controller.fetch = function(response)
  local ranged_response, partial_response = range:handle_range_request(response)
    if partial_response then
      local body_reader = coroutine.wrap(function()
        coroutine.yield(ranged_response.body)
      end)

      ranged_response.body_reader = range:get_range_request_filter(
        body_reader
        )
      local body = read_body(ranged_response)
        ngx.status = ranged_response.status
        ngx.header["Content-Length"] = #body
        ngx.say(body)
    else
      ngx.status = response.status
      ngx.header["Content-Length"] = #response.body
      ngx.say(response.body)
    end
end
  

return range_controller
