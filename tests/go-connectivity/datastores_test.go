package conntest

import (
	"fmt"
	"testing"
	"time"

	consulapi "github.com/hashicorp/consul/api"
	"github.com/jackc/pgx/v5"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	openfga "github.com/openfga/go-sdk"
	"github.com/openfga/go-sdk/client"
	"github.com/redis/go-redis/v9"
)

// NATS JetStream: 建流 → 发布 → 拉取消费 → 删流。SDK: nats.go + jetstream。
func TestNATSJetStream(t *testing.T) {
	skipIf(t, "NATS")
	url := env("NATS_URL", "nats://nats.nats.svc.cluster.local:4222")
	nc, err := nats.Connect(url, nats.Timeout(10*time.Second), nats.Name(runID))
	if err != nil {
		t.Fatalf("连接 %s: %v", url, err)
	}
	defer nc.Drain() //nolint:errcheck
	js, err := jetstream.New(nc)
	if err != nil {
		t.Fatalf("JetStream 上下文: %v", err)
	}
	c := ctx(t, 30*time.Second)
	stream := "CONNTEST_" + fmt.Sprint(time.Now().UnixNano())
	subject := "conntest." + stream
	s, err := js.CreateStream(c, jetstream.StreamConfig{Name: stream, Subjects: []string{subject}, Storage: jetstream.MemoryStorage})
	if err != nil {
		t.Fatalf("创建流(JetStream 是否启用?): %v", err)
	}
	defer js.DeleteStream(ctx(t, 10*time.Second), stream) //nolint:errcheck
	if _, err := js.Publish(c, subject, []byte(runID)); err != nil {
		t.Fatalf("发布: %v", err)
	}
	cons, err := s.CreateOrUpdateConsumer(c, jetstream.ConsumerConfig{Durable: "c1", AckPolicy: jetstream.AckExplicitPolicy})
	if err != nil {
		t.Fatalf("创建消费者: %v", err)
	}
	batch, err := cons.Fetch(1, jetstream.FetchMaxWait(10*time.Second))
	if err != nil {
		t.Fatalf("拉取: %v", err)
	}
	var got string
	for m := range batch.Messages() {
		got = string(m.Data())
		_ = m.Ack()
	}
	if got != runID {
		t.Fatalf("消息往返失败: 发 %q 收 %q", runID, got)
	}
	t.Logf("NATS %s: 流 %s 发布→消费往返 OK, 服务器 %s", url, stream, nc.ConnectedServerVersion())
}

// Dragonfly(Redis 协议, TLS + 密码): PING → SET/GET/DEL。SDK: go-redis。
func TestDragonfly(t *testing.T) {
	skipIf(t, "DRAGONFLY")
	addr := env("DRAGONFLY_ADDR", "dragonfly.dragonfly.svc.cluster.local:6379")
	password := requireEnv(t, "DRAGONFLY_PASSWORD")
	opt := &redis.Options{Addr: addr, Password: password, DialTimeout: 10 * time.Second}
	if env("DRAGONFLY_TLS", "true") == "true" {
		opt.TLSConfig = tlsConfig(t, "dragonfly.dragonfly.svc.cluster.local")
	}
	rdb := redis.NewClient(opt)
	defer rdb.Close()
	c := ctx(t, 20*time.Second)
	if err := rdb.Ping(c).Err(); err != nil {
		t.Fatalf("PING %s: %v", addr, err)
	}
	key := runID
	if err := rdb.Set(c, key, "pong", time.Minute).Err(); err != nil {
		t.Fatalf("SET: %v", err)
	}
	v, err := rdb.Get(c, key).Result()
	if err != nil || v != "pong" {
		t.Fatalf("GET: %v (%q)", err, v)
	}
	_ = rdb.Del(c, key).Err()
	info, _ := rdb.Info(c, "server").Result()
	t.Logf("Dragonfly %s: SET/GET 往返 OK; %s", addr, firstLine(info, "dragonfly_version"))
}

