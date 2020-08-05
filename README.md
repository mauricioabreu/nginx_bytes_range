# NGINX bytes-range feature problem

`make up-server` create a container with NGINX and the sample app.

There are 3 location here:

`/` - HTML page with video tag
`/d` - dynamic response using lua (read/output video.mp4 file)
`/r` - range support (read/output video.mp4 file)

## The problem

NGINX does not slice the content when it uses a subrequest made by ngx-lua-module.

As the ngx-lua-module author says [ngx-lua subrequest is a simple thing, do not expect too much from it](https://github.com/openresty/lua-nginx-module/issues/947).

## Solution

I decoupled the range module from the excelent [Ledge HTTP project](https://github.com/ledgetech/ledge/)

Special thanks yo James Hurst james@pintsized.co.uk