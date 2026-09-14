FROM alpine:3.22
RUN apk add --no-cache bash curl jq kubectl python3 py3-pyyaml
WORKDIR /app
COPY tools/config-center-rotate-service-tokens.sh /app/tools/config-center-rotate-service-tokens.sh
COPY components/_lib /app/components/_lib
COPY bootstrap/lib /app/bootstrap/lib
COPY bootstrap/config.env /app/bootstrap/config.env
RUN chmod 0755 /app/tools/config-center-rotate-service-tokens.sh && ln -s /app/tools/config-center-rotate-service-tokens.sh /app/rotate-service-tokens
USER 65532:65532
ENTRYPOINT ["/app/rotate-service-tokens"]
