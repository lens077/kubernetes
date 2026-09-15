package conntest

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	openbao "github.com/openbao/openbao/api/v2"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// OpenBao: sys/health 必须 initialized && !sealed。SDK: openbao/api。
func TestOpenBao(t *testing.T) {
	skipIf(t, "OPENBAO")
	cfg := openbao.DefaultConfig()
	cfg.Address = env("OPENBAO_ADDR", "http://openbao.openbao.svc.cluster.local:8200")
	cli, err := openbao.NewClient(cfg)
	if err != nil {
		t.Fatalf("客户端: %v", err)
	}
	h, err := cli.Sys().HealthWithContext(ctx(t, 15*time.Second))
	if err != nil {
		t.Fatalf("sys/health(%s): %v", cfg.Address, err)
	}
	if !h.Initialized || h.Sealed {
		t.Fatalf("OpenBao 未就绪: initialized=%v sealed=%v", h.Initialized, h.Sealed)
	}
	t.Logf("OpenBao %s: initialized, unsealed, 版本 %s", cfg.Address, h.Version)
}

// VictoriaMetrics: 用 Prometheus 文本格式写一个样本, 再用 PromQL 查回来。
func TestVictoriaMetrics(t *testing.T) {
	skipIf(t, "VICTORIAMETRICS")
	base := env("VM_URL", "http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428")
	metric := "conntest_probe"
	line := fmt.Sprintf(`%s{run="%s"} 42`, metric, runID)
	if code, body := httpPost(t, plainHTTP, base+"/api/v1/import/prometheus", "text/plain", line+"\n"); code/100 != 2 {
		t.Fatalf("import 返回 %d: %s", code, body)
	}
	// 即时查询默认忽略最近 -search.latencyOffset(30s) 的样本, 刚写入的点查不到; 用 export 精确核对原始样本。
	eventually(t, 30*time.Second, func() error {
		code, _, body := httpGet(t, plainHTTP, base+`/api/v1/export?match[]=`+metric+`{run="`+runID+`"}`, "")
		if code != 200 {
			return fmt.Errorf("export %d: %s", code, body)
		}
		if !strings.Contains(body, `"values":[42]`) {
			return fmt.Errorf("样本尚未可查: %s", body)
		}
		return nil
	})
	// PromQL 通路本身也要能用: 查刚写入的样本, 把评估时间点向后放 latencyOffset(默认 30s)之外, 避开"忽略最近 30s"。
	q := `/api/v1/query?query=` + metric + `{run="` + runID + `"}&time=` + fmt.Sprint(time.Now().Add(60*time.Second).Unix())
	if code, _, body := httpGet(t, plainHTTP, base+q, ""); code != 200 || !strings.Contains(body, `"42"`) {
		t.Fatalf("PromQL query %d: %s", code, body)
	}
	t.Logf("VictoriaMetrics %s: 写入→export 查回 OK, PromQL 查回 OK", base)
}

// VictoriaLogs: jsonline 写一条日志, LogsQL 查回。
func TestVictoriaLogs(t *testing.T) {
	skipIf(t, "VICTORIALOGS")
	base := env("VL_URL", "http://vl-victoria-logs-single-server.logging.svc.cluster.local:9428")
	entry := fmt.Sprintf(`{"_msg":"%s","_time":"%s","source":"conntest"}`, runID, time.Now().UTC().Format(time.RFC3339Nano))
	if code, body := httpPost(t, plainHTTP, base+"/insert/jsonline?_stream_fields=source", "application/stream+json", entry+"\n"); code/100 != 2 {
		t.Fatalf("insert 返回 %d: %s", code, body)
	}
	eventually(t, 30*time.Second, func() error {
		code, body := httpPost(t, plainHTTP, base+"/select/logsql/query", "application/x-www-form-urlencoded", "query=_msg:"+runID+"&limit=1")
		if code != 200 {
			return fmt.Errorf("query %d: %s", code, body)
		}
		if !strings.Contains(body, runID) {
			return fmt.Errorf("日志尚未可查")
		}
		return nil
	})
	t.Logf("VictoriaLogs %s: 写入→LogsQL 查回 OK", base)
}

