static:
	perl -e 'foreach $$i ( 0 ... 1024*1024-1 ) { printf "%09d\n",  $$i*10 }' > static/10Mb.txt

up-server: static
	docker run --rm -p 8080:80 \
		-v $(shell pwd)/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf \
		-v $(shell pwd)/lib:/etc/nginx \
		-v $(shell pwd)/static:/www/s openresty/openresty:alpine

.PHONY: static up-server