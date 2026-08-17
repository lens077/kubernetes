package main

import (
	"context"
	"crypto/tls"
	"log"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"
	"google.golang.org/grpc/credentials"
)

// 临时测试：GRPC_ENFORCE_ALPN_ENABLED=false go run .
func main() {
	ctx := context.Background()

	// 1. 配置 Exporter：连接到 Jaeger Collector (gRPC 端口通常是 4317)
	// 如果你在集群外测试，请确保通过 Gateway 暴露了 4317 端口并指向正确 IP
	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithTLSCredentials(credentials.NewTLS(&tls.Config{
			// 1. 跳过自签名证书验证（开发环境）
			InsecureSkipVerify: true,

			// 2. 核心修复：解决 "missing selected ALPN property"
			// 显式告诉网关和客户端，我们要使用 HTTP/2 协议
			NextProtos: []string{"h2"},
		})),
		// otlptracegrpc.WithEndpoint("192.168.3.119:4317"),
		// otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithEndpoint("otlp-grpc.app.com:443"),
	)
	if err != nil {
		log.Fatalf("failed to create exporter: %v", err)
	}

	// 2. 配置资源信息：设置服务名称，方便在 Jaeger UI 中查找
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceNameKey.String("order-service"), // 与你 values.yml 中的策略对应
		),
	)
	if err != nil {
		log.Fatalf("failed to create resource: %v", err)
	}

	// 3. 创建 TracerProvider
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.AlwaysSample()), // 测试时使用全量采样
	)
	defer tp.Shutdown(ctx)
	otel.SetTracerProvider(tp)

	// 4. 开始编写一个模拟业务 Span
	tracer := otel.Tracer("test-tracer")

	func() {
		_, span := tracer.Start(ctx, "Manual-Test-Span")
		defer span.End()

		log.Println("正在发送测试 Span 到 Jaeger...")

		// 模拟业务逻辑耗时
		span.AddEvent("开始执行业务逻辑")
		time.Sleep(500 * time.Millisecond)
		span.AddEvent("逻辑执行完毕")
	}()

	// 强制刷新，确保数据发出
	log.Println("数据已发出，请去 Jaeger UI 检查。")
	time.Sleep(2 * time.Second)
}
