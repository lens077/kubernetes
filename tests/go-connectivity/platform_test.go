package conntest

import (
	"strings"
	"testing"
	"time"

	"github.com/cilium/tetragon/api/v1/tetragon"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// Kubernetes API(in-cluster, ServiceAccount conntest): 节点全部 Ready, 关键算子 Deployment 全部可用。
// SDK: client-go。
func TestKubernetesAPI(t *testing.T) {
	skipIf(t, "KUBERNETES")
	cfg, err := rest.InClusterConfig()
	if err != nil {
		t.Skipf("不在集群内(无 in-cluster 配置): %v", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		t.Fatalf("clientset: %v", err)
	}
	c := ctx(t, 30*time.Second)
	nodes, err := cs.CoreV1().Nodes().List(c, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("list nodes(RBAC?): %v", err)
	}
	for _, n := range nodes.Items {
		ready := false
		for _, cond := range n.Status.Conditions {
			if cond.Type == "Ready" && cond.Status == "True" {
				ready = true
			}
		}
		if !ready {
			t.Errorf("节点 %s 未 Ready", n.Name)
		}
	}
	// 与内网 node101~103 对齐的算子层: 每个命名空间至少一个 Deployment 且全部可用
	operators := strings.Split(env("OPERATOR_NAMESPACES", "cert-manager,kyverno,keda,external-secrets,argo-rollouts,trust-system,cnpg-system,openebs,kube-system"), ",")
	for _, ns := range operators {
		deps, err := cs.AppsV1().Deployments(ns).List(c, metav1.ListOptions{})
		if err != nil {
			t.Errorf("list deployments in %s: %v", ns, err)
			continue
		}
		if len(deps.Items) == 0 {
			t.Errorf("%s 没有任何 Deployment(组件未装?)", ns)
		}
		for _, d := range deps.Items {
			if d.Status.AvailableReplicas < *d.Spec.Replicas {
				t.Errorf("%s/%s 可用 %d/%d", ns, d.Name, d.Status.AvailableReplicas, *d.Spec.Replicas)
			}
		}
	}
	t.Logf("Kubernetes API: %d 节点 Ready, %d 个算子命名空间 Deployment 全部可用", len(nodes.Items), len(operators))
}

// Tetragon gRPC(SDK: cilium/tetragon/api): GetVersion + GetHealth。
// 服务只监听节点 localhost:54321, 所以这个测试要在 hostNetwork 的 Job 里跑(run-in-cluster.sh --host)。
func TestTetragonGRPC(t *testing.T) {
	skipIf(t, "TETRAGON")
	addr := requireEnv(t, "TETRAGON_GRPC_ADDR")
	c := ctx(t, 15*time.Second)
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("gRPC 客户端: %v", err)
	}
	defer conn.Close()
	cli := tetragon.NewFineGuidanceSensorsClient(conn)
	ver, err := cli.GetVersion(c, &tetragon.GetVersionRequest{})
	if err != nil {
		t.Fatalf("GetVersion(%s): %v", addr, err)
	}
	health, err := cli.GetHealth(c, &tetragon.GetHealthStatusRequest{EventSet: []tetragon.HealthStatusType{tetragon.HealthStatusType_HEALTH_STATUS_TYPE_STATUS}})
	if err != nil {
		t.Fatalf("GetHealth: %v", err)
	}
	for _, h := range health.GetHealthStatus() {
		if h.GetStatus() != tetragon.HealthStatusResult_HEALTH_STATUS_RUNNING {
			t.Errorf("Tetragon 健康状态 %s: %s", h.GetStatus(), h.GetDetails())
		}
	}
	t.Logf("Tetragon %s: 版本 %s, 健康 RUNNING", addr, ver.GetVersion())
}
