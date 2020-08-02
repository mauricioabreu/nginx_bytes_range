# NGINX bytes-range feature problem

`make up-server` create a container with NGINX and the sample app.

There are 3 location here:

`/s/10Mb.txt` - static file, 10 megabytes.
`/d` - dynamic response using lua

## The problem

The dynamic location does not work with range-byte request (does it?).

```
curl -v -r 0-10 http://127.0.0.1:8080/s/10Mb.txt

> GET /s/10Mb.txt HTTP/1.1
> Host: 127.0.0.1:8080
> Range: bytes=0-10
> User-Agent: curl/7.64.1
> Accept: */*
> 
< HTTP/1.1 206 Partial Content
< Server: openresty/1.15.8.3
< Date: Sun, 02 Aug 2020 17:09:17 GMT
< Content-Type: text/plain
< Content-Length: 11
< Connection: keep-alive
< Last-Modified: Sun, 02 Aug 2020 16:50:39 GMT
< ETag: "5f26eedf-a00000"
< Content-Range: bytes 0-10/10485760
< 
000000000
```


```
curl -v -r 0-10 http://127.0.0.1:8080/d

> GET /d HTTP/1.1
> Host: 127.0.0.1:8080
> Range: bytes=0-10
> User-Agent: curl/7.64.1
> Accept: */*
> 
< HTTP/1.1 200 OK
< Server: openresty/1.15.8.3
< Date: Sun, 02 Aug 2020 17:12:12 GMT
< Content-Type: application/octet-stream
< Content-Length: 10485761
< Connection: keep-alive
< 
000000010
000000020
000000030
000000040
000000050
000000060
000000070
000000080
000000090
<...>
010485710
010485720
010485730
010485740
010485750
```