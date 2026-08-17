#!/bin/bash

set -x

mkdir -p /home/kubernetes/postgres
cd /home/kubernetes/postgres

#helm install postgres oci://registry-1.docker.io/bitnamicharts/postgresql

VERSION="18.7.0"
# https://artifacthub.io/packages/helm/bitnami/postgresql?modal=install

#wget https://charts.bitnami.com/bitnami/postgresql-${VERSION}.tgz
helm repo add bitnami https://charts.bitnami.com/bitnami
helm pull bitnami/postgresql --version $VERSION

#helm pull ingress-nginx/ingress-nginx --untar --untar-dir /path/to/directory

tar -zxvf postgresql-${VERSION}.tgz

# 根据你的 kubectl get sc 输出，你有几个选择。
# 对于 PostgreSQL，您应该使用提供高可用性和数据持久性的 StorageClass，
# 例如由 OpenEBS Mayastor 支持的 StorageClass。
# 如果您没有可用的 Mayastor StorageClass，您可以临时使用 openebs-lvmpv 进行测试，但它缺少数据复制。
# 假设你有一个合适的，比如 openebs-mayastor。把它的sc名称添加到primary.persistence.storageClassName=<sc-name>参数里
kubectl get sc

# https://pgtune.leopard.in.ua
# https://artifacthub.io/packages/helm/bitnami/postgresql?modal=install
cat > pg-extended-conf.values.yml <<EOF
primary:
## pgHbaConfiguration: |-
##   local all all trust
##   host all all localhost trust
##   host mydatabase mysuser 192.168.0.0/24 md5
##
  extendedConfiguration: |-
    wal_level = logical
    wal_buffers = 16MB
    max_connections = 100
    shared_buffers = 1536MB
    effective_cache_size = 4608MB
    maintenance_work_mem = 384MB
    checkpoint_completion_target = 0.9
    default_statistics_target = 100
    random_page_cost = 1.1
    effective_io_concurrency = 1000
    work_mem = 15123kB
    huge_pages = off
    jit = off
    wal_compression = lz4
    min_wal_size = 1GB
    max_wal_size = 4GB
    max_worker_processes = 4
    max_replication_slots = 1
    max_parallel_workers_per_gather = 4
    max_parallel_workers = 8
    max_parallel_maintenance_workers = 4
EOF

helm upgrade --install postgres ./postgresql \
  -n postgres \
  --create-namespace \
  --set global.postgresql.auth.username="postgres" \
  --set global.postgresql.auth.password="msdnmm" \
  --set global.postgresql.auth.database="postgres" \
  --set primary.service.type=LoadBalancer \
  --set global.postgresql.service.ports.postgresql="5432" \
  --set primary.persistence.storageClass="openebs-lvmpv" \
  --set volumePermissions.enabled=true \
  -f pg-extended-conf.values.yml

#	2Gi / 3Gi

# 临时测试, Pod重启后消失
# 允许从默认 postgresql.conf 以外的文件加载设置
# 复制配置文件
# kubectl cp extended.conf \
#  postgres/postgres-postgresql-0:/opt/bitnami/postgresql/conf/conf.d/

# 滚动重启
# kubectl rollout restart statefulset postgres-postgresql -n postgres

set +x
