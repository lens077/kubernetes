package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0" // 使用一个具体的版本以保证稳定性

	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
)

const (
	// 4317:30474/TCP
	// 4318:32719/TCP
	// 修改为你的 OTEL Collector 地址和端口
	// vmEndpoint = "192.168.3.100:32719"
	vmEndpoint = "otlp-http.app.com:443"

	// vmURLPath  = "/opentelemetry/v1/metrics"
)

func main() {
	ctx := context.Background()

	// 1. 创建 OTLP HTTP Exporter
	// 这个 Exporter 负责将指标数据发送到你的 VM 端点
	// WithInsecure() 是必须的，因为你的端点是 http:// 而不是 https://
	exporter, err := otlpmetrichttp.New(ctx,
		otlpmetrichttp.WithEndpoint(vmEndpoint),
		// otlpmetrichttp.WithURLPath(vmURLPath),
		otlpmetrichttp.WithInsecure(),
	)
	if err != nil {
		log.Fatalf("创建 OTLP exporter 失败: %v", err)
	}

	// 2. 配置资源 (Resource)
	// 资源信息会作为公共标签附加到所有指标上
	res := resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName("my-go-app"), // 服务名
		semconv.ServiceVersion("1.0.0"),
	)

	// 3. 创建 Meter Provider
	// Meter Provider 是 OTel Metrics SDK 的核心，它连接了指标的生成和导出
	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter, sdkmetric.WithInterval(5*time.Second))),
	)

	// 4. 设置全局 Meter Provider
	// 这样在应用的其他地方就可以通过 otel.Meter() 获取到配置好的 Meter
	otel.SetMeterProvider(meterProvider)

	// 确保在程序退出时，所有缓存的指标都被正确导出
	defer func() {
		if err := meterProvider.Shutdown(ctx); err != nil {
			log.Fatalf("关闭 Meter Provider 失败: %v", err)
		}
	}()

	// 5. 创建一个 Meter
	// Meter 来自于一个库或组件，用于创建具体的指标
	meter := otel.Meter("my-test-instrumentation")

	// 6. 创建一个计数器 (Counter)
	// 我们将创建一个名为 "requests_total" 的计数器
	counter, err := meter.Int64Counter(
		"requests_total",
		metric.WithDescription("Total number of requests processed."),
		metric.WithUnit("1"),
	)
	if err != nil {
		log.Fatalf("创建 counter 失败: %v", err)
	}

	fmt.Println("开始发送指标到 VictoriaMetrics...")
	// fmt.Printf("目标端点: http://%s%s\n", vmEndpoint, vmURLPath)
	fmt.Println("每 5 秒发送一次数据。请在你的 VMUI 中查询 'requests_total'。")
	fmt.Println("按 Ctrl+C 停止程序。")

	// 7. 模拟应用运行并更新计数器
	// 我们将每隔5秒增加一次计数器的值
	for {
		// 添加标签（在 OTel 中称为 Attribute）
		attrs := attribute.NewSet(
			attribute.String("environment", "development"),
			attribute.String("http_method", "GET"),
		)

		// 增加计数器的值
		counter.Add(ctx, 1, metric.WithAttributeSet(attrs))

		fmt.Printf("[%s] 'requests_total' 计数器增加 1\n", time.Now().Format(time.RFC3339))

		time.Sleep(5 * time.Second)
	}
}
