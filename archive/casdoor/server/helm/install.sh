#!/bin/bash
set -x

# https://casdoor.org/zh/docs/basic/try-with-helm/
# 镜像版本tag: https://hub.docker.com/r/casbin/casdoor-helm-charts/tags

mkdir -p /home/kubernetes/casdoor
cd /home/kubernetes/casdoor || exit

#helm pull oci://registry-1.docker.io/casbin/casdoor-helm-charts --version v1.702.0
helm pull oci://registry-1.docker.io/casbin/casdoor-helm-charts --version 3.10.2
tar -zxvf casdoor-helm-charts-*.tgz
kubectl create ns casdoor

# 配置文件: https://casdoor.org/zh/docs/basic/try-with-helm/
# 填写指南: https://casdoor.org/docs/basic/server-installation/#via-ini-file

# 修改values.yaml, 如果使用postgres:
#driverName = postgres
#dataSourceName = "user=root password=msdnmm host=localhost port=5432 sslmode=disable dbname=casdoor"
#dbName = casdoor

# 配置页面: https://casdoor.org/docs/basic/try-with-helm
# 外部数据库的配置: https://github.com/casdoor/casdoor-helm/blob/master/charts/casdoor/values.yaml
#wget -O config.yaml https://raw.githubusercontent.com/casdoor/casdoor-helm/master/charts/casdoor/values.yaml

host="postgres-postgresql.postgres.svc.cluster.local"
user="postgres"
password="msdnmm"
driver="postgres"
port=5432
databaseName="casdoor"
ssl_mode="disable"
#service_type="NodePort"
service_type="LoadBalancer"

cat > casdoor-values.yml <<EOF
# Default values for casdoor.
# This is a YAML-formatted file.
# Declare variables to be passed into your templates.

replicaCount: 1

image:
  repository: casbin
  name: casdoor
  pullPolicy: IfNotPresent
  # Overrides the image tag whose default is the chart appVersion.
  tag: ""

# ref: https://casdoor.org/docs/basic/server-installation#via-ini-file
config: |
  appname = casdoor
  httpport = {{ .Values.service.port }}
  runmode = dev
  SessionOn = true
  copyrequestbody = true
  driverName = {{ .Values.database.driver }}
  dataSourceName = {{ include "casdoor.dataSourceName" . }}
  dbName = {{ include "casdoor.dbName" . }}
  redisEndpoint =
  defaultStorageProvider =
  isCloudIntranet = false
  authState = "casdoor"
  socks5Proxy = ""
  verificationCodeTimeout = 10
  initScore = 0
  logPostOnly = true
  origin =
  enableGzip = true
  ldapServerPort = 10389

# Use secret to mount app.conf file for who don't want user,pass on git
# encode base64 on Value.config or create your own secret with anything you prefer
# if you use your own secret, leave Value.config: ""
# configFromSecret: casdoor

database:
  # Supports mysql, postgres, cockroachdb, sqlite
  driver: postgres

  user: "postgres"
  password: "msdnmm"
  host: "postgres-postgresql.postgres.svc.cluster.local"
  # If port is empty, default port will be used.
  # mysql: 3306, postgres: 5432, cockroachdb: 26257
  port: "5432"
  databaseName: casdoor

  sslMode: disable

ldap:
  enabled: false
  service:
    port: 389

imagePullSecrets: []
nameOverride: casdoor
fullnameOverride: ""

serviceAccount:
  # Specifies whether a service account should be created
  create: true
  # Annotations to add to the service account
  annotations: {}
  # The name of the service account to use.
  # If not set and create is true, a name is generated using the fullname template
  name: ""

podAnnotations: {}

podSecurityContext: {}
  # fsGroup: 2000

securityContext: {}
  # capabilities:
  #   drop:
  #   - ALL
  # readOnlyRootFilesystem: true
  # runAsNonRoot: true
  # runAsUser: 1000

probe:
  readiness:
    enabled: true
  liveness:
    enabled: true

service:
  type: LoadBalancer
  port: 8000

ingress:
  enabled: false
  className: ""
  annotations: {}
    # kubernetes.io/ingress.class: nginx
    # kubernetes.io/tls-acme: "true"
  hosts:
    - host: chart-example.local
      paths:
        - path: /
          pathType: ImplementationSpecific
  tls: []
  #  - secretName: chart-example-tls
  #    hosts:
  #      - chart-example.local

resources:
  # We usually recommend not to specify default resources and to leave this as a conscious
  # choice for the user. This also increases chances charts run on environments with little
  # resources, such as Minikube. If you do want to specify resources, uncomment the following
  # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
  limits:
    cpu: 100m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi

autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 100
  targetCPUUtilizationPercentage: 80
  # targetMemoryUtilizationPercentage: 80

nodeSelector: {}

tolerations: []

affinity: {}

# -- Optionally add init containers.
initContainersEnabled: false
initContainers: ""
# initContainers: |
#  - name: ...
#    image: ...

# -- Optionally add extra sidecar containers.
extraContainersEnabled: false
extraContainers: ""
# extraContainers: |
#  - name: ...
#    image: ...
extraVolumeMounts: []
extraVolumes: []

envFromSecret: []
  # - name: ENV_NAME
  #   secretName: test-secret
  #   key: key_name

envFromConfigmap: []
  # - name: ENV_NAME
  #   configmapName: test-cm
  #   key: key_name

envFrom: []
  # - type: configmap
  #   name: test-cm
  # - type: secret
  #   name: test-secret

priorityClassName: ""

# -- Enable/disable the default config volume mount to /conf
# Set to false if you want to provide your own config volume via extraVolumes/extraVolumeMounts
defaultConfigVolumeEnabled: true
EOF

# 安装
helm upgrade --install casdoor ./casdoor-helm-charts \
  -n casdoor \
  -f casdoor-values.yml
#helm upgrade --install casdoor ./casdoor-helm-charts \
#  -n casdoor \
#  --set database.user=${user} \
#  --set database.host=${host} \
#  --set database.password=${password} \
#  --set database.driver=${driver} \
#  --set database.port=${port} \
#  --set database.sslMode=${ssl_mode} \
#  --set database.databaseName=${databaseName} \
#  --set service.type=${service_type}


# 升级
# helm upgrade casdoor . \
# --reuse-values \
# -n casdoor \
# -f values.yaml

# NodePort
kubectl patch svc casdoor-casdoor-helm-charts -n casdoor -p '{"spec":{"type":"NodePort"}}'

set +x
