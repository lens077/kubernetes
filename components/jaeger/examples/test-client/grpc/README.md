如果在网关层添加了TLS，那么可能会产生协议不匹配的冲突：网关在入口处接收的是加密的 HTTP/2 (gRPC) 流量。
在卸载 TLS 后，它默认会以 HTTP/1.1 协议将明文数据包转发给后端服务。
然而，Jaeger 的 gRPC 服务端预期的是明文 HTTP/2 (h2c) 协议。
当它收到一个 HTTP/1.1 格式的请求时，无法解析，导致连接被重置，出现 "protocol error"

解决方案：
- go运行时:
```shell
GRPC_ENFORCE_ALPN_ENABLED=false go run .
```

- 在jaeger的svc上进行修改， 将`otlp-grpc`的`appProtocol`的值`grpc`
```yaml
spec:
  clusterIP: 10.101.177.210
  clusterIPs:
    - 10.101.177.210
  internalTrafficPolicy: Cluster
  ipFamilies:
    - IPv4
  ipFamilyPolicy: SingleStack
  ports:
    - appProtocol: grpc
      name: otlp-grpc
      port: 4317
      protocol: TCP
      targetPort: 4317
```
改成`kubernetes.io/h2c`
```yaml
spec:
  clusterIP: 10.101.177.210
  clusterIPs:
    - 10.101.177.210
  internalTrafficPolicy: Cluster
  ipFamilies:
    - IPv4
  ipFamilyPolicy: SingleStack
  ports:
    - appProtocol: kubernetes.io/h2c
      name: otlp-grpc
      port: 4317
      protocol: TCP
      targetPort: 4317
```

# 测试
进入一个带有curl工具的Pod来检查
```shell
kubectl exec -it casdoor-6fbdbb555f-lls22 -n casdoor -- curl -u elastic:oGubUGYjGH29xlOuCYuCOSvw http://elasticsearch-es-http.elastic-stack:9200/_cat/indices?v
```
如果包含index，默认为`ecommerce-jaeger`的索引，那么证明jaeger已经存储数据到了es中
输出示例：
```
health status index                                                              uuid                   pri rep docs.count docs.deleted store.size pri.store.size dataset.size
green  open   .internal.alerts-transform.health.alerts-default-000001            auH7igkPRNW9Lj677_zICw   1   0          0            0       249b           249b         249b
green  open   .internal.alerts-observability.logs.alerts-default-000001          HnNAiG7ZR7yUhH6yLV0MlA   1   0          0            0       249b           249b         249b
yellow open   ecommerce-jaeger-span-2026-04-14                                   nqiGgR1OS9yexHjQ3hXtrQ   5   1
```
