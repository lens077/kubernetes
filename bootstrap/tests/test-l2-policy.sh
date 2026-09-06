#!/usr/bin/env bash
# lib/common.sh 里 LB-IPAM 池 / L2Policy / 共享 Gateway 纯校验函数的离线回归(只喂 JSON, 不碰集群)。
# 60-cilium 的 l2 步骤、90-verify 与 components/gateway/install.sh 共用这些判据。
set -euo pipefail

BOOTSTRAP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
# shellcheck source=../lib/common.sh
source "$BOOTSTRAP_DIR/lib/common.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect_ok <描述> <命令...>: 校验函数不能有任何输出
expect_ok() {
  local desc=$1; shift
  local out
  out=$("$@")
  [[ -z $out ]] || fail "$desc: 期望无问题, 实际:"$'\n'"$out"
}
# expect_problem <描述> <问题片段> <命令...>: 输出里必须含该片段
expect_problem() {
  local desc=$1 needle=$2; shift 2
  local out
  out=$("$@")
  grep -q -- "$needle" <<<"$out" || fail "$desc: 期望问题含 [$needle], 实际:"$'\n'"${out:-<无输出>}"
}

VIP=10.10.31.240
# pool <name> <gen> <观测gen> <conflict状态> <blocks json> [selector json] [disabled]
pool() {
  local name=$1 gen=$2 ogen=$3 conflict=$4 blocks=$5 selector=${6:-null} disabled=${7:-false}
  jq -nc --arg name "$name" --argjson gen "$gen" --argjson ogen "$ogen" --arg conflict "$conflict" \
    --argjson blocks "$blocks" --argjson selector "$selector" --argjson disabled "$disabled" '
    {metadata:{name:$name,generation:$gen},
     spec:({blocks:$blocks,disabled:$disabled} + (if $selector == null then {} else {serviceSelector:$selector} end)),
     status:{conditions:(if $conflict == "" then [] else
       [{type:"cilium.io/PoolConflict",status:$conflict,observedGeneration:$ogen,reason:"r",message:"m"}] end)}}'
}
GW_SEL='{"matchLabels":{"io.kubernetes.service.namespace":"default","io.kubernetes.service.name":"cilium-gateway-cilium-gateway"}}'
GW_BLOCKS='[{"start":"10.10.31.240","stop":"10.10.31.240"}]'
DEF_BLOCKS='[{"start":"10.10.31.241","stop":"10.10.31.249"}]'

# --- gateway-pool ------------------------------------------------------------
expect_ok "健康 gateway-pool" \
  lb_pool_problems "$(pool gateway-pool 3 3 False "$GW_BLOCKS" "$GW_SEL")" $VIP $VIP default cilium-gateway-cilium-gateway
expect_problem "地址不是 VIP" "与期望" \
  lb_pool_problems "$(pool gateway-pool 3 3 False '[{"start":"10.10.31.241","stop":"10.10.31.241"}]' "$GW_SEL")" $VIP $VIP default cilium-gateway-cilium-gateway
expect_problem "多出一段 block" "blocks 应恰好 1 段" \
  lb_pool_problems "$(pool gateway-pool 3 3 False '[{"start":"10.10.31.240","stop":"10.10.31.240"},{"start":"10.10.31.250","stop":"10.10.31.250"}]' "$GW_SEL")" $VIP $VIP default cilium-gateway-cilium-gateway
expect_problem "cidr 写法不是期望的起止" "与期望" \
  lb_pool_problems "$(pool gateway-pool 3 3 False '[{"cidr":"10.10.31.240/32"}]' "$GW_SEL")" $VIP $VIP default cilium-gateway-cilium-gateway
expect_problem "selector 缺 namespace" "未同时限定 namespace" \
  lb_pool_problems "$(pool gateway-pool 3 3 False "$GW_BLOCKS" '{"matchLabels":{"io.kubernetes.service.name":"cilium-gateway-cilium-gateway"}}')" $VIP $VIP default cilium-gateway-cilium-gateway
