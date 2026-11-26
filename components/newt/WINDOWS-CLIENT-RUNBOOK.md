# Windows 开发机接入 Pangolin（newt 客户端）—— Agent 执行手册

> 给执行 agent：照顺序做完 1–7 步即交付。**不要跳过第 3 步的凭据落盘**，
> secret 只在创建站点那一刻回显一次，之后面板不再返回，丢了只能删站点重建。
> 目标：Windows 开发机跑 newt 客户端，面板出现一个 `online=1` 的站点，
> 远程可通过 Pangolin 访问这台机器上的服务（RDP / HTTP 开发服务 / SSH 等）。

## 0. 先读这里：版本线与现状

| 项 | 值 |
|---|---|
| Pangolin 服务端 | **1.27.1**（node3，控制面） |
| newt 客户端 | **1.20.1**（独立版本线，没有 1.27.1 这个号） |
| 面板地址 | `https://pangolin.apikv.com`，org=`main` |
| 管理员凭据 | 执行机本地 `~/.pangolin-admin.env`（`PANGOLIN_ADMIN_EMAIL` / `PANGOLIN_ADMIN_PASSWORD`，**不入库**） |
| 现有站点 | node1-local=1, node2=5, mac=6, k8s-cluster=11, k1=12, k2=13, k3=14, node3=15, node4=16, node5=17, node6=18 |

**命名约定**：站点 `name` 与 `niceId` 都用同一台机器名（例如 `win-dev`），
不要复用已有名字（会互相顶替）。先问用户确认机器名和要暴露的端口。

**Windows 产物**（1.20.1 release）：`newt_windows_amd64.exe`（大小以 release 页面为准）与
`newt_windows_installer.exe`（17,743,104 B）。官方推荐 installer；本手册用**手动 exe + NSSM 注册服务**，
因为 installer 是否静默装服务未经本集群验证，而 NSSM 可控、可查、可回滚。

---

## 1. 收集信息（缺一不可）

向用户/目标机确认：

- [ ] 机器名 `SITE`（如 `win-dev`），面板上唯一
- [ ] Windows 版本与架构（几乎都是 amd64；`[Environment]::Is64BitOperatingSystem`）
- [ ] 要暴露什么：RDP 3389？某开发服务端口？还是只要隧道通、资源以后再建
- [ ] 该机是否能访问公网 `https://pangolin.apikv.com`（必须能出网 443）
- [ ] 执行 agent 的位置：能在自己机器跑 ssh/curl 操作面板，且**能登录 Windows 机**（WinRM / RDP / 用户自行执行）

> 如果执行 agent 无法直接操作 Windows 机，把第 4–5 步整理成 PowerShell 脚本交给用户在目标机上以管理员身份运行。

---

## 2. 登录面板（拿 cookie）

在**有 `~/.pangolin-admin.env` 的机器**上：

```bash
set -a; source ~/.pangolin-admin.env; set +a
COOKIE=$(mktemp)
curl -s -b "$COOKIE" -c "$COOKIE" \
  -X POST https://pangolin.apikv.com/api/v1/auth/login \
  -H 'Content-Type: application/json' -H 'x-csrf-token: x-csrf-protection' \
  -d "{\"email\":\"$PANGOLIN_ADMIN_EMAIL\",\"password\":\"$PANGOLIN_ADMIN_PASSWORD\"}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["success"], d; print("login ok")'
```

所有后续请求都要带 `-b "$COOKIE" -c "$COOKIE" -H 'x-csrf-token: x-csrf-protection'`。

**先确认站点不存在**：

```bash
curl -s -b "$COOKIE" -c "$COOKIE" -H 'x-csrf-token: x-csrf-protection' \
  https://pangolin.apikv.com/api/v1/org/main/sites \
| python3 -c 'import json,sys; print([s["niceId"] for s in json.load(sys.stdin)["data"]["sites"]])'
```

若 `SITE` 已在列表里：**要么换名字，要么先确认目标机上还有没有凭据**（面板不回显 secret，
已有站点拿不到 secret）。本手册按「新建站点」走。

