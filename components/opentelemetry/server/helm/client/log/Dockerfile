ARG GO_IMAGE=golang:1.25.1-alpine3.22
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS compile

ARG TARGETOS=linux
ARG TARGETARCH
ARG SERVICE
ARG VERSION=dev
ARG GOPROXY=https://goproxy.cn,direct
ARG CGOENABLED=0

WORKDIR /build

# 挂载依赖缓存
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download -x

# 编译代码
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=$CGOENABLED \
    go build -ldflags="-s -w -X main.Version=$VERSION" -o /app/service . && \
    chmod +x /app/service

# 最终镜像
FROM alpine:3.22 AS final

# 安装必要的依赖
RUN apk add --no-cache libc6-compat

# 创建非root用户
RUN addgroup -g 1000 appuser && \
    adduser -u 1000 -G appuser -D appuser

# 创建工作目录
WORKDIR /app

# 复制可执行文件
COPY --from=compile --chown=appuser:appuser /app/service /app/

# 切换到非root用户
USER appuser

ENTRYPOINT ["/app/service"]

# # 最终镜像
# FROM gcr.io/distroless/static-debian12 AS final
# # COPY --from=compile /app/$SERVICE /app/service
#
# # 复制可执行文件并设置正确权限
# COPY --from=compile --chown=nonroot:nonroot /app/$SERVICE /app/service
#
# # 使用非root用户
# USER nonroot
#
# ENTRYPOINT ["/app/service"]
