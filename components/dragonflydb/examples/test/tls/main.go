package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"log"
	"os"

	"github.com/redis/go-redis/v9"
)

func main() {
	ctx := context.Background()
	caCert, err := os.ReadFile("./ca.crt") // 或 "./ca.crt"
	if err != nil {
		log.Fatal(err)
	}
	caCertPool := x509.NewCertPool()
	caCertPool.AppendCertsFromPEM(caCert)
	rdb := redis.NewClient(&redis.Options{
		// 注意：端口是网关的HTTPS端口，通常是 443
		Addr: "dragonfly.app.com:443",
		// Addr:     "192.168.3.113:6379",
		Password: "msdnmm", // 如果需要密码，在这里设置

		// 启用 TLS，并设置 SNI（Server Name Indication）
		TLSConfig: &tls.Config{
			RootCAs: caCertPool,
			// MinVersion: tls.VersionTLS12, // 可选，强制最低TLS版本
			// InsecureSkipVerify: true,                   // 跳过证书验证，仅用于测试
			// ServerName: "dragonfly.dragonfly.svc", // 必须与证书SAN/CN匹配
		},
	})

	// 测试连接
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("无法连接到Redis: %v", err)
	}
	log.Println("成功连接到Redis")
}
