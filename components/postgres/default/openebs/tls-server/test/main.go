package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

func main() {
	// 1. 读取你从 k8s secret 中提取的自签名 CA 证书
	caCert, err := os.ReadFile("ca.crt")
	if err != nil {
		log.Fatalf("无法读取 CA 证书: %v\n请确保 ca.crt 文件在当前目录", err)
	}

	// 2. 将 CA 证书加入系统的信任池
	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		log.Fatal("解析 CA 证书失败")
	}

	// 3. 配置 TLS
	// 注意：ServerName 必须与证书 DNS Names (pg-dev.app.com 或 pg.app.com) 一致
	tlsConfig := &tls.Config{
		RootCAs:            caCertPool,
		ServerName:         "pg-dev.app.com",
		InsecureSkipVerify: false, // 设为 false 表示严格验证服务端证书
	}

	// 4. 配置数据库连接
	// 如果你改成了 TCPRoute，端口是 443；如果直连 LB，端口是 5432。请根据实际情况修改。
	// 这里假设你本地 `/etc/hosts` 已经配置了 pg-dev.app.com 指向 192.168.3.119
	dsn := "host=pg-dev.app.com port=5432 user=postgres password=msdnmm dbname=postgres sslmode=require"
	// dsn := "host=192.168.3.109 port=5432 user=postgres password=msdnmm dbname=postgres sslmode=require"

	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		log.Fatalf("解析连接字符串失败: %v", err)
	}

	// 将我们自定义的 TLS 配置注入到 pgx 连接配置中
	config.TLSConfig = tlsConfig

	// 5. 建立连接
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	fmt.Println("正在尝试通过 TLS 连接 PostgreSQL...")
	conn, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		log.Fatalf("连接失败 (请检查网关 TCP 透传是否已生效): %v", err)
	}
	defer conn.Close(context.Background())

	// 6. 执行查询验证
	var version string
	err = conn.QueryRow(context.Background(), "SELECT version()").Scan(&version)
	if err != nil {
		log.Fatalf("查询失败: %v", err)
	}

	fmt.Println("✅ 成功通过 TLS 连接到数据库！")
	fmt.Printf("📦 数据库版本: %s\n", version)
}

// package main
//
// import (
// 	"context"
// 	"crypto/tls"
// 	"crypto/x509"
// 	"fmt"
// 	"log"
// 	"os"
//
// 	"github.com/jackc/pgx/v5"
// )
//
// func main() {
// 	// 1. 加载 CA 证书
// 	caCert, err := os.ReadFile("./ca.crt")
// 	if err != nil {
// 		log.Fatal(err)
// 	}
// 	caCertPool := x509.NewCertPool()
// 	caCertPool.AppendCertsFromPEM(caCert)
//
// 	// 2. 配置 TLS
// 	tlsConfig := &tls.Config{
// 		RootCAs: caCertPool,
// 		// ServerName:         "pg-dev.app.com", // 必须与证书中的 CN/SAN 匹配
// 		// InsecureSkipVerify: false, // 测试环境若不验证域名可设为 true
// 	}
//
// 	// 3. 构建连接配置
// 	connStr := "postgres://postgres:msdnmm@pg.app.com:443/postgres"
// 	// connStr := "postgres://postgres:msdnmm@192.168.3.106:5432/postgres"
// 	config, err := pgx.ParseConfig(connStr)
// 	if err != nil {
// 		log.Fatal(err)
// 	}
// 	config.TLSConfig = tlsConfig
//
// 	// 4. 建立连接
// 	conn, err := pgx.ConnectConfig(context.Background(), config)
// 	if err != nil {
// 		fmt.Printf("连接失败 (可能由于 TLS 握手): %v\n", err)
// 		os.Exit(1)
// 	}
// 	defer conn.Close(context.Background())
//
// 	// 5. 验证连接是否使用了 SSL
// 	var sslUsed bool
// 	err = conn.QueryRow(context.Background(), "SELECT ssl_is_used()").Scan(&sslUsed)
// 	if err != nil {
// 		// 如果没有安装 sslinfo 扩展，可以直接查询连接状态
// 		fmt.Println("连接成功，但无法验证 SSL 扩展状态")
// 	} else {
// 		fmt.Printf("SSL 连接状态: %v\n", sslUsed)
// 	}
//
// 	fmt.Println("成功通过 TLS 连接到 PostgreSQL!")
// }
