package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"

	sdklog "go.opentelemetry.io/otel/sdk/log"
)

var (
	name   = "test-loki"
	logger = otelslog.NewLogger(name)
)

// --- 配置你的 OTel Collector 端点 ---
// 4317:30969/TCP
// 4318:30694/TCP
// const collectorEndpoint = "192.168.3.100:30694"
const collectorEndpoint = "otlp-http.app.com:443"

// OTLP 日志的标准 HTTP 路径
// const collectorURLPath = "/v1/logs"

// newResource 创建一个 OTel Resource，它代表了产生遥测数据的实体。
// Resource 的属性会作为公共标签附加到所有日志上。
func newResource() *resource.Resource {
	return resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName("my-go-app-logger"),
		semconv.ServiceVersion("1.0.1"),
		attribute.String("environment", "production"),
	)
}

// newLoggerProvider 初始化并配置 LoggerProvider。
func newLoggerProvider(ctx context.Context) (func(context.Context) error, error) {
	// 1. 创建 OTLP HTTP 日志 Exporter
	// WithInsecure 是必须的，因为你的 Collector 端点是 http://
	exporter, err := otlploghttp.New(ctx,
		otlploghttp.WithEndpoint(collectorEndpoint),
		otlploghttp.WithTLSClientConfig(&tls.Config{
			InsecureSkipVerify: true, // 开发环境跳过证书验证
		}),
		// otlploghttp.WithURLPath(collectorURLPath),
		// otlploghttp.WithInsecure(),
	)
	if err != nil {
		return nil, fmt.Errorf("创建 OTLP 日志 exporter 失败: %w", err)
	}

	// 2. 创建一个批处理处理器 (Batching Processor)
	// 这将在后台批量导出日志记录，性能更好
	processor := sdklog.NewBatchProcessor(exporter)

	// 3. 创建并注册全局的 Logger Provider
	loggerProvider := sdklog.NewLoggerProvider(
		sdklog.WithResource(newResource()),
		sdklog.WithProcessor(processor),
	)
	global.SetLoggerProvider(loggerProvider)

	return loggerProvider.Shutdown, nil
}

func main() {
	ctx := context.Background()

	// 初始化 Logger Provider
	shutdown, err := newLoggerProvider(ctx)
	if err != nil {
		log.Fatalf("初始化 Logger Provider 失败: %v", err)
	}
	// 确保在程序退出时，所有缓存的日志都被正确导出
	defer func() {
		if err := shutdown(ctx); err != nil {
			log.Fatalf("关闭 Logger Provider 失败: %v", err)
		}
	}()

	// 从全局 Provider 获取一个 Logger 实例
	// "my-instrumentation" 是 instrumentation scope 的名称

	fmt.Println("开始发送结构化日志到 OTel Collector...")
	// fmt.Printf("目标端点: http://%s%s\n", collectorEndpoint, collectorURLPath)
	fmt.Println("请在你的 Grafana/Loki 中查询 {service_name=\"my-go-app-logger\"}。")
	fmt.Println("按 Ctrl+C 停止程序。")

	// 模拟应用运行并生成日志
	for {
		// --- 示例 1: INFO 级别的日志 ---
		infoAttributes := []any{
			attribute.String("user.id", "user-12345"),
			attribute.String("http.request.method", "GET"),
			attribute.String("http.route", "/home"),
		}
		logger.InfoContext(ctx, "用户成功登录", infoAttributes...)
		fmt.Printf("[%s] 发送 INFO 日志\n", time.Now().Format(time.RFC3339))

		time.Sleep(5 * time.Second)

		// --- 示例 2: ERROR 级别的日志 ---
		err := errors.New("insufficient funds")
		errorAttributes := []any{
			attribute.String("user.id", "user-67890"),
			attribute.String("payment.processor", "stripe"),
			attribute.String("payment.transaction_id", "txn_abc123"),
			attribute.Float64("payment.amount", 99.95),
			attribute.String("error.message", err.Error()),
		}
		logger.ErrorContext(ctx, "处理支付失败", errorAttributes...)
		fmt.Printf("[%s] 发送 ERROR 日志\n", time.Now().Format(time.RFC3339))

		time.Sleep(5 * time.Second)
	}
}
