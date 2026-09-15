# Base is mirrored into TCR (Docker Hub is unreachable from the build host and cluster nodes).
# amd64 only: nodes 3/4/5 are amd64. Refresh the mirror with
#   docker push --platform linux/amd64 ccr.ccs.tencentyun.com/sumery/alpine:3.20-amd64
FROM ccr.ccs.tencentyun.com/sumery/alpine:3.20-amd64
RUN apk add --no-cache bash curl jq kubectl python3 py3-yaml
WORKDIR /app
COPY tools/config-center-rotate-service-tokens.sh /app/tools/config-center-rotate-service-tokens.sh
COPY components/_lib /app/components/_lib
COPY bootstrap/lib /app/bootstrap/lib
COPY bootstrap/config.env /app/bootstrap/config.env
RUN chmod 0755 /app/tools/config-center-rotate-service-tokens.sh
USER 65532:65532
# No symlink: the script resolves components/_lib relative to BASH_SOURCE, which must be the real path.
ENTRYPOINT ["/app/tools/config-center-rotate-service-tokens.sh"]
