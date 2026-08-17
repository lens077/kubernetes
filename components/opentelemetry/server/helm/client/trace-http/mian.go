package main

import (
	"context"
	"crypto/tls"
	"log"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"
)

// 临时测试：go run .
func main() {
	ctx := context.Background()

	// 1. 配置 HTTP Exporter：连接到 OTLP HTTP 端点 (通常是 4318，这里通过网关 443 访问)
	exporter, err := otlptracehttp.New(ctx,
		otlptracehttp.WithTLSClientConfig(&tls.Config{
			// 跳过自签名证书验证（开发环境）
			InsecureSkipVerify: true,
			// 显式协商 HTTP/2，解决可能的 ALPN 问题
			NextProtos: []string{"h2"},
		}),
		// 指向 otlp-http.app.com，网关会将流量路由到 otel-collector 的 4318 端口
		// otlptracehttp.WithEndpoint("jaeger-http.app.com:443"),
		// otlptracehttp.WithEndpoint("192.168.3.119:4318"),
		otlptracehttp.WithEndpoint("otlp-http.app.com:443"),
		// otlptracehttp.WithInsecure(),
		// 如果网关做了路径重写，可能需要手动指定 URL 路径，这里使用默认的 /v1/traces
		// otlptracehttp.WithURLPath("/v1/traces"),
	)
	if err != nil {
		log.Fatalf("failed to create exporter: %v", err)
	}

	// 2. 配置资源信息：设置服务名称
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceNameKey.String("order-service2"), // 方便在 Jaeger UI 中查找
		),
	)
	if err != nil {
		log.Fatalf("failed to create resource: %v", err)
	}

	// 3. 创建 TracerProvider
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.AlwaysSample()), // 测试时全量采样
	)
	defer tp.Shutdown(ctx)
	otel.SetTracerProvider(tp)

	// 4. 编写一个模拟业务 Span
	tracer := otel.Tracer("test-tracer")

	func() {
		_, span := tracer.Start(ctx, "Manual-Test-Span")
		defer span.End()

		log.Println("正在发送测试 Span 到 Jaeger (via HTTP)...")

		// 模拟业务逻辑耗时
		span.AddEvent("开始执行业务逻辑")
		time.Sleep(500 * time.Millisecond)
		span.AddEvent("逻辑执行完毕")
	}()

	// 强制刷新，确保数据发出
	log.Println("数据已发出，请去 Jaeger UI 检查。")
	time.Sleep(2 * time.Second)
}
