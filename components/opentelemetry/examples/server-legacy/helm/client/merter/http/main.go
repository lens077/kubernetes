package main

import (
	"context"
	"crypto/tls"
	"log"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/metric"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"
)

func main() {
	ctx := context.Background()

	// 1. 创建 gRPC Metrics Exporter，连接到 otel-collector 的 gRPC 端口
	exporter, err := otlpmetrichttp.New(ctx,
		otlpmetrichttp.WithEndpoint("otlp-http.app.com:443"), // 你的 OTLP gRPC 域名
		otlpmetrichttp.WithTLSClientConfig(&tls.Config{
			InsecureSkipVerify: true, // 开发环境跳过证书验证
		}),
		// 如果遇到 ALPN 错误，取消下面一行的注释
		// otlpmetrichttp.WithDialOption(grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{
		// 	InsecureSkipVerify: true,
		// 	NextProtos: []string{"h2"},
		// }))),
	)
	if err != nil {
		log.Fatalf("failed to create metrics exporter: %v", err)
	}

	// 2. 配置资源（服务名等信息），方便在 VictoriaMetrics / Grafana 中区分
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceNameKey.String("test-metrics-service"),
		),
	)
	if err != nil {
		log.Fatalf("failed to create resource: %v", err)
	}

	// 3. 创建 MeterProvider，并注册周期性导出器（每 10 秒导出一批）
	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(
			sdkmetric.NewPeriodicReader(exporter,
				sdkmetric.WithInterval(10*time.Second), // 导出间隔
			),
		),
	)
	defer meterProvider.Shutdown(ctx)

	// 设置全局 MeterProvider
	otel.SetMeterProvider(meterProvider)

	// 4. 创建 Meter 和 Counter 指标
	meter := otel.Meter("test-meter")
	counter, err := meter.Int64Counter("test.requests_total",
		metric.WithDescription("测试用请求总数"),
	)
	if err != nil {
		log.Fatalf("failed to create counter: %v", err)
	}

	// 5. 模拟业务，不断累加指标
	log.Println("开始上报测试指标到 OTel Collector ...")
	for i := 0; i < 5; i++ {
		counter.Add(ctx, 1, metric.WithAttributes(
			attribute.String("env", "dev"),
			attribute.String("method", "GET"),
		))
		log.Printf("已上报第 %d 个指标点", i+1)
		time.Sleep(2 * time.Second)
	}

	log.Println("指标上报完成，等待导出...")
	time.Sleep(15 * time.Second) // 确保周期性导出有时间工作
}
