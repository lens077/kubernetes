#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

mkdir -p /home/kubernetes/argocd
cd /home/kubernetes/argocd

# 获取初始化的密码
argocd admin initial-<REDACTED-20260817> -n argocd

# CLI登录
# $lb_ip:port: ip与端口
# --insecure: 忽略TLS验证
# --grpc-web
#lb_ip=$(kubectl get service example-argocd-server -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' -n $ns)

lb_ip="argocd-server.app.com"
argocd login \
$lb_ip \
--username admin \
--<REDACTED-20260817> "${ARGOCD_PASSWORD:?Set ARGOCD_PASSWORD before running this script}" \
--insecure

# 遗忘密码的解决方案:
# 1. 删除 argocd-secret 中的密码相关字段，这会触发系统生成新的随机密码。
# 2. 密码修改需要重启才能被服务加载。
# 3. 获取新生成的密码
#kubectl -n argocd patch secret argocd-secret --type=json -p='[{"op": "remove", "path": "/data/admin.<REDACTED-20260817>"}, {"op": "remove", "path": "/data/admin.<REDACTED-20260817>Mtime"}]'
#kubectl -n argocd rollout restart deployment argocd-server
#argocd admin initial-<REDACTED-20260817> -n argocd

# 列出用户
argocd account list

# 修改密码
argocd account update-<REDACTED-20260817>

# 1. 注册集群以将应用程序部署到该集群(可选, 推荐)
# 将 ServiceAccount （argocd-manager） 安装到该 kubectl 上下文的 kube-system 命名空间中，
# 并将服务帐户绑定到管理员级别的 ClusterRole。Argo CD 使用此服务帐户令牌来执行其管理任务（即部署/监控）。
CLUSTER=$(kubectl config get-contexts -o name)
echo "$CLUSTER"
argocd cluster add "$CLUSTER"

# 2. 添加helm repo
# https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_repo_add/
## Helm仓库
OCI_URL=harbor.apikv.com:5443
argocd repo add $OCI_URL \
  --name oci-helm-registry \
  --username <username> \
  --<REDACTED-20260817> <<REDACTED-20260817>> \
  --type helm \
  --enable-oci

# 3. 创建项目
# -s 可以指定某个命名空间的所有 chart,也可以指定单一的chart
PROJECT=ecommerce
NAME_SPACE=ecommerce
argocd proj create $PROJECT \
 -s $OCI_URL/$PROJECT_PATH \
 --upsert

# https://gitlab.com/sumery/ecommerce.git
argocd proj create ecommerce \
  -s https://gitlab.com/sumery/ecommerce.git \
  -d https://kubernetes.default.svc,ecommerce \
  -d https://kubernetes.default.svc,argocd \
  --upsert

# 查看项目的详细信息
argocd proj get $PROJECT

# 4. 添加集群与命名空间
# argocd proj add-destination <PROJECT> <CLUSTER> <NAMESPACE>
# argocd proj remove-destination <PROJECT> <CLUSTER> <NAMESPACE>
argocd proj add-destination $PROJECT https://kubernetes.default.svc $NAME_SPACE
argocd proj get $PROJECT

# 5. 部署应用
ARGOCD_APP_NAME="ecommerce-backend"
PROJECT_PATH="sumery"
CHART_NAME="ecommerce-helm"
VERSION="0.1.0"
argocd app create ${ARGOCD_APP_NAME} \
  --project $PROJECT \
  --repo $OCI_URL/${PROJECT_PATH} \
  --helm-chart ${CHART_NAME} \
  --revision ${VERSION} \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace $NAME_SPACE \
  --sync-policy automated \
  --self-heal \
  --helm-set backend.image.tag=${VERSION} \
  --helm-pass-credentials \
  --upsert \
  --validate

# 删除
# argocd proj delete frontend

# 添加仓库到项目
#  argocd proj add-source <PROJECT> <REPO>
argocd proj add-source frontend https://gitlab.com/lookeke/full-stack-engineering.git

# 删除
# argocd proj remove-source <PROJECT> <REPO>

# 排除项目
# argocd proj add-source <PROJECT> !<REPO>

# 创建仓库秘钥
## 方式1 HTTPS + Token:
argocd repo add https://github.com/your-org/your-monorepo.git \
  --username your-github-username \
  --<REDACTED-20260817> ghp_xxxxxxxxxxxx
## 方式2 私钥方式:
argocd repo add git@gitlab.com:your-org/your-monorepo.git \
  --ssh-private-key-path ~/.ssh/id_ed25519
## 方式3 声明式:
cat > gitlab-secret.yml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-example-apps
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  # Project scoped
  project: my-project1
  name: argocd-example-apps
  url: https://github.com/argoproj/argocd-example-apps.git
  username: your-github-username
  <REDACTED-20260817>: ghp_xxxxxxxxxxxx
EOF
kubectl apply -f gitlab-secret.yml -n argocd

# 删除应用
#argocd app delete guestbook

# 获取特定用户信息
argocd account get --account <username>

# 生成token
argocd account generate-token --account admin
# token:
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJhZG1pbjphcGlLZXkiLCJuYmYiOjE3MTQ5Mjg0MTYsImlhdCI6MTcxNDkyODQxNiwianRpIjoiYzJiNTAzYzAtNmI0Mi00MzljLTliYTQtNjk1M2E5ZjU5OGZiIn0.t1AjKKWYNBshV5oGFYXOQCfWX-S_u2hX3NcHS3WPMrM

# RBAC权限:
# p, role:lx, applications, *, */*, allow
# p, role:lx, clusters, *, *, allow
# p, role:lx, repositories, *, */*, allow
# p, role:lx, projects, *, */*, allow
# p, role:lx, projects, sync, */*, allow
# p, role:lx, logs, *, */*, allow
# p, role:lx, exec, *, */*, allow
# p, role:admin, applications, *, */*, allow
# p, role:admin, clusters, *, *, allow
# p, role:admin, repositories, *, */*, allow
# p, role:admin, projects, sync, */*, allow
# p, role:admin, logs, *, */*, allow
# p, role:admin, exec, *, */*, allow
# g, admin, role:admin
# g, admin, role:lx
# policy.default: role:admin

# 验证RBAC权限:
# 验证包含rbac的yml或csv文件
argocd admin settings rbac validate --policy-file argocd-rbac-cm.yml
# 命名空间:
argocd admin settings rbac validate --namespace argocd

# 测试策略
# https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/#testing-a-policy
argocd admin settings rbac can role:org-admin get applications --policy-file argocd-rbac-cm.yaml
