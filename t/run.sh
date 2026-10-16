#!/usr/bin/env bash
# Run the system_one Test::Nginx suite in APISIX's own test harness (Docker).
#
#   t/run.sh                      system_one suite + semantic and retry suites
#   t/run.sh t/plugin/x.t ...     any APISIX test files
#
# The image holds the APISIX source tree of APISIX_VERSION; patches/ is applied
# to it (code and tests only, docs differ between master and the release).
set -euo pipefail
cd "$(dirname "$0")/.."
APISIX_VERSION=${APISIX_VERSION:-3.19.0}
IMAGE=adr-test-nginx:$APISIX_VERSION
TESTS=${*:-t/plugin/ai-proxy-multi-system-one.t t/plugin/ai-proxy-semantic-routing.t t/plugin/ai-proxy-semantic-schema.t t/plugin/ai-proxy-multi-retry.t t/plugin/ai-proxy-multi.balancer.t}

docker build -q -t "$IMAGE" --build-arg APISIX_VERSION="$APISIX_VERSION" t/docker >/dev/null
docker rm -f adr-test-etcd >/dev/null 2>&1 || true
docker run -d --name adr-test-etcd quay.io/coreos/etcd:v3.5.17 etcd \
  --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls http://127.0.0.1:2379 >/dev/null
trap 'docker rm -f adr-test-etcd >/dev/null 2>&1' EXIT

docker run --rm --network container:adr-test-etcd -v "$PWD/patches:/patches:ro" "$IMAGE" sh -c "
  git apply --include='apisix/*' --include='t/*' /patches/*.patch &&
  prove -I. $TESTS"