expect_problem "selector namespace 漂移" "未同时限定 namespace" \
  lb_pool_problems "$(pool gateway-pool 3 3 False "$GW_BLOCKS" '{"matchLabels":{"io.kubernetes.service.namespace":"pangolin","io.kubernetes.service.name":"cilium-gateway-cilium-gateway"}}')" $VIP $VIP default cilium-gateway-cilium-gateway
expect_problem "disabled=true" "spec.disabled=true" \
  lb_pool_problems "$(pool gateway-pool 3 3 False "$GW_BLOCKS" "$GW_SEL" true)" $VIP $VIP default cilium-gateway-cilium-gateway
expect_problem "PoolConflict=True" "PoolConflict=True" \
  lb_pool_problems "$(pool gateway-pool 3 3 True "$GW_BLOCKS" "$GW_SEL")" $VIP $VIP default cilium-gateway-cilium-gateway
expect_problem "条件属于旧 generation" "落后于 generation" \
  lb_pool_problems "$(pool gateway-pool 4 3 False "$GW_BLOCKS" "$GW_SEL")" $VIP $VIP default cilium-gateway-cilium-gateway
expect_problem "尚无 PoolConflict 条件" "缺少 cilium.io/PoolConflict" \
  lb_pool_problems "$(pool gateway-pool 1 0 "" "$GW_BLOCKS" "$GW_SEL")" $VIP $VIP default cilium-gateway-cilium-gateway

# --- default-pool: 必须用 NotIn 排除共享 Gateway 的 Service ----------------------
DEF_SEL='{"matchExpressions":[{"key":"io.kubernetes.service.name","operator":"NotIn","values":["cilium-gateway-cilium-gateway"]}]}'
expect_ok "健康 default-pool" \
  lb_pool_problems "$(pool default-pool 2 2 False "$DEF_BLOCKS" "$DEF_SEL")" 10.10.31.241 10.10.31.249 exclude=cilium-gateway-cilium-gateway
expect_ok "不要求排除时无 selector 也通过" \
  lb_pool_problems "$(pool default-pool 2 2 False "$DEF_BLOCKS")" 10.10.31.241 10.10.31.249
expect_problem "default-pool 范围被改" "与期望" \
  lb_pool_problems "$(pool default-pool 2 2 False '[{"start":"10.10.31.241","stop":"10.10.31.250"}]' "$DEF_SEL")" 10.10.31.241 10.10.31.249 exclude=cilium-gateway-cilium-gateway
expect_problem "default-pool 没有 selector(会匹配共享 Gateway)" "未用 NotIn 排除" \
  lb_pool_problems "$(pool default-pool 2 2 False "$DEF_BLOCKS")" 10.10.31.241 10.10.31.249 exclude=cilium-gateway-cilium-gateway
expect_problem "default-pool 用 In 而不是 NotIn" "未用 NotIn 排除" \
  lb_pool_problems "$(pool default-pool 2 2 False "$DEF_BLOCKS" '{"matchExpressions":[{"key":"io.kubernetes.service.name","operator":"In","values":["cilium-gateway-cilium-gateway"]}]}')" 10.10.31.241 10.10.31.249 exclude=cilium-gateway-cilium-gateway
expect_problem "default-pool 排除了别的名字" "未用 NotIn 排除" \
  lb_pool_problems "$(pool default-pool 2 2 False "$DEF_BLOCKS" '{"matchExpressions":[{"key":"io.kubernetes.service.name","operator":"NotIn","values":["other"]}]}')" 10.10.31.241 10.10.31.249 exclude=cilium-gateway-cilium-gateway

# --- L2Policy --------------------------------------------------------------------
L2_OK='{"metadata":{"name":"default-l2"},"spec":{"loadBalancerIPs":true,"interfaces":["^en.*","^eth.*"]}}'
expect_ok "健康 default-l2" l2_policy_problems "$L2_OK"
expect_problem "loadBalancerIPs 关闭" "loadBalancerIPs 不是 true" \
  l2_policy_problems '{"metadata":{"name":"default-l2"},"spec":{"loadBalancerIPs":false,"interfaces":["^en.*"]}}'
