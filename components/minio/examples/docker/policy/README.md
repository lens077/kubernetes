## 业界标准架构
桶策略读写分离 (Public Read / Private Write) + 预签名上传 (Presigned PUT) + CDN/Nginx 反向代理与缓存”。

这种方案不仅安全性极高（未经授权绝不可能上传或覆盖），而且图片的 URL 是永久有效的，前端展示时零 Backend/MinIO CPU 消耗，轻松应对大并发。

核心架构设计 [ 商家上传流程 ]
1. 商家前端 ──(携带 JWT)──> Go 后端 (验证权限)
2. Go 后端 ──────────────> 生成 Presigned PUT URL (5分钟有效)
3. 商家前端 ──(PUT 直传)──> MinIO (完成文件写入)
4. 商家前端 ──────────────> 将相对路径 (如 products/spu-123.jpg) 存入数据库

[ 消费者浏览流程 ]
消费者前端 ───────────────> Nginx / CDN 缓存 ───────────────> MinIO (公开 ReadOnly)
(直接通过静态永久 URL 加载)
具体实现步骤第一步：配置 MinIO 桶策略（读写分离）在 MinIO 中将存储桶（例如名为 shop-public）设置为 Public Read（只读）。读权限 (s3:GetObject)：对所有人开放，无需任何 Signature，直接访问静态 URL 即可获取图片。写/删权限 (s3:PutObject, s3:DeleteObject)：严格保持私有，必须携带凭证或使用后端生成的预签名 URL。方式 A：在 MinIO Console 可视化界面设置进入 MinIO 控制台 $\rightarrow$ Buckets $\rightarrow$ 选择 shop-public $\rightarrow$ Access Rules $\rightarrow$ 添加一条 Rule：Prefix: *, Access: readonly。方式 B：设置 JSON Policy（粒度更精细）
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "*"
        ]
      },
      "Action": [
        "s3:GetObject"
      ],
      "Resource": [
        "arn:aws:s3:::shop-public/*"
      ]
    }
  ]
}
```

## 第二步：Go 后端生成“预签名上传 URL” (Presigned PUT)当有权限的商家要上传图片时，向 Go 后端请求一个用于上传的临时链接。
```go
// Go 后端生成 Presigned PUT URL
func (s *UploadService) GetUploadUrl(ctx context.Context, objectName string) (string, error) {
// 设置上传链接 10 分钟内有效
expiry := time.Minute * 10

    // 生成 PUT 预签名 URL
    presignedURL, err := s.minioClient.PresignedPutObject(
        ctx,
        "shop-public",             // Bucket 名称
        objectName,                // 对象路径, 如: products/2026/07/uuid.jpg
        expiry,
    )
    if err != nil {
        return "", err
    }
    return presignedURL.String(), nil
}
```
前端收到这个 presignedURL 后，直接使用 fetch 或 axios 以 PUT 方式将文件二进制数据推送到 MinIO，完全不经过 Go 后端转移流量。

## 第三步：数据库存储与环境隔离（本地 vs 上线）

数据库千万不要存绝对路径（比如 http://localhost:9000/...），只存相对 Key。数据库存入：products/2026/07/a1b2c3d4.jpg
前后端通过环境变量动态拼接：本地开发环境 (.env.local)：MEDIA_BASE_URL = http://localhost:9000/shop-public/图片完整 URL：http://localhost:9000/shop-public/products/2026/07/a1b2c3d4.jpg线上生产环境 (.env.prod)：MEDIA_BASE_URL = [https://media.yourdomain.com/](https://media.yourdomain.com/)图片完整 URL：[https://media.yourdomain.com/products/2026/07/a1b2c3d4.jpg](https://media.yourdomain.com/products/2026/07/a1b2c3d4.jpg)

## 第四步：应对大并发与生产加固 (Nginx / CDN)
在生产环境中，绝不要让客户端直接访问 MinIO 的 9000 端口。套一层 Nginx 反向代理：隐藏 MinIO 真实端口与架构，统一域名和 SSL 证书。边缘缓存 (CDN)：由于图片 URL 是长期的且公开只读，你可以在 Cloudflare 或阿里云 CDN 上设置静态资源缓存规则（如 Cache-Control: max-age=31536000）。效果：99% 的图片访问流量全部命中 CDN/Nginx 缓存，MinIO 本身的并发压力降为接近 0，后端 CPU 没有任何预签名计算开销。
