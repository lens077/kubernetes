#!/usr/bin/env bash
# Isolated vmalert-tool tests, not connected to production VM or Alertmanager.
# TEST_HOST=node4 ./components/vmalert/test-host-rules.sh [host-recording.yml|host-alerts.yml]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
FILE=${1:-host-recording.yml}
case "$FILE" in host-recording.yml|host-alerts.yml) ;; *) echo "Unknown test fixture" >&2; exit 2;; esac
IMAGE=victoriametrics/vmalert-tool@sha256:a14b2d609b9b1636ec42fc6a3d38f65c235a1120a9db1d3d3e304cbbb7eb65f5
if [ -z "${TEST_HOST:-}" ]; then
  docker run --rm --network none -v "$ROOT:/work:ro" -w /work/tests "$IMAGE" unittest "-files=$FILE"
else
  remote=$(ssh -o BatchMode=yes "$TEST_HOST" 'mktemp -d /tmp/host-metrics-tests.XXXXXX')
  case "$remote" in /tmp/host-metrics-tests.*) ;; *) echo "Unsafe remote path" >&2; exit 2;; esac
  trap 'ssh -o BatchMode=yes "$TEST_HOST" "rm -r '\''$remote'\''"' EXIT
  ssh -o BatchMode=yes "$TEST_HOST" "mkdir -p '$remote/rules' '$remote/tests'"
  scp -q "$ROOT/rules/host-recording.yml" "$ROOT/rules/cloud-hosts.yml" "$TEST_HOST:$remote/rules/"
  scp -q "$ROOT/tests/$FILE" "$TEST_HOST:$remote/tests/"
  ssh -o BatchMode=yes "$TEST_HOST" "docker run --rm --network none -v '$remote:/work:ro' -w /work/tests '$IMAGE' unittest '-files=$FILE'"
fi