---

## 3. 创建站点并立刻落盘凭据（关键）

```bash
SITE=win-dev          # ← 改成实际机器名
RESP=$(curl -s -b "$COOKIE" -c "$COOKIE" -X PUT \
  https://pangolin.apikv.com/api/v1/org/main/site \
  -H 'Content-Type: application/json' -H 'x-csrf-token: x-csrf-protection' \
  -d "{\"name\":\"$SITE\",\"niceId\":\"$SITE\",\"type\":\"newt\"}")
echo "$RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["success"], d; x=d["data"]; print("siteId=%s newtId=%s"%(x["siteId"],x["newtId"]))'
```

**立刻**把响应里的 `siteId` / `newtId` / `secret` 提取出来，写进一次性凭据文件，权限 600：

```bash
python3 - "$SITE" <<'PY' > /tmp/newt-site.env
import json,sys
raw=sys.stdin.read()
PY
# 更稳妥：把上面的 $RESP 存到临时文件再解析（secret 不要打到终端历史）
printf '%s' "$RESP" > /tmp/site-resp.json
python3 - <<'PY' > /tmp/newt-site.env
import json, os
d=json.load(open('/tmp/site-resp.json'))['data']
print("NEWT_ID=%s" % d['newtId'])
print("NEWT_SECRET=%s" % d['secret'])
print("PANGOLIN_ENDPOINT=https://pangolin.apikv.com")
print("SITE_ID=%s" % d['siteId'])
PY
chmod 600 /tmp/newt-site.env
shred -u /tmp/site-resp.json 2>/dev/null || rm -f /tmp/site-resp.json
```

> ⚠️ **secret 只回显这一次**。确认 `/tmp/newt-site.env` 里有非空 `NEWT_SECRET` 再继续。
> 若已经丢了：面板删除该站点（`DELETE https://pangolin.apikv.com/api/v1/site/<siteId>`）后重跑本节。
> 一份凭据只应有一个进程在用，两个进程会互相顶替连接。

---

## 4. Windows 上安装 newt（管理员 PowerShell）

把第 3 步的凭据安全传到 Windows 机（建议用带外方式/凭据管理工具，不要明文留在聊天记录、脚本仓库或共享目录）。
在目标机开**管理员 PowerShell**：

```powershell
$ErrorActionPreference = "Stop"
$NEWT_VERSION = "1.20.1"
$InstallDir   = "C:\Program Files\Newt"
$Bin          = "$InstallDir\newt.exe"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# GitHub 直连不通时用代理前缀（本集群云机实测 ghfast.top 可用；Windows 机自行验证）
$Url = "https://ghfast.top/https://github.com/fosrl/newt/releases/download/$NEWT_VERSION/newt_windows_amd64.exe"
Invoke-WebRequest -Uri $Url -OutFile "$Bin" -UseBasicParsing

# 版本校验：必须输出 "Newt version 1.20.1"
& $Bin --version
```

若代理也不通，改直连 `https://github.com/fosrl/newt/releases/download/1.20.1/newt_windows_amd64.exe`。

**凭据落盘**（把 `NEWT_ID` / `NEWT_SECRET` 换成第 3 步的真实值）：

```powershell
$ConfDir = "C:\ProgramData\Newt"
New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
@"
NEWT_ID=__NEWT_ID__
NEWT_SECRET=__NEWT_SECRET__
PANGOLIN_ENDPOINT=https://pangolin.apikv.com
"@ | Set-Content -Path "$ConfDir\newt.env" -Encoding ASCII
# 收紧权限：仅 SYSTEM 与 Administrators
icacls "$ConfDir" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"
```

**先前台跑一次**验证握手（Ctrl-C 停掉）：

```powershell
$env:NEWT_ID = "__NEWT_ID__"; $env:NEWT_SECRET = "__NEWT_SECRET__"
$env:PANGOLIN_ENDPOINT = "https://pangolin.apikv.com"
& $Bin
# 期望看到：Server version: 1.27.1
#           Tunnel connection to server established successfully!
```

