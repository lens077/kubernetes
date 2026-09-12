#!/usr/bin/env python3
"""
harvest.py —— 把组件契约(地址/凭据/CA)按 mapping.yaml 写进 Config Center 各服务的 bootstrap.yaml。

由 tools/config-center-harvest.sh 调用(它负责 bash 侧的环境加载与契约收集), 也可直接执行:

  CC_CONTRACTS_JSON="$(bash tools/verify-contracts.sh --json)" \
  python3 tools/config-center/harvest.py --env pre --dry-run

  python3 tools/config-center/harvest.py --check-mapping      # 离线: 映射路径 ↔ control-tower schema 门禁

流程(每个服务): GetKey 现值 → 按 schema $defs 判断需要哪些能力 → 只改映射里的路径(其余字节不动)
→ 重新序列化后与「原值+补丁」等价自检 → JSON Schema 校验 → 脱敏 diff → PutKey(管理 token)
→ [可选]签发 machine token → 更新 selector Secret → 滚动 Deployment。

凭据边界: 凭据只在本进程与集群 Secret / Config Center 之间流动; 不打印明文, 不落盘。
需要: python3 + PyYAML(节点已有); jsonschema 可选(没有则跳过 schema 校验并警告)。
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any

import yaml

try:  # 可选依赖
    import jsonschema  # type: ignore
except Exception:  # pragma: no cover
    jsonschema = None

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_SERVICES = "address behavior cart inventory merchant order payment product search user"
KEY = "bootstrap.yaml"
SECRET_FIELDS = ("password", "client_secret", "api_key", "certificate", "ca_pem", "token", "service_token")


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def die(msg: str, code: int = 1) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] ✘ {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


# ----------------------------------------------------------------------------- kubectl

def kubectl(*args: str, input_: str | None = None) -> str:
    env = dict(os.environ)
    cmd = ["kubectl", *args]
    r = subprocess.run(cmd, input=input_, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def read_secret(ns_name: str) -> dict[str, str]:
    ns, name = ns_name.split("/", 1)
    raw = json.loads(kubectl("-n", ns, "get", "secret", name, "-o", "json"))
    return {k: base64.b64decode(v).decode() for k, v in (raw.get("data") or {}).items()}


def read_ca(ref: str) -> str:
    kind, rest = ref.split(":", 1)
    ns, rest = rest.split("/", 1)
    name, key = rest.split(":", 1)
    if kind == "secret":
        return read_secret(f"{ns}/{name}")[key]
    if kind == "configmap":
        raw = json.loads(kubectl("-n", ns, "get", "cm", name, "-o", "json"))
        return raw["data"][key]
    raise ValueError(f"CA_REF 格式错误: {ref}")


# ----------------------------------------------------------------------------- Config Center RPC

def admin_headers(token: str) -> dict[str, str]:
    """管理面凭据的两种形态: Casdoor 管理员 JWT(Bearer) 或 operator machine token(ct_ 前缀, 走 service-token 头; P4)。"""
    if token.startswith("ct_"):
        return {"x-config-center-service-token": token, "x-config-center-client-name": "config-center-harvest"}
    return {"Authorization": f"Bearer {token}"}


class ConfigCenter:
    def __init__(self, url: str):
        self.url = url.rstrip("/")

    def rpc(self, method: str, body: dict, headers: dict[str, str]) -> dict:
        req = urllib.request.Request(
            f"{self.url}/config.v1.ConfigService/{method}",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", **headers},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                out = json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            try:
                out = json.loads(e.read().decode())
            except Exception:
                out = {"code": str(e.code), "message": str(e)}
        if isinstance(out, dict) and out.get("code") is not None:
            raise RuntimeError(f"{method}: {out.get('code')}: {out.get('message')}")
        return out

    def get_key(self, ns: str, env: str, key: str, headers: dict[str, str]) -> dict:
        return self.rpc("GetKey", {"namespace": ns, "environment": env, "key": key}, headers)["entry"]

    def put_key(self, ns: str, env: str, key: str, value: str, admin: str, comment: str) -> dict:
        body = {
            "namespace": ns, "environment": env, "key": key, "format": "CONFIG_FORMAT_YAML",
            "value": value, "is_secret": False,  # true 时管理面脱敏、数据面读不到真值(pre-seed 踩过)
            "comment": comment, "description": "由 tools/config-center-harvest.sh 按组件契约生成",
        }
        return self.rpc("PutKey", body, admin_headers(admin))["entry"]

    def issue_token(self, service: str, env: str, note: str, admin: str) -> str:
        out = self.rpc("IssueMachineToken", {"service_name": service, "environment": env, "note": note},
                       admin_headers(admin))
        tok = out.get("token")
        if not tok:
            raise RuntimeError(f"{service}: IssueMachineToken 未返回 token")
        return tok


# ----------------------------------------------------------------------------- 契约 → 值

class Provider:
    """一个能力的提供方(来自 verify-contracts --json 的一行)。值按需懒加载, 只加载一次。"""

    def __init__(self, contract: dict, env: str, overrides: dict):
        self.c = contract
        self.env = env
        self.overrides = overrides.get(contract["provides"], {}) or {}
        self._cred: dict[str, str] | None = None
        self._ca: str | None = None
        self.cred_err = ""
        self.ca_err = ""

    @property
    def addr(self) -> dict:
        return self.c["pre"] if self.env == "pre" else self.c["dev"]

    def cred(self) -> dict[str, str]:
        if self._cred is None:
            sec = self.c["cred"]["secret"]
            try:
                self._cred = read_secret(sec) if sec else {}
            except RuntimeError as e:
                self.cred_err = f"凭据 Secret {sec} 不存在或读不到(ESO 未物化?)"
                self._cred = {}
        return self._cred

    def ca(self) -> str | None:
        if self._ca is None and self.c.get("ca_ref"):
            try:
                self._ca = read_ca(self.c["ca_ref"]).strip()
            except (RuntimeError, KeyError) as e:
                self.ca_err = f"CA_REF {self.c['ca_ref']} 不存在或缺键"
        return self._ca

    def resolve(self, src: str) -> tuple[bool, Any]:
        """返回 (有值?, 值)。"""
        a = self.addr
        scheme = a["scheme"]
        if src == "address.host":
            return True, a["host"]
        if src == "address.port":
            return True, a["port"]
        if src == "address.hostport":
            return True, f"{a['host']}:{a['port']}"
        if src == "address.scheme":
            return True, scheme
        if src == "address.tls":
            return True, scheme in ("https", "rediss", "grpcs")
        if src == "address.url":
            default_port = {"https": 443, "http": 80}.get(scheme)
            return True, f"{scheme}://{a['host']}" + ("" if a["port"] == default_port else f":{a['port']}")
        if src == "ca.pem":
            ca = self.ca()
            return (ca is not None), ca
        if src == "cred.user":
            u = self.c["cred"].get("user")
            if u:
                return True, u
            cred = self.cred()
            for k in ("user", "username"):
                if cred.get(k):
                    return True, cred[k]
            return False, None
        if src.startswith("cred."):
            key = src[5:]
            cred = self.cred()
            return (key in cred and cred[key] != ""), cred.get(key)
        if src.startswith("overrides."):
            key = src[10:]
            return (key in self.overrides), self.overrides.get(key)
        raise ValueError(f"未知的值来源 {src}")


def deep_get(doc: dict, path: str) -> tuple[bool, Any]:
    cur: Any = doc
    for p in path.split("."):
        if not isinstance(cur, dict) or p not in cur:
            return False, None
        cur = cur[p]
    return True, cur


def deep_set(doc: dict, path: str, value: Any) -> None:
    parts = path.split(".")
    cur = doc
    for p in parts[:-1]:
        nxt = cur.get(p)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[p] = nxt
        cur = nxt
    cur[parts[-1]] = value


def is_secret_path(path: str) -> bool:
    last = path.rsplit(".", 1)[-1]
    return last in SECRET_FIELDS


def mask(path: str, v: Any) -> str:
    if v is None:
        return "<缺失>"
    if is_secret_path(path):
        s = v if isinstance(v, str) else json.dumps(v)
        return f"<len={len(s)}>"
    s = v if isinstance(v, str) else json.dumps(v)
    return s if len(s) <= 80 else s[:77] + "..."


# ----------------------------------------------------------------------------- YAML 往返

class Dumper(yaml.SafeDumper):
    pass


def _str_presenter(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


Dumper.add_representer(str, _str_presenter)


def dump_yaml(doc: dict) -> str:
    return yaml.dump(doc, Dumper=Dumper, allow_unicode=True, sort_keys=False, width=4096)


# ----------------------------------------------------------------------------- 主流程

def load_schema(schemas_dir: str, svc: str) -> dict | None:
    p = os.path.join(schemas_dir, svc, "bootstrap.schema.json")
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def needed_caps(schema: dict | None, mapping: dict) -> list[str]:
    """schema 的 $defs 里出现 schema_marker 的能力才需要填。"""
    if schema is None:
        return []
    defs = set(schema.get("$defs", {}).keys())
    return [cap for cap, m in mapping.items() if f"{m['schema_marker']}.schema.json" in defs]


def check_mapping(mapping: dict, schemas_dir: str) -> int:
    """离线门禁: 映射里每条路径都必须能在对应 $def 的 properties 链里找到。"""
    bad = 0
    services = sorted(d for d in os.listdir(schemas_dir) if os.path.isdir(os.path.join(schemas_dir, d)))
    if not services:
        die(f"{schemas_dir} 下没有 schema")
    for svc in services:
        schema = load_schema(schemas_dir, svc)
        if schema is None:
            continue
        defs = schema["$defs"]
        root = defs.get("conf.v1.Bootstrap.schema.json")

        def walk(path: str) -> bool:
            node = root
            for p in path.split("."):
                props = (node or {}).get("properties", {})
                if p not in props:
                    return False
                nxt = props[p]
                if "$ref" in nxt:
                    ref = nxt["$ref"].split("/")[-1]
                    node = defs.get(ref)
                else:
                    node = nxt
            return True

        for cap in needed_caps(schema, mapping):
            m = mapping[cap]
            for block in ("fields", "fields_pre", "fields_dev"):
                for path in (m.get(block) or {}):
                    if not walk(path):
                        print(f"✘ {svc}: {cap}.{block} 的路径 {path} 在 schema 里不存在")
                        bad += 1
    if bad == 0:
        print(f"✔ 映射门禁通过: {len(services)} 个服务的 schema 都能覆盖映射路径")
    return 1 if bad else 0


def extract_externals(cc: "ConfigCenter", mapping: dict, providers: dict, services: list[str],
                      env: str, admin: str, svc_tokens: dict[str, str]) -> int:
    """反向映射: 对每个外部提供方, 把映射里 from: cred.<k> / ca.pem / overrides.<k> 的路径从现值里读出来。
    输出 {"<id>": {"<k>": v, "ca.crt": pem}, "_overrides": {"<cap>": {...}}}; 凭据只进 stdout(由调用方直接管进 OpenBao)。"""
    out: dict[str, dict] = {"_overrides": {}}
    docs: dict[str, dict] = {}
    for svc in services:
        headers = admin_headers(admin) if admin else (
            {"x-config-center-service-token": svc_tokens[svc]} if svc in svc_tokens else None)
        if headers is None:
            continue
        try:
            docs[svc] = yaml.safe_load(cc.get_key(svc, env, KEY, headers).get("value") or "") or {}
        except RuntimeError as e:
            log(f"⚠ {svc}: {e}")
    for cap, p in providers.items():
        if not p.c.get("external") or cap not in mapping:
            continue
        m = mapping[cap]
        fields: dict = dict(m.get("fields") or {})
        fields.update(m.get(f"fields_{env}") or {})
        bucket: dict = {}
        for path, spec in fields.items():
            src = spec.get("from", "")
            key = None
            if src.startswith("cred."):
                key = src[5:]
            elif src == "ca.pem":
                key = "ca.crt"
            elif src.startswith("overrides."):
                for d in docs.values():
                    ok, v = deep_get(d, path)
                    if ok and v not in (None, ""):
                        out["_overrides"].setdefault(cap, {})[src[10:]] = v
                        break
                continue
            else:
                continue
            for d in docs.values():
                ok, v = deep_get(d, path)
                if ok and v not in (None, ""):
                    bucket[key] = v if isinstance(v, str) else json.dumps(v)
                    break
            # cred.user: 契约里 CRED_USER 已给固定值就不必进 OpenBao
            if key == "user" and p.c["cred"].get("user"):
                bucket.pop("user", None)
        if bucket:
            out[p.c["id"]] = bucket
        else:
            log(f"⚠ {p.c['id']}: 现值里找不到 {cap} 的任何凭据字段")
    print(json.dumps(out, ensure_ascii=False))
    return 0


def apply_caps(doc: dict, orig: dict, caps: list[str], mapping: dict, prov: dict, env: str,
               dry_run: bool, who: str) -> tuple[list[tuple[str, Any, Any]], list[str]]:
    """对一份文档按能力映射打补丁(只改映射路径)。返回 (changes, unresolved)。非 dry-run 时缺值直接 die。"""
    changes: list[tuple[str, Any, Any]] = []
    unresolved: list[str] = []
    for cap in caps:
        m = mapping[cap]
        fields: dict = dict(m.get("fields") or {})
        fields.update(m.get(f"fields_{env}") or {})
        p = prov[cap]
        for path, spec in fields.items():
            has_old, old = deep_get(doc, path)
            if "const" in spec:
                new = spec["const"]
            elif "default" in spec:
                if has_old:
                    continue
                new = spec["default"]
            else:
                ok, new = p.resolve(spec["from"])
                if not ok:
                    if spec.get("optional"):
                        continue
                    if spec["from"].startswith("overrides."):
                        reason = f"overrides 文件缺少 {cap}.{spec['from'][10:]}(--overrides / CC_OVERRIDES)"
                    else:
                        err = p.ca_err if spec["from"] == "ca.pem" else p.cred_err
                        reason = f"{cap}({p.c['id']}) 的 {spec['from']}: " + (err or "契约没声明 CRED_SECRET/CA_REF 或键不存在")
                    if dry_run:
                        unresolved.append(f"{path} ← {reason}")
                        continue
                    die(f"{who}: {path}: {reason}")
            if has_old and (old == new or (isinstance(old, str) and isinstance(new, str) and old.strip() == new.strip())):
                continue
            deep_set(doc, path, new)
            deep_set(orig, path, new)
            changes.append((path, old if has_old else None, new))
    return changes, unresolved


def harvest_secret_consumer(name: str, spec: dict, mapping: dict, providers: dict, providers_all: dict, args) -> int:
    """kind: secret 的消费方: 读 K8s Secret 里的 YAML 键 → 按 caps 打补丁 → 写回 → 滚动。"""
    if spec.get("kind") != "secret":
        die(f"consumers.{name}.kind={spec.get('kind')} 不支持(目前只有 secret)")
    ns, sec = spec["secret"].split("/", 1)
    key = spec["key"]
    caps = list(spec.get("caps") or [])
    prov = dict(providers)
    for cap, pid in (spec.get("providers") or {}).items():
        if pid not in providers_all:
            die(f"consumers.{name}.providers.{cap}={pid} 不是启用的提供方(components/*/component.env 或 _external/*)")
        if providers_all[pid].c["provides"] != cap:
            die(f"consumers.{name}.providers.{cap}={pid} 提供的是 {providers_all[pid].c['provides']}")
        prov[cap] = providers_all[pid]
    missing = [c for c in caps if c not in prov or c not in mapping]
    if missing:
        die(f"consumers.{name}: 能力 {' '.join(missing)} 没有提供方或映射")
    log(f"消费方 {name}: Secret {ns}/{sec} 键 {key} | 环境策略 {args.env} | 提供方 "
        + ", ".join(f"{c}←{prov[c].c['id']}" for c in caps) + (" | dry-run(只读)" if args.dry_run else ""))
    data = read_secret(f"{ns}/{sec}")
    if key not in data:
        die(f"{ns}/{sec} 没有键 {key}(有: {' '.join(sorted(data))})")
    cur_text = data[key]
    doc = yaml.safe_load(cur_text)
    orig = yaml.safe_load(cur_text)
    if not isinstance(doc, dict):
        die(f"{ns}/{sec}:{key} 不是映射结构")
    changes, unresolved = apply_caps(doc, orig, caps, mapping, prov, args.env, args.dry_run, name)
    if not changes:
        log(f"· {name}: 无差异" + (f"(另有 {len(unresolved)} 处待补齐)" if unresolved else ""))
        for r in unresolved:
            print(f"    待补齐: {r}")
        return 0
    new_text = dump_yaml(doc)
    if yaml.safe_load(new_text) != orig:
        die(f"{name}: 重新序列化后的配置与「原值+补丁」不等价, 拒绝写入")
    log(f"{name}: 改动 {len(changes)} 处" + (f", 待补齐 {len(unresolved)} 处" if unresolved else ""))
    for path, old, new in changes:
        print(f"    {path}: {mask(path, old)} → {mask(path, new)}")
    for r in unresolved:
        print(f"    待补齐: {r}")
    if args.dry_run:
        log("dry-run 结束: 未写 Secret、未滚动")
        return 0
    # 只改这一个键, 其余键(如 casdoor.pem)原样; 走 merge patch, 不重建 Secret
    patch = {"data": {key: base64.b64encode(new_text.encode()).decode()}}
    kubectl("-n", ns, "patch", "secret", sec, "--type=merge", "-p", json.dumps(patch))
    log(f"Secret {ns}/{sec}:{key} 已写入")
    if spec.get("restart") and not args.no_restart:
        rns, target = spec["restart"].split("/", 1)
        kubectl("-n", rns, "rollout", "restart", target)
        r = subprocess.run(["kubectl", "-n", rns, "rollout", "status", target, "--timeout=180s"], capture_output=True, text=True)
        log(("✔ " if r.returncode == 0 else "✘ 未就绪: ") + spec["restart"])
    return 0


def selector_tokens(ns: str, secret: str) -> dict[str, str]:
    """ecommerce-config-source-<env> Secret 里每个 <svc>.yaml 的 service_token。"""
    try:
        data = read_secret(f"{ns}/{secret}")
    except RuntimeError:
        return {}
    out = {}
    for k, v in data.items():
        if not k.endswith(".yaml"):
            continue
        doc = yaml.safe_load(v) or {}
        tok = ((doc.get("config_center") or {}).get("service_token"))
        if tok:
            out[k[:-5]] = str(tok)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default="pre", choices=("pre", "dev"), help="Config Center 环境 = 地址策略(pre 集群内 DNS / dev 网关域名+CA)")
    ap.add_argument("--services", default=os.environ.get("SERVICES", DEFAULT_SERVICES))
    ap.add_argument("--namespace", default=os.environ.get("ECOMMERCE_NAMESPACE", "ecommerce"))
    ap.add_argument("--mapping", default=os.path.join(HERE, "mapping.yaml"))
    ap.add_argument("--overrides", default=os.environ.get("CC_OVERRIDES", ""), help="非机密但无法推导的值(casdoor client_id 等), 0600, 不入库")
    ap.add_argument("--schemas-dir", default=os.environ.get("CC_SCHEMAS_DIR",
                    os.path.join(REPO_ROOT, "..", "control-tower", "services", "config", "internal", "schema", "schemas")))
    ap.add_argument("--contracts-file", default="", help="verify-contracts --json 的输出; 缺省读环境变量 CC_CONTRACTS_JSON")
    ap.add_argument("--cc-url", default=os.environ.get("CONFIG_CENTER_URL", ""))
    ap.add_argument("--admin-token-file", default=os.environ.get("ADMIN_TOKEN_FILE", "/root/.config-center-admin-token"))
    ap.add_argument("--admin-token-secret", default=os.environ.get("ADMIN_TOKEN_SECRET", ""), help="<ns>/<name>:<key>; P4 管理面服务账号 token 所在 Secret, 优先于文件")
    ap.add_argument("--dry-run", action="store_true", help="只读: 打印脱敏 diff, 不写 Config Center / Secret / Deployment")
    ap.add_argument("--rotate-tokens", action="store_true", help="为每个服务重新签发 machine token(默认沿用 selector Secret 里的)")
    ap.add_argument("--no-restart", action="store_true", help="写完不滚动 Deployment")
    ap.add_argument("--consumer", default="", help="只处理 mapping.yaml consumers.<名>(如 config-center: 目标是 K8s Secret 而不是 Config Center 键)")
    ap.add_argument("--check-mapping", action="store_true", help="离线门禁: 映射路径 ↔ schema, 不连集群")
    ap.add_argument("--extract-externals", action="store_true",
                    help="反向: 从 Config Center 现值抽出外部提供方(EXTERNAL=true)的凭据/CA, 以 JSON 打到 stdout 供 openbao-seed.sh 播种; 不写任何东西")
    ap.add_argument("--require-schema", action="store_true", help="没有 jsonschema 模块时报错而不是警告(schema 文件本身永远必需)")
    args = ap.parse_args()

    with open(args.mapping, encoding="utf-8") as f:
        mapping = yaml.safe_load(f) or {}
    consumers: dict = mapping.pop("consumers", {}) or {}
    schemas_dir = os.path.abspath(args.schemas_dir)

    if args.check_mapping:
        return check_mapping(mapping, schemas_dir)

    # ---- 契约 → 提供方
    raw = ""
    if args.contracts_file:
        with open(args.contracts_file, encoding="utf-8") as f:
            raw = f.read()
    else:
        raw = os.environ.get("CC_CONTRACTS_JSON", "")
    contracts = [json.loads(l) for l in raw.splitlines() if l.strip()]
    if not contracts:
        die("没有契约输入: 传 --contracts-file 或设 CC_CONTRACTS_JSON(bash tools/verify-contracts.sh --json)")
    overrides: dict = {}
    if args.overrides:
        if not os.path.isfile(args.overrides):
            die(f"overrides 文件不存在: {args.overrides}")
        with open(args.overrides, encoding="utf-8") as f:
            overrides = yaml.safe_load(f) or {}
    providers_all = {c["id"]: Provider(c, args.env, overrides) for c in contracts}
    providers = {c["provides"]: providers_all[c["id"]] for c in contracts if c.get("chosen", True)}
    unknown = [cap for cap in providers if cap not in mapping]
    if unknown:
        log(f"⚠ 有提供方但映射表没有对应能力(跳过): {' '.join(unknown)}")

    if args.consumer:
        if args.consumer not in consumers:
            die(f"mapping.yaml 没有 consumers.{args.consumer}(有: {' '.join(consumers) or '无'})")
        return harvest_secret_consumer(args.consumer, consumers[args.consumer], mapping, providers, providers_all, args)

    # ---- Config Center 与 token
    cc_url = args.cc_url
    if not cc_url:
        ip = kubectl("-n", "config-center", "get", "svc", "config-center", "-o", "jsonpath={.spec.clusterIP}").strip()
        cc_url = f"http://{ip}:30010"
    cc = ConfigCenter(cc_url)

    admin = ""
    if args.admin_token_secret:
        ns_name, key = args.admin_token_secret.rsplit(":", 1)
        admin = read_secret(ns_name).get(key, "").strip()
    elif os.path.isfile(args.admin_token_file):
        with open(args.admin_token_file, encoding="utf-8") as f:
            admin = f.read().strip()
    if not (args.dry_run or args.extract_externals) and not admin:
        die(f"缺少管理 token(--admin-token-secret 或 {args.admin_token_file}); 只读检查请加 --dry-run")

    ns = args.namespace
    selector = f"ecommerce-config-source-{args.env}"
    svc_tokens = selector_tokens(ns, selector)
    services = args.services.split()
    log(f"Config Center {cc_url} | 环境 {args.env} | 服务 {' '.join(services)} | 提供方 "
        + ", ".join(f"{cap}←{p.c['id']}" for cap, p in providers.items())
        + (" | dry-run(只读)" if args.dry_run else ""))

    if args.extract_externals:
        return extract_externals(cc, mapping, providers, services, args.env, admin, svc_tokens)

    schema_warned = False
    new_tokens: dict[str, str] = {}
    changed_services: list[str] = []
    pending_all: dict[str, list[str]] = {}
    for svc in services:
        # 1) 读现值: 优先管理 token(非 is_secret 键管理面也给真值), 否则用 selector 里的 service token
        if admin:
            headers = admin_headers(admin)
        elif svc in svc_tokens:
            headers = {"x-config-center-service-token": svc_tokens[svc]}
        else:
            die(f"{svc}: 既没有管理 token, {ns}/{selector} 里也没有它的 service_token, 读不了现值")
        try:
            entry = cc.get_key(svc, args.env, KEY, headers)
        except RuntimeError as e:
            die(f"{svc}: {e}")
        cur_text = entry.get("value") or ""
        if not cur_text:
            die(f"{svc}: {args.env}/{KEY} 为空(新环境请先用 config-center-pre-seed.sh 从 dev 复制)")
        doc = yaml.safe_load(cur_text)
        if not isinstance(doc, dict):
            die(f"{svc}: {KEY} 不是映射结构")
        orig = yaml.safe_load(cur_text)

        # 2) 按 schema 决定要填哪些能力
        schema = load_schema(schemas_dir, svc)
        if schema is None:
            # 没有 schema 就不知道这个服务需要哪些块(search 才有 elasticsearch, cart 才有 minio), 不能猜
            die(f"{svc}: 找不到 schema {schemas_dir}/{svc}/bootstrap.schema.json —— 把 control-tower 的 "
                f"services/config/internal/schema/schemas 同步过来并设 CC_SCHEMAS_DIR(节点上通常是 $STATE_DIR/config-center/schemas)")
        caps = [c for c in needed_caps(schema, mapping) if c in providers]
        missing = [c for c in needed_caps(schema, mapping) if c not in providers]
        if missing:
            log(f"⚠ {svc}: schema 需要 {' '.join(missing)} 但没有启用的提供方, 这些块保持原值")

        # 3) 只改映射路径
        changes, unresolved = apply_caps(doc, orig, caps, mapping, providers, args.env, args.dry_run, svc)
        for r in unresolved:
            pending_all.setdefault(r.split(" ← ", 1)[1], []).append(f"{svc}:{r.split(' ← ', 1)[0]}")

        if not changes:
            log(f"· {svc}: v{entry.get('version')} 无差异" + (f"(另有 {len(unresolved)} 处待补齐)" if unresolved else ""))
            continue

        # 4) 往返等价自检: 除改动路径外必须与原值完全等价
        new_text = dump_yaml(doc)
        if yaml.safe_load(new_text) != orig:
            die(f"{svc}: 重新序列化后的配置与「原值+补丁」不等价, 拒绝写入")

        # 5) schema 校验
        if schema is not None:
            if jsonschema is None:
                if args.require_schema:
                    die("缺少 python 模块 jsonschema(--require-schema)")
                if not schema_warned:
                    log("⚠ 没有 jsonschema 模块, 跳过 schema 校验(pip install jsonschema 或 --require-schema)")
                    schema_warned = True
            else:
                try:
                    jsonschema.validate(yaml.safe_load(new_text), schema)
                except jsonschema.ValidationError as e:  # type: ignore[attr-defined]
                    die(f"{svc}: 合成结果不符合 schema: {'/'.join(str(x) for x in e.absolute_path)}: {e.message}")

        # 6) 脱敏 diff
        log(f"{svc}: v{entry.get('version')} → 改动 {len(changes)} 处" + (f", 待补齐 {len(unresolved)} 处" if unresolved else ""))
        for path, old, new in changes:
            print(f"    {path}: {mask(path, old)} → {mask(path, new)}")
        if args.dry_run:
            continue

        # 7) 写入 + 读回校验
        try:
            put = cc.put_key(svc, args.env, KEY, new_text, admin,
                             comment=f"harvest {args.env}: " + ", ".join(caps))
        except RuntimeError as e:
            die(f"{svc}: {e}(管理 token 无效/过期?)")
        log(f"{svc}: {args.env}/{KEY} 已写入 v{put.get('version')}")
        if args.rotate_tokens or svc not in svc_tokens:
            note = f"{os.uname().nodename} harvest {time.strftime('%F')}"
            new_tokens[svc] = cc.issue_token(svc, args.env, note, admin)
        tok = new_tokens.get(svc) or svc_tokens[svc]
        back = cc.get_key(svc, args.env, KEY, {"x-config-center-service-token": tok})
        if back.get("value") != new_text:
            die(f"{svc}: 数据面读回与写入不一致(is_secret 脱敏? 版本冲突?)")
        changed_services.append(svc)

    if args.dry_run:
        if pending_all:
            log(f"待补齐清单({len(pending_all)} 项; 不补齐则正式运行时对应服务会报错):")
            for reason, where in pending_all.items():
                print(f"    - {reason}  [{len(where)} 处]")
        log("dry-run 结束: 未写 Config Center、未建 Secret、未改 Deployment")
        return 0
    if not changed_services:
        log("全部无差异, 结束")
        return 0

    # 8) selector Secret: 只更新本次涉及的 key, 其余保留(2026-09-11 部分重播种踩过)
    if new_tokens:
        try:
            existing = json.loads(kubectl("-n", ns, "get", "secret", selector, "-o", "json"))
        except RuntimeError:
            existing = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                        "metadata": {"name": selector, "namespace": ns}, "data": {}}
        data = existing.setdefault("data", {})
        for svc, tok in new_tokens.items():
            cur = base64.b64decode(data[f"{svc}.yaml"]).decode() if f"{svc}.yaml" in data else \
                f"type: config_center\nconfig_center:\n  address: {cc_url if cc_url.endswith('.svc:30010') else 'http://config-center.config-center.svc:30010'}\n  namespace: {svc}\n  environment: {args.env}\n  key: {KEY}\n  service_token: \n"
            sel = yaml.safe_load(cur)
            sel["config_center"]["environment"] = args.env
            sel["config_center"]["service_token"] = tok
            data[f"{svc}.yaml"] = base64.b64encode(dump_yaml(sel).encode()).decode()
        minimal = {"apiVersion": "v1", "kind": "Secret", "type": existing.get("type", "Opaque"),
                   "metadata": {"name": selector, "namespace": ns}, "data": data}
        kubectl("apply", "-f", "-", input_=json.dumps(minimal))
        log(f"Secret {ns}/{selector} 已更新 {len(new_tokens)} 个服务的 token")

    # 9) 滚动: 配置在启动时读, 键变了必须重启(Deployment 引用未变, patch 不会触发)
    if not args.no_restart:
        for svc in changed_services:
            dep = f"ecommerce-{svc}-deploy"
            try:
                replicas = kubectl("-n", ns, "get", "deploy", dep, "-o", "jsonpath={.spec.replicas}").strip()
            except RuntimeError:
                log(f"⚠ {dep} 不存在, 跳过滚动")
                continue
            kubectl("-n", ns, "rollout", "restart", f"deploy/{dep}")
            if replicas == "0":
                log(f"· {dep} 副本为 0, 不等待")
                continue
            r = subprocess.run(["kubectl", "-n", ns, "rollout", "status", f"deploy/{dep}", "--timeout=180s"],
                               capture_output=True, text=True)
            log(("✔ " if r.returncode == 0 else "✘ 未就绪: ") + dep)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
