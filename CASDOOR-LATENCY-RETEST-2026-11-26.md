# casdoor.apikv.com 分段计时复测报告（2026-11-26）

> 目的：对最初 5 项需求里唯一还挂着"未根治"的 **casdoor 响应慢** 做决定性复测，把结论定下来。
> 方法：从三个视角做 curl 分段计时（DNS / TCP / TLS / TTFB / total），找出耗时落在哪一段。

## 1. 测量环境

- 被测：`https://casdoor.apikv.com/login`（200，7901 B），node3 上的 casdoor 4.30.0 容器。
- 链路：`公网用户 → node3 edge(pangolin/traefik + crowdsec + safeline) → casdoor:8000 → pg.apikv.com:52288`。
- 关键拓扑事实（已核实）：casdoor 容器 `/etc/hosts` 有静态映射 `172.18.0.1 pg.apikv.com`，走 docker bridge 网关内网；`socks5Proxy` 已清空；PG 是 node3 本机 `postgres:18.6`。
- 注意：WorkBuddy 宿主注入了代理 `127.0.0.1:54244`，Mac 侧测量统一用 `curl --noproxy '*'` 绕开，测真实公网路径。

## 2. 分段计时结果

### 视角 A：Mac 直连公网（真实外部用户路径，20 次采样）

```
dns=0.002s  tcp=0.022-0.034s  tls=0.044-0.070s  ttfb=0.077-0.112s
P50=0.094s  P95=0.114s  max=0.114s  min=0.084s   全部 200
```

拆解：DNS 2ms + TCP ~25ms（公网 RTT）+ TLS ~20ms（Pangolin 边缘证书）+ 服务端/edge 处理 ~25ms = **端到端 ~94ms**。无长尾、无失败。

### 视角 B：node3 本机经公网域名（走边缘栈回环）

```
dns=0.002-0.040s（首次 6ms，偶发 30-40ms；缓存后 0.2ms）
tcp=0.004-0.041s  tls=0.013-0.053s  ttfb=0.028-0.069s
```

HTTP（无 TLS）对照：`http://casdoor.apikv.com/login` → 302，总耗时仅 **3.6-5.2ms**（DNS 1-2ms）。

结论：node3 经域名访问时那 20-60ms 的波动，**主要来自系统 resolver 偶发卡顿（30-40ms）**，其次是 TLS 握手 ~13ms；edge 栈本身（HTTP 302）只占 2-3ms。

### 视角 C：node3 本机直连容器 `127.0.0.1:8000`（绕过 edge/TLS）

```
/login     ttfb=5.9-9.5ms   （5 次）
/api/...   ttfb=2.4-2.9ms   （10 次，无长尾）
```

### 视角 D：后端 PG

- PG TLS 握手（宿主机 → `172.18.0.1:52288`，verify-full 同路径）：**~20ms/次**（本地回环连 docker 网关 + TLS 协商）。
- 历史实测 SQL 执行 1-2ms；`/api/get-account` 端到端 2.4-2.9ms，说明 PG 查询没有拖慢。

## 3. 结论（定案）

**casdoor 当前不慢，最初的"响应慢"主诉在现状下不成立。** 证据：

1. 外部真实用户路径 P50 **94ms**、P95 **114ms**，属于正常范围，20 次采样无一次超 150ms、无失败。
2. 服务端自身处理极快：本地直连 `/login` 6-9ms、`/api` 2.4-2.9ms；PG 查询 1-2ms。慢的部分是**公网 RTT + TLS**，不是应用或数据库。
3. 早期怀疑的两点均已排除：
   - DB 连接串走公网回环 → 错，实际是 `/etc/hosts` 静态映射到 docker 网关内网，DNS 零开销（视角 C/D 证实）。
   - `socks5Proxy` 死代理 → 已清空，且 4 个 provider 均 `enable_proxy=f`，本就没走代理。
4. node3 本机经域名时的偶发 30-40ms 抖动来自 **系统 DNS resolver**，仅影响 node3 本机自己经公网域名访问的场景；对外部用户无影响（外部 DNS 在客户端侧）。

**遗留隐患（不影响"慢"的结论，但应处理）**：
- casdoor/gorse 的 `pg_dump` 备份停在 2026-11-11（约 14 天未更新），缺每日备份 timer —— 这是数据安全的真问题，建议补一个 systemd timer。

## 4. 与最初需求的收口

最初 5 项里：
- ✅ newt/主控升级、✅ 服务版本检查、✅ node3 本地 PG 评估（已是现状）、⏸ PG19（等 CNPG 1.31）。
- ✅ **casdoor 响应慢：本次复测定案为"不慢"**，主诉关闭；仅保留备份 timer 一项待办。

## 5. 测量命令备查

```bash
# Mac 外部视角（绕开宿主代理）
curl --noproxy '*' -s -o /dev/null -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n' https://casdoor.apikv.com/login

# node3 本机经 edge / 直连容器
ssh node3 'curl -s -o /dev/null -w "%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n" https://casdoor.apikv.com/login'
ssh node3 'curl -s -o /dev/null -w "%{time_starttransfer} %{time_total}\n" http://127.0.0.1:8000/login'
```
