package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/log/global"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"
)

// OTel Collector 的 OTLP/HTTP 接收器地址
// 日志、追踪和指标通常使用相同的 HTTP 端点
const otelHttpEndpoint = "otlp.app.com"

// initLoggerProvider 用于初始化并配置一个 Logger Provider
// 它负责将日志数据通过 OTLP/HTTP 导出
func initLoggerProvider() (func(context.Context) error, error) {
	ctx := context.Background()

	// 1. 创建资源 (Resource)
	// 这个资源信息会附加到所有的日志记录上，
	// 成为 Loki 中的公共标签 ( `service_name`, `service_version` )
	res, err := resource.New(ctx,
		resource.WithAttributes(
			// semconv.SchemaURL,
			semconv.ServiceName("my-go-app-loki-log"), // 服务名，在 Loki 中会非常有用
			semconv.ServiceVersion("1.0.0"),
			attribute.String("environment", "production"), // 自定义标签
		),
	)
	if err != nil {
		return nil, fmt.Errorf("创建资源失败: %w", err)
	}

	// 2. 创建 OTLP HTTP Log Exporter
	// 我们使用 otlploghttp 来创建一个通过 HTTP 发送日志的 exporter
	logExporter, err := otlploghttp.New(ctx,
		// otlploghttp.WithInsecure(), // HTTP
		otlploghttp.WithTLSClientConfig(&tls.Config{InsecureSkipVerify: true}), // 跳过自签名证书， 仅用于开发测试
		otlploghttp.WithEndpoint(otelHttpEndpoint),
	)
	if err != nil {
		return nil, fmt.Errorf("创建 OTLP HTTP log exporter 失败: %w", err)
	}

	// 3. 创建 Logger Provider
	// 使用 NewBatchProcessor 将日志记录批量处理和发送
	processor := sdklog.NewBatchProcessor(logExporter)
	loggerProvider := sdklog.NewLoggerProvider(
		sdklog.WithResource(res),
		sdklog.WithProcessor(processor),
	)

	// 4. 设置为全局 Logger Provider
	// 这样就可以在代码的任何地方使用 global.LoggerProvider().Logger() 来获取 logger
	global.SetLoggerProvider(loggerProvider)

	fmt.Println("OTLP/HTTP Logger Provider 初始化成功。")
	fmt.Printf("日志数据将发送到: http://%s/v1/logs\n", otelHttpEndpoint)

	// 返回一个用于优雅关闭的函数
	return loggerProvider.Shutdown, nil
}

func main() {
	// 初始化 Logger Provider 并获取关闭函数
	shutdown, err := initLoggerProvider()
	if err != nil {
		log.Fatalf("初始化 Logger Provider 失败: %v", err)
	}

	// 使用 defer 确保在程序退出时关闭 Provider
	defer func() {
		if err := shutdown(context.Background()); err != nil {
			log.Printf("关闭 Logger Provider 失败: %v", err)
		}
		fmt.Println("Logger Provider 已成功关闭。")
	}()

	// 从全局 provider 获取一个 logger 实例
	// "my-app/my-component" 是 instrumentation scope 的名称
	// logger := global.Logger("my-app/my-component")
	logger := otelslog.NewLogger("my-app/my-component")

	fmt.Println("开始生成并发送日志...")

	// 发送一些不同级别的日志
	// 每条日志都可以携带额外的属性 (Attributes)，这些属性在 Loki 中可以作为标签或元数据进行查询
	logger.Info(
		"用户登录成功",
		// sdklog.String("username", "testuser"),
		"username", "testuser",
		// sdklog.Int("user_id", 12345),
	)
	fmt.Println("发送 INFO 日志...")

	time.Sleep(1 * time.Second)

	logger.Warn(
		"密码即将过期",
		// sdklog.String("username", "anotheruser"),
		// sdklog.Int("days_left", 3),
		"username", "anotheruser",
		"days_left", 3,
	)
	fmt.Println("发送 WARN 日志...")

	time.Sleep(1 * time.Second)

	logger.Error(
		"数据库连接失败",
		"error.message", "connection refused",
		"db.host", "db.example.com",
	)
	fmt.Println("发送 ERROR 日志...")

	fmt.Println("日志已生成。请等待片刻，然后在 Grafana (Loki) 中查询。")
	// 等待几秒钟，确保 Batch Processor 有足够的时间发送数据
	time.Sleep(5 * time.Second)
}
