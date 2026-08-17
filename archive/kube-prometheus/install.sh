#!/bin/bash

set -x

# 参考 https://blog.csdn.net/slc09/article/details/132571091

export DIR_HOME="/home/kubernetes/"
cd $DIR_HOME || exit

git clone -b main --depth 1 https://github.com/prometheus-operator/kube-prometheus.git
cd kube-prometheus || exit

# Create the namespace and CRDs, and then wait for them to be available before creating the remaining resources
# Note that due to some CRD size we are using kubectl server-side apply feature which is generally available since kubernetes 1.22.
# If you are using previous kubernetes versions this feature may not be available and you would need to use kubectl create instead.
kubectl apply --server-side -f manifests/setup
kubectl wait \
	--for condition=Established \
	--all CustomResourceDefinition \
	--namespace=monitoring
kubectl apply -f manifests/

# 在manifests目录下执行，因为kube-prometheus的镜像都是来自外网，如果用它的镜像源很大概率会出现Imagepullbackoff的错误：
# sed -i 's/quay.io/quay.mirrors.ustc.edu.cn/g' prometheusOperator-deployment.yaml
# sed -i 's/quay.io/quay.mirrors.ustc.edu.cn/g' prometheus-prometheus.yaml
# sed -i 's/quay.io/quay.mirrors.ustc.edu.cn/g' alertmanager-alertmanager.yaml
# sed -i 's/quay.io/quay.mirrors.ustc.edu.cn/g' kubeStateMetrics-deployment.yaml
# sed -i 's/k8s.gcr.io/lank8s.cn/g' kubeStateMetrics-deployment.yaml
# sed -i 's/quay.io/quay.mirrors.ustc.edu.cn/g' nodeExporter-daemonset.yaml
# sed -i 's/quay.io/quay.mirrors.ustc.edu.cn/g' prometheusAdapter-deployment.yaml
# sed -i 's/k8s.gcr.io/lank8s.cn/g' prometheusAdapter-deployment.yaml

# 删除这些网络策略可以让它们在公网访问, 按需删除
kubectl delete -f manifests/prometheus-networkPolicy.yaml
kubectl delete -f manifests/grafana-networkPolicy.yaml
kubectl delete -f manifests/alertmanager-networkPolicy.yam

# 修改SVC类型,默认不对外开放
kubectl patch svc prometheus-k8s -n monitoring -p '{"spec":{"type":"LoadBalancer"}}'
kubectl patch svc grafana -n monitoring -p '{"spec":{"type":"LoadBalancer"}}'
kubectl patch svc alertmanager-main -n monitoring -p '{"spec":{"type":"LoadBalancer"}}'

set +x