---

## 5. 注册为 Windows 服务（开机自启）

用 NSSM（Windows 上把任意 exe 包成服务的事实标准）：

```powershell
# 若已装 chocolatey: choco install nssm -y
# 否则从 https://nssm.cc/download 解压，取 win64\nssm.exe
$nssm = "C:\Tools\nssm\win64\nssm.exe"

& $nssm install NewtClient "$Bin"
& $nssm set NewtClient AppDirectory "$InstallDir"
& $nssm set NewtClient DisplayName "Pangolin Newt Client"
& $nssm set NewtClient Start SERVICE_AUTO_START
& $nssm set NewtClient AppStdout "$ConfDir\stdout.log"
& $nssm set NewtClient AppStderr "$ConfDir\stderr.log"
& $nssm set NewtClient AppRotateFiles 1
& $nssm set NewtClient AppRotateBytes 10485760     # 10MB 轮转，避免日志无限增长
& $nssm set NewtClient AppEnvironmentExtra "NEWT_ID=__NEWT_ID__" "NEWT_SECRET=__NEWT_SECRET__" "PANGOLIN_ENDPOINT=https://pangolin.apikv.com"
& $nssm start NewtClient
Get-Service NewtClient        # 期望 Running
```

> newt 会自动读 `NEWT_ID` / `NEWT_SECRET` / `PANGOLIN_ENDPOINT` 环境变量，
> 所以服务参数不用再重复 `--id --secret --endpoint`（Linux 的 systemd 单元也是这个约定）。
> 若 NSSM 不可用，退路是用任务计划程序建「启动时触发、最高权限、失败自动重启」的任务。

---

## 6. 验证（三项都过才算完成）

**① 本机服务与日志**

```powershell
Get-Service NewtClient
Get-Content "$ConfDir\stdout.log" -Tail 20
# 期望：Newt version 1.20.1 / Server version: 1.27.1 /
#       Tunnel connection to server established successfully!
```

**② 面板站点 online**（在有凭据的机器上）

```bash
curl -s -b "$COOKIE" -c "$COOKIE" -H 'x-csrf-token: x-csrf-protection' \
  https://pangolin.apikv.com/api/v1/org/main/sites \
| python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["sites"]; s=[x for x in d if x["niceId"]=="win-dev"]; assert s, "站点未创建"; print(s[0]["siteId"], s[0]["online"])'
# 期望 (19, True) 之类：siteId 已分配、online=True
```

**③ 服务端 DB 直读**（node1 上，可选交叉验证）

```bash
ssh node1 'python3 /root/check_sites.py' | grep win-dev
```

> **判据是隧道握手 + 面板 online，不是「服务 Running」**。日志里
> `auth-daemon is only supported on Linux, not darwin` 这类平台 WARN 可忽略。

---

## 7. 让远程能访问（建资源，按需要二选一）

站点 online 只代表隧道通了，**还要在面板建资源**才有实际访问入口。

### 方案 A：面板 UI（推荐，最不容易出错）

1. 打开 `https://pangolin.apikv.com` → Resources → New
2. HTTP 资源（访问 Windows 上的 web 开发服务）：
   - Type = `HTTP`；Subdomain 填想要的（如 `windev`）；Domain = `apikv.com`
   - Target site 选刚建的 `win-dev`；Target IP 填 **`127.0.0.1`**（相对 newt 客户端本机）
   - Target Port 填开发服务端口（如 `3000`）
3. TCP 资源（RDP / SSH 等）：
   - Type = `TCP`；Pangolin 会分配一个 `proxyPort`（参考现有 `argocd-grpc`=30002、`kafka-dev`=30004）
   - Target site 选 `win-dev`；Target IP `127.0.0.1`；Target Port 填 `3389`（RDP）或 `22`
   - 远程用 `pangolin.apikv.com:<proxyPort>` 连接

> **Target IP 的含义**：newt 是反向代理，target 里的 IP 是**从 Windows 机器自身看**的地址，
> 所以本机服务一律写 `127.0.0.1`，不要写 Windows 的公网/内网 IP。

