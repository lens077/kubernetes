#!/usr/bin/env bash
# OpenFGA 冒烟: 建 store → 写模型 → 写 tuple → check 应 allowed=true
set -euo pipefail
kubectl -n openfga port-forward svc/openfga 18080:8080 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT; sleep 2
STORE=$(curl -s -X POST localhost:18080/stores -H 'content-type: application/json' -d '{"name":"smoke"}' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "store=$STORE"
MODEL=$(curl -s -X POST "localhost:18080/stores/$STORE/authorization-models" -H 'content-type: application/json' -d '{
  "schema_version":"1.1",
  "type_definitions":[
    {"type":"user"},
    {"type":"shop","relations":{"operator":{"this":{}}},"metadata":{"relations":{"operator":{"directly_related_user_types":[{"type":"user"}]}}}}
  ]}' | sed -n 's/.*"authorization_model_id":"\([^"]*\)".*/\1/p')
echo "model=$MODEL"
curl -s -X POST "localhost:18080/stores/$STORE/write" -H 'content-type: application/json' -d '{
  "writes":{"tuple_keys":[{"user":"user:anne","relation":"operator","object":"shop:1"}]}}' >/dev/null
curl -s -X POST "localhost:18080/stores/$STORE/check" -H 'content-type: application/json' -d '{
  "tuple_key":{"user":"user:anne","relation":"operator","object":"shop:1"}}'
echo