// OTel Collector → VictoriaTraces: 用 otel-go OTLP/gRPC 发一个 span, 再从 VictoriaTraces 的
// Jaeger 兼容查询接口找到服务名。这条链路证明 collector 的 traces pipeline 真的写进了后端。
func TestOTLPTraceToVictoriaTraces(t *testing.T) {
	skipIf(t, "OTEL")
	endpoint := env("OTLP_GRPC_ENDPOINT", "otel-opentelemetry-collector.opentelemetry.svc.cluster.local:4317")
	vt := env("VT_URL", "http://victoria-traces.observability.svc.cluster.local:10428")
	service := runID
	c := ctx(t, 60*time.Second)
	exp, err := otlptracegrpc.New(c, otlptracegrpc.WithEndpoint(endpoint), otlptracegrpc.WithInsecure())
	if err != nil {
		t.Fatalf("OTLP exporter(%s): %v", endpoint, err)
	}
	res, _ := resource.Merge(resource.Default(), resource.NewWithAttributes(semconv.SchemaURL, semconv.ServiceName(service)))
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp), sdktrace.WithResource(res))
	otel.SetTracerProvider(tp)
	_, span := tp.Tracer("conntest").Start(c, "probe")
	span.SetAttributes(attribute.String("run", runID))
	span.End()
	if err := tp.Shutdown(c); err != nil { // Shutdown 会 flush; 失败说明 collector 不可达或拒收
		t.Fatalf("flush span 到 collector: %v", err)
	}
	eventually(t, 60*time.Second, func() error {
		code, _, body := httpGet(t, plainHTTP, vt+"/select/jaeger/api/services", "")
		if code != 200 {
			return fmt.Errorf("VT services %d: %s", code, body)
		}
		if !strings.Contains(body, service) {
			return fmt.Errorf("服务 %s 尚未出现在 VictoriaTraces", service)
		}
		return nil
	})
	t.Logf("OTLP/gRPC %s → VictoriaTraces %s: span 落库并可查 OK", endpoint, vt)
}

// Alertmanager: /-/ready 与 /api/v2/status(集群成员、配置已加载)。
func TestAlertmanager(t *testing.T) {
	skipIf(t, "ALERTMANAGER")
	base := env("ALERTMANAGER_URL", "http://alertmanager.observability.svc.cluster.local:9093")
	if code, _, body := httpGet(t, plainHTTP, base+"/-/ready", ""); code != 200 {
		t.Fatalf("/-/ready %d: %s", code, body)
	}
	code, _, body := httpGet(t, plainHTTP, base+"/api/v2/status", "")
	if code != 200 {
		t.Fatalf("/api/v2/status %d: %s", code, body)
	}
	var st struct {
		VersionInfo struct{ Version string }  `json:"versionInfo"`
		Config      struct{ Original string } `json:"config"`
	}
	if err := json.Unmarshal([]byte(body), &st); err != nil || st.Config.Original == "" {
		t.Fatalf("status 解析失败或配置为空: %v", err)
	}
	t.Logf("Alertmanager %s: ready, 版本 %s, 配置已加载", base, st.VersionInfo.Version)
}

// 其它只有 HTTP 接口的组件: 一次请求证明进程活着且路由正确。
func TestHTTPEndpoints(t *testing.T) {
	cases := []struct {
		name, url, host string
		skip            string
		wantCode        int
		wantBody        string
	}{
		{"argocd", env("ARGOCD_URL", "http://argocd-server.argocd.svc.cluster.local/api/version"), "", "ARGOCD", 200, `"Version"`},
		{"spegel-metrics", env("SPEGEL_URL", "http://spegel.spegel.svc.cluster.local:9090/metrics"), "", "SPEGEL", 200, "spegel_"},
		{"gatus", env("GATUS_URL", "http://gatus.ops.svc.cluster.local:8080/health"), "", "GATUS", 200, ""},
		{"healthchecks", env("HEALTHCHECKS_URL", "http://healthchecks.ops.svc.cluster.local:8000/api/v3/status/"), "", "HEALTHCHECKS", 200, ""},
		{"bugsink", env("BUGSINK_URL", "http://bugsink.ops.svc.cluster.local:8000/health/ready"), env("BUGSINK_HOST", "bugsink.dev.test"), "BUGSINK", 200, ""},
		{"tetragon-metrics", env("TETRAGON_METRICS_URL", "http://tetragon.tetragon.svc.cluster.local:2112/metrics"), "", "TETRAGON", 200, "tetragon_"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			skipIf(t, tc.skip)
			code, _, body := httpGet(t, plainHTTP, tc.url, tc.host)
			if code != tc.wantCode {
				t.Fatalf("%s → %d (期望 %d): %s", tc.url, code, tc.wantCode, body)
			}
			if tc.wantBody != "" && !strings.Contains(body, tc.wantBody) {
				t.Fatalf("%s 响应缺少 %q: %s", tc.url, tc.wantBody, body)
			}
			t.Logf("%s OK (%d)", tc.url, code)
		})
	}
}