// PostgreSQL(CNPG pg-main, app 用户): 连接 → 建临时表写读。SDK: pgx。
func TestPostgres(t *testing.T) {
	skipIf(t, "POSTGRES")
	uri := requireEnv(t, "PG_URI") // 来自 Secret pg-main-app 的 uri 键
	c := ctx(t, 30*time.Second)
	conn, err := pgx.Connect(c, uri)
	if err != nil {
		t.Fatalf("连接: %v", err)
	}
	defer conn.Close(c)
	var version string
	if err := conn.QueryRow(c, "select version()").Scan(&version); err != nil {
		t.Fatalf("select version(): %v", err)
	}
	if _, err := conn.Exec(c, "create temp table conntest(id text primary key, at timestamptz default now())"); err != nil {
		t.Fatalf("建临时表(app 用户应有 CREATE TEMP 权限): %v", err)
	}
	if _, err := conn.Exec(c, "insert into conntest(id) values ($1)", runID); err != nil {
		t.Fatalf("insert: %v", err)
	}
	var n int
	if err := conn.QueryRow(c, "select count(*) from conntest where id=$1", runID).Scan(&n); err != nil || n != 1 {
		t.Fatalf("select: %v n=%d", err, n)
	}
	t.Logf("PostgreSQL: 写读往返 OK; %s", firstWords(version, 2))
}

// Consul(ACL 开启): agent self → KV put/get/delete。SDK: hashicorp/consul/api。
func TestConsul(t *testing.T) {
	skipIf(t, "CONSUL")
	cfg := consulapi.DefaultConfig()
	cfg.Address = env("CONSUL_HTTP_ADDR", "consul-server.consul.svc.cluster.local:8500")
	cfg.Token = requireEnv(t, "CONSUL_HTTP_TOKEN") // Secret consul-bootstrap-acl-token/token
	cli, err := consulapi.NewClient(cfg)
	if err != nil {
		t.Fatalf("客户端: %v", err)
	}
	self, err := cli.Agent().Self()
	if err != nil {
		t.Fatalf("agent/self(地址或 token 不对?): %v", err)
	}
	key := "conntest/" + runID
	if _, err := cli.KV().Put(&consulapi.KVPair{Key: key, Value: []byte("pong")}, nil); err != nil {
		t.Fatalf("KV put: %v", err)
	}
	pair, _, err := cli.KV().Get(key, nil)
	if err != nil || pair == nil || string(pair.Value) != "pong" {
		t.Fatalf("KV get: %v pair=%v", err, pair)
	}
	if _, err := cli.KV().Delete(key, nil); err != nil {
		t.Fatalf("KV delete: %v", err)
	}
	t.Logf("Consul %s: KV 往返 OK; 版本 %v", cfg.Address, self["Config"]["Version"])
}

// OpenFGA: 建 store → 写授权模型 → 写 tuple → check → 删 store。SDK: openfga/go-sdk。
func TestOpenFGA(t *testing.T) {
	skipIf(t, "OPENFGA")
	apiURL := env("OPENFGA_API_URL", "http://openfga.openfga.svc.cluster.local:8080")
	c := ctx(t, 60*time.Second)
	fga, err := client.NewSdkClient(&client.ClientConfiguration{ApiUrl: apiURL})
	if err != nil {
		t.Fatalf("客户端: %v", err)
	}
	store, err := fga.CreateStore(c).Body(client.ClientCreateStoreRequest{Name: runID}).Execute()
	if err != nil {
		t.Fatalf("创建 store(%s): %v", apiURL, err)
	}
	fga.SetStoreId(store.Id)
	defer fga.DeleteStore(ctx(t, 10*time.Second)).Execute() //nolint:errcheck
	model, err := fga.WriteAuthorizationModel(c).Body(client.ClientWriteAuthorizationModelRequest{
		SchemaVersion: "1.1",
		TypeDefinitions: []openfga.TypeDefinition{
			{Type: "user"},
			{Type: "doc", Relations: &map[string]openfga.Userset{"viewer": {This: &map[string]interface{}{}}},
				Metadata: &openfga.Metadata{Relations: &map[string]openfga.RelationMetadata{
					"viewer": {DirectlyRelatedUserTypes: &[]openfga.RelationReference{{Type: "user"}}},
				}}},
		},
	}).Execute()
	if err != nil {
		t.Fatalf("写授权模型: %v", err)
	}
	fga.SetAuthorizationModelId(model.AuthorizationModelId)
	if _, err := fga.Write(c).Body(client.ClientWriteRequest{Writes: []client.ClientTupleKey{{User: "user:anne", Relation: "viewer", Object: "doc:1"}}}).Execute(); err != nil {
		t.Fatalf("写 tuple: %v", err)
	}
	ok, err := fga.Check(c).Body(client.ClientCheckRequest{User: "user:anne", Relation: "viewer", Object: "doc:1"}).Execute()
	if err != nil || ok.Allowed == nil || !*ok.Allowed {
		t.Fatalf("check 应为 allowed: %v %v", err, ok)
	}
	t.Logf("OpenFGA %s: store→model→tuple→check 往返 OK (store %s)", apiURL, store.Id)
}