### 方案 B：API（已实测的两个端点，慎用）

```bash
# 建 TCP 资源（proxyPort 必填且不能与现有 30001-30005 冲突；domainId 可传空串）
curl -s -b "$COOKIE" -c "$COOKIE" -X PUT \
  https://pangolin.apikv.com/api/v1/org/main/resource \
  -H 'Content-Type: application/json' -H 'x-csrf-token: x-csrf-protection' \
  -d '{"name":"win-dev-rdp","mode":"tcp","proxyPort":30006,"domainId":""}'
# 返回 data.resourceId

# 绑 target（siteId 用第 3 步的；ip/port 从 Windows 本机视角）
curl -s -b "$COOKIE" -c "$COOKIE" -X PUT \
  https://pangolin.apikv.com/api/v1/resource/<resourceId>/target \
  -H 'Content-Type: application/json' -H 'x-csrf-token: x-csrf-protection' \
  -d '{"siteId":<siteId>,"ip":"127.0.0.1","port":3389}'
```

校验失败不会落库（例如缺 `proxyPort`、`port` 字段名写错都会 400），
但**成功会真创建**，所以先在测试环境确认参数，建完用
`GET /org/main/resources` 复核；建错了用
`DELETE https://pangolin.apikv.com/api/v1/resource/<resourceId>` 与
`DELETE https://pangolin.apikv.com/api/v1/target/<targetId>` 清理。

---

## 8. 常见坑（按踩过概率排序）

| 坑 | 表现 | 处理 |
|---|---|---|
| **secret 没存下来** | 面板 API 再也拿不到 | 删站点重建（第 3 步），先确保旧 newt 进程已停，否则互相顶替 |
| **两份凭据同时在线** | 隧道反复断、online 抖动 | 只允许一个进程；服务装好后不要再前台手动跑 |
| **target IP 写成公网 IP** | 远程连不上但隧道 online | 用 `127.0.0.1`（相对 Windows 本机） |
| **Windows 防火墙挡本地端口** | 隧道通、访问超时 | 放行对应端口的入站规则；RDP 还要确认「远程桌面」已启用 |
| **日志无限增长** | 磁盘被吃 | NSSM 已配 `AppRotateBytes 10MB`；若用 installer，另配轮转 |
| **siteId 写错/复用旧名** | 远程看到的是别的机器 | 建站点前先 GET sites 查重；站点名与机器名一致 |
| **代理下载失败** | Invoke-WebRequest 超时 | 去掉 ghfast.top 前缀直连 GitHub；或让用户浏览器下载后拷贝 |
| **升服务端后客户端告警** | `Newt ping with outdated config version` | 客户端保持 1.20.1；只升服务端会有此告警，成对升级即可 |

---

## 9. 回滚 / 卸载

```powershell
Stop-Service NewtClient
& $nssm remove NewtClient confirm
Remove-Item -Recurse -Force "C:\Program Files\Newt", "C:\ProgramData\Newt"
```

面板侧（在有凭据的机器上）：

```bash
curl -s -b "$COOKIE" -c "$COOKIE" -X DELETE \
  https://pangolin.apikv.com/api/v1/site/<siteId> -H 'x-csrf-token: x-csrf-protection'
```

以及删掉第 7 步建的资源与 target（若建过）。

---

## 10. 交付清单（agent 完成后逐条报告）

- [ ] `SITE` 名称、siteId、面板 `online=True`（附 API 或 DB 输出）
- [ ] Windows 上 `Newt version 1.20.1` 与握手日志片段（含 `Server version: 1.27.1`）
- [ ] 服务 `NewtClient` = Running、开机自启、日志有 10MB 轮转
- [ ] 凭据落盘路径与权限（不要回显 secret 本身）
- [ ] 若建了资源：资源类型、subdomain/proxyPort、target site/port、远程实测结果
- [ ] 任何偏离本手册的地方（例如 installer 替代 NSSM、直连替代代理）