// 共享 Gateway 固定 VIP: 从 Pod 走 Cilium L7 LB 到 Envoy。匹配的 Host 得业务状态码,
// 不匹配的 Host 得 Envoy 404(证明到了网关而不是别的东西), 80 口 301 到 https。
func TestGatewayVIP(t *testing.T) {
	skipIf(t, "GATEWAY")
	vip := requireEnv(t, "GATEWAY_VIP")
	host := env("GATEWAY_PROBE_HOST", "metrics.dev.test")
	tlsClient := &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{TLSClientConfig: tlsConfig(t, host)},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	code, hdr, _ := httpGet(t, tlsClient, "https://"+vip+"/", host)
	if code != 200 || !strings.EqualFold(hdr.Get("server"), "envoy") {
		t.Fatalf("https://%s Host=%s → %d server=%q (期望 200/envoy)", vip, host, code, hdr.Get("server"))
	}
	if code, hdr, _ := httpGet(t, tlsClient, "https://"+vip+"/", "nomatch."+host); code != 404 || !strings.EqualFold(hdr.Get("server"), "envoy") {
		t.Fatalf("未匹配 Host 应得 Envoy 404, 实际 %d server=%q", code, hdr.Get("server"))
	}
	plain := &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	if code, hdr, _ := httpGet(t, plain, "http://"+vip+"/", host); code != 301 || !strings.HasPrefix(hdr.Get("location"), "https://") {
		t.Fatalf("80 口应 301 到 https, 实际 %d location=%q", code, hdr.Get("location"))
	}
	t.Logf("Gateway VIP %s: Host=%s 200/envoy, 未匹配 404/envoy, 80→443 301 OK", vip, host)
}

// 应用层(与内网 node101~103 对齐后新增): config-center 管理面/数据面、control-tower-gateway、ecommerce 后端。
// 路径都经共享 Gateway VIP + Host 头, 与公网 Pangolin 走的是同一条路。
func TestApplicationLayer(t *testing.T) {
	skipIf(t, "APPS")
	vip := requireEnv(t, "GATEWAY_VIP")
	// 证书是 *.dev.test 泛域名; .app.com 这类 Host 只用于路由匹配, SNI 固定用一个证书覆盖的名字做校验
	sni := env("GATEWAY_SNI", "probe.dev.test")
	tlsClient := &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{TLSClientConfig: tlsConfig(t, sni)},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	cases := []struct {
		name, host, path string
		want             int
	}{
		{"config-center-web", "config.app.com", "/", 200},
		{"config-center-api-healthz", "config-api.app.com", "/healthz", 200},
		{"config-center-api-needs-token", "config-api.app.com", "/config.v1.ConfigService/ListNamespaces", 401},
		{"control-tower-gateway", "gateway.dev.test", "/healthz", 200},
		{"ecommerce-payment", "payment.dev.test", "/healthz", 200},
		{"ecommerce-user", "user.dev.test", "/healthz", 200},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			code, hdr, body := httpGet(t, tlsClient, "https://"+vip+tc.path, tc.host)
			if code != tc.want {
				t.Fatalf("Host=%s %s → %d (期望 %d) server=%q: %.200s", tc.host, tc.path, code, tc.want, hdr.Get("server"), body)
			}
			t.Logf("Host=%s %s → %d", tc.host, tc.path, code)
		})
	}
	// 数据面: 用 pre 环境 machine token 从 Config Center 读一个服务的 bootstrap.yaml(Secret 注入, 缺失则 Skip)
	tok := requireEnv(t, "CONFIG_CENTER_SERVICE_TOKEN")
	svc := env("CONFIG_CENTER_SERVICE", "payment")
	envName := env("CONFIG_CENTER_ENV", "pre")
	req := fmt.Sprintf(`{"namespace":%q,"environment":%q,"key":"bootstrap.yaml"}`, svc, envName)
	r, err := http.NewRequestWithContext(ctx(t, 15*time.Second), http.MethodPost, "https://"+vip+"/config.v1.ConfigService/GetKey", strings.NewReader(req))
	if err != nil {
		t.Fatal(err)
	}
	r.Host = "config-api.app.com"
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("x-config-center-service-token", tok)
	resp, err := tlsClient.Do(r)
	if err != nil {
		t.Fatalf("GetKey: %v", err)
	}
	defer resp.Body.Close()
	var out struct {
		Code  *string `json:"code"`
		Entry struct {
			Version int    `json:"version"`
			Value   string `json:"value"`
		} `json:"entry"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || out.Code != nil || out.Entry.Version == 0 || !strings.Contains(out.Entry.Value, "data:") {
		t.Fatalf("GetKey %s/%s 失败: http=%d err=%v code=%v version=%d", svc, envName, resp.StatusCode, err, out.Code, out.Entry.Version)
	}
	t.Logf("Config Center 数据面: %s/%s/bootstrap.yaml v%d 读取 OK(machine token)", svc, envName, out.Entry.Version)
}
