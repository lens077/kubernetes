// 集群内组件连通性测试(Go 客户端)。
//
// 每个组件一个测试, 用该组件的官方 Go SDK(没有 SDK 的用 net/http 打健康/查询接口),
// 目标地址与凭据全部来自环境变量, 默认值是集群内 DNS 名; 由 run-in-cluster.sh 以 Job 形式
// 在集群里执行, 凭据通过 Secret 注入, 不写进仓库。
//
// 判据是"真实读写往返"而不是"端口通": NATS 发一条消息再拉回来, VM 写一个样本再查回来,
// OTLP 发一个 span 再从 VictoriaTraces 查到服务名, 等等。
package conntest

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// env 返回环境变量, 未设置时用默认值。
func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// requireEnv 返回环境变量; 未设置时跳过测试(凭据类: Secret 未注入就不测, 不假装通过)。
func requireEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	if v == "" {
		t.Skipf("环境变量 %s 未设置, 跳过", key)
	}
	return v
}

// skipIf 允许用 SKIP_<NAME>=1 跳过单个组件(组件未安装时)。
func skipIf(t *testing.T, name string) {
	t.Helper()
	if os.Getenv("SKIP_"+name) != "" {
		t.Skipf("SKIP_%s 已设置, 跳过", name)
	}
}

// runID 让每次运行写入的数据可区分, 查询时不会命中上一次的残留。
var runID = fmt.Sprintf("conntest-%d", time.Now().UnixNano())

func ctx(t *testing.T, d time.Duration) context.Context {
	t.Helper()
	c, cancel := context.WithTimeout(context.Background(), d)
	t.Cleanup(cancel)
	return c
}

// clusterCA 读取 trust-manager 分发的集群根 CA(ConfigMap global-root-ca 挂载到 /etc/cluster-ca/ca.crt)。
// 没有挂载时返回 nil, 调用方决定是否退化为 InsecureSkipVerify。
func clusterCA(t *testing.T) *x509.CertPool {
	t.Helper()
	path := env("CLUSTER_CA_FILE", "/etc/cluster-ca/ca.crt")
	pem, err := os.ReadFile(path)
	if err != nil {
		t.Logf("集群根 CA 不可用(%s: %v), TLS 校验将退化为跳过", path, err)
		return nil
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		t.Fatalf("%s 不是合法的 PEM 证书", path)
	}
	return pool
}

func tlsConfig(t *testing.T, serverName string) *tls.Config {
	t.Helper()
	pool := clusterCA(t)
	if pool == nil {
		return &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12} //nolint:gosec // 无 CA 时的退化路径, 已在日志说明
	}
	return &tls.Config{RootCAs: pool, ServerName: serverName, MinVersion: tls.VersionTLS12}
}

// httpGet 发 GET(可带 Host 头), 返回状态码、响应头与正文前 1MiB(/metrics 这类正文较长, 组件自有指标排在 Go 运行时指标之后)。
func httpGet(t *testing.T, client *http.Client, url, host string) (int, http.Header, string) {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx(t, 15*time.Second), http.MethodGet, url, nil)
	if err != nil {
		t.Fatalf("构造请求 %s: %v", url, err)
	}
	if host != "" {
		req.Host = host
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET %s (Host=%s): %v", url, host, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, resp.Header, string(body)
}

func httpPost(t *testing.T, client *http.Client, url, contentType, body string) (int, string) {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx(t, 15*time.Second), http.MethodPost, url, strings.NewReader(body))
	if err != nil {
		t.Fatalf("构造请求 %s: %v", url, err)
	}
	req.Header.Set("Content-Type", contentType)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", url, err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return resp.StatusCode, string(out)
}

// eventually 轮询直到 fn 返回 nil 或超时; 用于"写入后异步可查"的后端(VL/VT)。
func eventually(t *testing.T, timeout time.Duration, fn func() error) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var last error
	for time.Now().Before(deadline) {
		if last = fn(); last == nil {
			return
		}
		time.Sleep(2 * time.Second)
	}
	t.Fatalf("%s 内未满足条件: %v", timeout, last)
}

var plainHTTP = &http.Client{Timeout: 15 * time.Second}

func firstLine(s, prefix string) string {
	for _, l := range strings.Split(s, "\n") {
		if strings.HasPrefix(strings.TrimSpace(l), prefix) {
			return strings.TrimSpace(l)
		}
	}
	return ""
}

func firstWords(s string, n int) string {
	f := strings.Fields(s)
	if len(f) > n {
		f = f[:n]
	}
	return strings.Join(f, " ")
}
