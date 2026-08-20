#!/usr/bin/env bash
# NATS 冒烟: 建 R3 stream → pub/sub → 杀 pod 验选主
set -euo pipefail
kubectl -n nats exec deploy/nats-box -- nats stream add smoke --subjects smoke --storage file --replicas 3 --defaults || true
kubectl -n nats exec deploy/nats-box -- sh -c 'nats sub smoke --count=1 >/tmp/sub & sleep 1; nats pub smoke ok; sleep 2; cat /tmp/sub'
kubectl -n nats delete pod nats-0 --wait=false
sleep 20
kubectl -n nats exec deploy/nats-box -- nats stream info smoke
