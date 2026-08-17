在获取前，确认证书已经就绪，以防签发失败导致 Secret 内容为空。

```bash
kubectl get certificate dragonfly-gateway-tls -n dragonfly
```
如果输出 READY 列为 True，则代表签发成功，可以提取证书了。你也可以用 describe 命令查看更详细的状态：
```bash
kubectl describe certificate dragonfly-gateway-tls -n dragonfly
```

第二步：从 Secret 中提取证书文件
证书和私钥会以 base64 编码的形式存储在名为 dragonfly-gateway-tls-secret 的 Secret 里。你可以用以下命令将它们解码并保存为本地文件：

1. 提取服务器证书 (tls.crt)
   ```bash
   kubectl get secret dragonfly-gateway-tls-secret -n dragonfly \
   -o jsonpath='{.data.tls\.crt}' | base64 -d > tls.crt
   ```
2. 提取服务器私钥 (tls.key)
   ```bash
   kubectl get secret dragonfly-gateway-tls-secret -n dragonfly \
   -o jsonpath='{.data.tls\.key}' | base64 -d > tls.key
   ```
3. 提取 CA 证书 (ca.crt)
   注意：ca.crt 字段仅在颁发者（Issuer）的 CA 证书也被包含在 Secret 中时才存在。对于自签名证书，它可能不存在，那么 tls.crt 本身即为根证书。

```bash
kubectl get secret dragonfly-gateway-tls-secret -n dragonfly \
-o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
```
如果命令返回空或报错，说明该 Secret 不包含独立的 CA 证书，你可以直接使用 tls.crt 作为 CA 证书。

第三步：验证证书内容（可选）
提取后，可用 openssl 快速查看证书信息，确认域名和有效期。

bash
# 查看证书的颁发者、有效期和域名（SANs）
```bash
openssl x509 -in tls.crt -noout -text
```
📋 第四步：如何在 Go 客户端中使用这些证书
提取的证书文件，可根据你的部署方式在 Go 应用中使用：

部署方式	使用场景	推荐方法
在 Kubernetes 集群内	Pod 需要连接至 dragonfly.app.com	直接挂载 Secret：将 dragonfly-gateway-tls-secret 作为 Volume 挂载到 Pod 的指定路径（如 /etc/tls），应用直接读取该路径下的 tls.crt、tls.key 和 ca.crt 文件。
在 Kubernetes 集群外	本地开发环境需要连接至集群内的服务	手动下载证书：使用第二步中的 kubectl 命令将证书文件下载到本地，然后在代码中通过 os.ReadFile 等方式加载。
