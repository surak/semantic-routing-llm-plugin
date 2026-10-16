#!/usr/bin/env bash
# Run t/plugin/ai-decision-router.t with APISIX's Test::Nginx harness in Docker.
#   t/run.sh [prove args]       e.g. t/run.sh -v
set -euo pipefail
cd "$(dirname "$0")/.."
APISIX_VERSION=${APISIX_VERSION:-3.19.0}
IMAGE=adr-test-nginx:$APISIX_VERSION

docker build -q -t "$IMAGE" --build-arg APISIX_VERSION="$APISIX_VERSION" t/docker >/dev/null
docker rm -f adr-test-etcd >/dev/null 2>&1 || true
docker run -d --name adr-test-etcd -e ALLOW_NONE_AUTHENTICATION=yes \
  quay.io/coreos/etcd:v3.5.17 etcd \
  --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls http://127.0.0.1:2379 >/dev/null
trap 'docker rm -f adr-test-etcd >/dev/null 2>&1' EXIT

docker run --rm --network container:adr-test-etcd \
  -v "$PWD/apisix/plugins/ai-decision-router.lua:/apisix/apisix/plugins/ai-decision-router.lua:ro" \
  -v "$PWD/t/plugin/ai-decision-router.t:/apisix/t/plugin/ai-decision-router.t:ro" \
  "$IMAGE" sh -c '
    # register the plugin the way the upstream PR does
    sed -i "s/^    \"ai-proxy\",$/    \"ai-proxy\",\n    \"ai-decision-router\",/" apisix/cli/config.lua
    grep -q "\"ai-decision-router\"" apisix/cli/config.lua
    prove -I. '"${*:-}"' t/plugin/ai-decision-router.t'
