package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math/rand"
	"os"
	"os/signal"
	"time"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"

	"go.opentelemetry.io/contrib/bridges/otelzap"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/metric"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"
)

const (
	serviceName = "dice-simulation-app"
	dbHost      = "192.168.3.104:4318"
	dbName      = "public"
)

var (
	tracer  = otel.Tracer("dice-tracer")
	meter   = otel.Meter("dice-meter")
	rollCnt metric.Int64Counter
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	// 1. 初始化 OTel SDK
	shutdown, lp, err := setupOTelSDK(ctx)
	if err != nil {
		log.Fatalf("Failed to setup SDK: %v", err)
	}
	defer shutdown(context.Background())

	// 2. 初始化 Zap 日志桥接器 (核心部分)
	otelCore := otelzap.NewCore("dice-logger", otelzap.WithLoggerProvider(lp))

	// 组合控制台输出和 OTel 输出
	consoleCore := zapcore.NewCore(
		zapcore.NewConsoleEncoder(zap.NewDevelopmentEncoderConfig()),
		zapcore.AddSync(os.Stdout),
		zap.DebugLevel,
	)

	logger := zap.New(zapcore.NewTee(otelCore, consoleCore))
	defer logger.Sync()

	// 3. 初始化指标
	rollCnt, _ = meter.Int64Counter("dice_rolls_total",
		metric.WithDescription("Total number of dice rolls"),
		metric.WithUnit("{roll}"))

	fmt.Println("🎲 Simulation started. Traces/Metrics/Logs linked via TraceID.")

	for i := 1; i <= 5; i++ {
		runSimulation(ctx, i, logger)
		time.Sleep(500 * time.Millisecond)
	}
}

func runSimulation(ctx context.Context, id int, logger *zap.Logger) {
	// --- TRACE 开始 ---
	ctx, span := tracer.Start(ctx, "RollDice")
	defer span.End()

	roll := 1 + rand.Intn(6)
	span.SetAttributes(attribute.Int("dice.value", roll))

	if roll < 3 {
		err := errors.New("dice_stuck_under_table")
		span.RecordError(err)
		span.SetStatus(codes.Error, "Dice simulation failed")

		// 使用 WithContext(ctx) 关联 TraceID
		logger.Error("Failed to roll dice",
			zap.Int("attempt", id),
			zap.Error(err),
			zap.Int("result", roll),
		)

		rollCnt.Add(ctx, 1, metric.WithAttributes(
			attribute.String("status", "error"),
			attribute.Int("value", roll),
		))
		return
	}

	span.SetStatus(codes.Ok, "Success")

	// 正常日志记录
	logger.Info("Dice rolled successfully",
		zap.Int("attempt", id),
		zap.Int("result", roll),
	)

	rollCnt.Add(ctx, 1, metric.WithAttributes(
		attribute.String("status", "success"),
		attribute.Int("value", roll),
	))
}

func setupOTelSDK(ctx context.Context) (func(context.Context) error, *sdklog.LoggerProvider, error) {
	res, _ := resource.New(ctx, resource.WithAttributes(semconv.ServiceNameKey.String(serviceName)))

	// Traces
	traceExporter, _ := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpoint(dbHost),
		otlptracehttp.WithInsecure(),
		otlptracehttp.WithHeaders(map[string]string{
			"X-Greptime-DB-Name":        dbName,
			"x-greptime-pipeline-name":  "greptime_trace_v1",
			"x-greptime-log-table-name": "ecommerce", // 传递表, 一般为当前的微服务, 用于筛选该微服务的日志
		}),
	)
	tp := sdktrace.NewTracerProvider(sdktrace.WithResource(res), sdktrace.WithBatcher(traceExporter))
	otel.SetTracerProvider(tp)

	// Metrics
	metricExporter, _ := otlpmetrichttp.New(ctx,
		otlpmetrichttp.WithEndpoint(dbHost),
		otlpmetrichttp.WithInsecure(),
		otlpmetrichttp.WithHeaders(map[string]string{
			"X-Greptime-DB-Name":        dbName,
			"x-greptime-log-table-name": "ecommerce",
		}),

	)
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter)),
	)
	otel.SetMeterProvider(mp)

	// Logs
	logExporter, _ := otlploghttp.New(ctx,
		otlploghttp.WithEndpoint(dbHost),
		otlploghttp.WithInsecure(),
		otlploghttp.WithHeaders(map[string]string{"X-Greptime-DB-Name": dbName, "x-greptime-log-table-name": "ecommerce"}),
	)
	lp := sdklog.NewLoggerProvider(
		sdklog.WithResource(res),
		sdklog.WithProcessor(sdklog.NewBatchProcessor(logExporter)),
	)

	return func(ctx context.Context) error {
		return errors.Join(tp.Shutdown(ctx), mp.Shutdown(ctx), lp.Shutdown(ctx))
	}, lp, nil
}