expect_problem "interfaces 为空" "interfaces 为空" \
  l2_policy_problems '{"metadata":{"name":"default-l2"},"spec":{"loadBalancerIPs":true}}'

# --- 共享 Gateway + 生成的 Service --------------------------------------------------
# gw <gen> <观测gen> <Programmed状态> <地址或空>
gw() {
  jq -nc --argjson gen "$1" --argjson ogen "$2" --arg st "$3" --arg addr "$4" '
    {metadata:{name:"cilium-gateway",namespace:"default",generation:$gen},
     status:{conditions:[{type:"Accepted",status:"True",observedGeneration:$gen},
                         {type:"Programmed",status:$st,observedGeneration:$ogen,reason:"r",message:"m"}],
             addresses:(if $addr == "" then [] else [{type:"IPAddress",value:$addr}] end)}}'
}
# svc <type> <请求注解> <实际ip或空> <IPAMRequestSatisfied 状态或空>
svc() {
  jq -nc --arg type "$1" --arg req "$2" --arg ip "$3" --arg sat "$4" '
    {metadata:{name:"cilium-gateway-cilium-gateway",namespace:"default",
               annotations:(if $req == "" then {} else {"io.cilium/lb-ipam-ips":$req} end)},
     spec:{type:$type},
     status:{loadBalancer:{ingress:(if $ip == "" then [] else [{ip:$ip}] end)},
             conditions:(if $sat == "" then [] else [{type:"cilium.io/IPAMRequestSatisfied",status:$sat,reason:"r",message:"m"}] end)}}'
}
expect_ok "健康 Gateway+Service" \
  shared_gateway_problems "$(gw 2 2 True $VIP)" "$(svc LoadBalancer "$VIP" "$VIP" True)" $VIP
expect_ok "请求注解含多个地址时也接受" \
  shared_gateway_problems "$(gw 2 2 True $VIP)" "$(svc LoadBalancer "$VIP, 10.10.31.250" "$VIP" True)" $VIP
expect_problem "Programmed=False" "Programmed=False" \
  shared_gateway_problems "$(gw 2 2 False "")" "$(svc LoadBalancer "$VIP" "" False)" $VIP
expect_problem "Programmed 属于旧 generation" "落后于 generation" \
  shared_gateway_problems "$(gw 3 2 True $VIP)" "$(svc LoadBalancer "$VIP" "$VIP" True)" $VIP
expect_problem "Gateway 地址漂移" "不等于固定 VIP" \
  shared_gateway_problems "$(gw 2 2 True 10.10.31.241)" "$(svc LoadBalancer "$VIP" 10.10.31.241 True)" $VIP
expect_problem "生成的 Service 不存在" "未找到 Cilium 为共享 Gateway 生成的 Service" \
  shared_gateway_problems "$(gw 2 2 True $VIP)" "" $VIP
expect_problem "hostNetwork 模式生成 NodePort" "不是 LoadBalancer" \
  shared_gateway_problems "$(gw 2 2 True $VIP)" "$(svc NodePort "" "" "")" $VIP
expect_problem "Service 没有固定 IP 请求注解" "请求注解 io.cilium/lb-ipam-ips" \
  shared_gateway_problems "$(gw 2 2 True $VIP)" "$(svc LoadBalancer "" "$VIP" True)" $VIP
expect_problem "Service 实际分配到别的地址" "实际 LB 地址" \
  shared_gateway_problems "$(gw 2 2 True $VIP)" "$(svc LoadBalancer "$VIP" 10.10.31.241 True)" $VIP
expect_problem "IPAMRequestSatisfied=False" "IPAMRequestSatisfied=False" \
  shared_gateway_problems "$(gw 2 2 True $VIP)" "$(svc LoadBalancer "$VIP" "$VIP" False)" $VIP
expect_problem "缺 IPAMRequestSatisfied 条件" "缺少 cilium.io/IPAMRequestSatisfied" \
  shared_gateway_problems "$(gw 2 2 True $VIP)" "$(svc LoadBalancer "$VIP" "$VIP" "")" $VIP

printf 'L2/LB-IPAM/Gateway checker tests: OK\n'
