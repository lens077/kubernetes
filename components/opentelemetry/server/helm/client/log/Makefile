.PHONY=docker-deployx
docker-deployx:
	docker buildx build . \
    	  -f ./Dockerfile \
    	  --progress=plain \
    	  -t ccr.ccs.tencentyun.com/sumery/test-loki:test1 \
    	  --build-arg SERVICE=test-loki \
    	  --build-arg CGOENABLED=0 \
    	  --build-arg GOIMAGE=golang:1.25.1-alpine3.22 \
    	  --build-arg VERSION=test2 \
    	  --platform linux/arm64,linux/amd64 \
    	  --push \
    	  --cache-from type=registry,ref=ccr.ccs.tencentyun.com/sumery/server:cache \
    	  --cache-to type=registry,ref=ccr.ccs.tencentyun.com/sumery/server:cache,mode=max
