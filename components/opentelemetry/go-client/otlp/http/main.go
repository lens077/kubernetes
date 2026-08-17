package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"
)

// OTel Collector 的 OTLP/HTTP 接收器地址
// 通常，OTLP HTTP 的默认端口是 4318
const otelHttpEndpoint = "192.168.3.104:4318"

// initTracerProvider 用于初始化并配置一个 Tracer Provider
// 它负责将追踪数据通过 OTLP/HTTP 导出
func initTracerProvider() func(context.Context) error {
	ctx := context.Background()

	// 1. 创建 OTLP HTTP Exporter
	// 与你之前的 gRPC 示例不同，这里我们使用 otlptracehttp
	// WithInsecure() 选项表示我们使用 http 而不是 https
	// WithEndpoint() 指定了 Collector 的地址
	exporter, err := otlptracehttp.New(ctx,
		otlptracehttp.WithInsecure(),
		otlptracehttp.WithEndpoint(otelHttpEndpoint),
	)
	if err != nil {
		log.Fatalf("创建 OTLP HTTP trace exporter 失败: %v", err)
	}

	// 2. 配置资源 (Resource)
	// 资源信息会作为公共属性附加到所有 Span 上
	// 这对于在 Jaeger 或 Grafana 中识别和过滤数据非常有用
	res, err := resource.New(ctx,
		resource.WithAttributes(
			// semconv.SchemaURL,
			semconv.ServiceName("my-go-app-http-trace"), // 定义服务名
			semconv.ServiceVersion("1.0.1"),
		),
	)
	if err != nil {
		log.Fatalf("创建资源失败: %v", err)
	}

	// 3. 创建 Tracer Provider
	// 我们使用 WithBatcher 来批量发送数据，这在生产环境中是推荐的做法
	// 它将 exporter 和资源配置关联起来
	bsp := sdktrace.NewBatchSpanProcessor(exporter)
	tracerProvider := sdktrace.NewTracerProvider(
		sdktrace.WithSampler(sdktrace.AlwaysSample()), // 采样策略，AlwaysSample 表示采集所有 trace
		sdktrace.WithResource(res),
		sdktrace.WithSpanProcessor(bsp),
	)

	// 4. 设置为全局 Tracer Provider
	// 这样在应用的其他地方就可以通过 otel.Tracer() 获取到这个配置好的 tracer
	otel.SetTracerProvider(tracerProvider)

	fmt.Println("OTLP/HTTP Tracer Provider 初始化成功。")
	fmt.Printf("追踪数据将发送到: http://%s/v1/traces\n", otelHttpEndpoint)

	// 返回一个函数，用于在程序退出时优雅地关闭 Provider
	return tracerProvider.Shutdown
}

func main() {
	// 初始化 Tracer Provider 并获取关闭函数
	shutdown := initTracerProvider()

	// 使用 defer 确保在 main 函数结束时调用 shutdown，
	// 这样可以保证所有缓冲的 span 都被发送出去
	defer func() {
		if err := shutdown(context.Background()); err != nil {
			log.Fatalf("关闭 Tracer Provider 失败: %v", err)
		}
		fmt.Println("Tracer Provider 已成功关闭。")
	}()

	// 从全局配置中获取一个 Tracer
	// 参数 "my-instrumentation-library" 是 instrumentation scope 的名称，
	// 用于标识产生 trace 的库或模块
	tracer := otel.Tracer("my-instrumentation-library")

	// 创建一个父 Span
	ctx, parentSpan := tracer.Start(context.Background(), "main-operation")
	fmt.Println("创建父 Span: 'main-operation'")

	// 模拟一些工作
	time.Sleep(200 * time.Millisecond)

	// 创建一个子 Span
	_, childSpan := tracer.Start(ctx, "child-task")
	fmt.Println("创建子 Span: 'child-task'")

	// 模拟子任务的工作
	time.Sleep(300 * time.Millisecond)

	// 结束子 Span
	childSpan.End()
	fmt.Println("子 Span 'child-task' 已结束。")

	// 模拟更多的工作
	time.Sleep(150 * time.Millisecond)

	// 结束父 Span
	parentSpan.End()
	fmt.Println("父 Span 'main-operation' 已结束。")

	fmt.Println("追踪数据已生成。请稍等片刻，然后在 Jaeger 或 Grafana 中查看。")
	// 等待几秒钟，确保 Batch Processor 有足够的时间发送数据
	time.Sleep(5 * time.Second)
}
