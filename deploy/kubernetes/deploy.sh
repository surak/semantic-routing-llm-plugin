#!/usr/bin/env bash
# Install APISIX + etcd with the system_one balancer of ai-proxy-multi.
#
#   KUBE_CONTEXT=docker-desktop deploy/kubernetes/deploy.sh
#
# Re-run after changing overlay/: the ConfigMap is updated and the pods restarted.
set -euo pipefail
cd "$(dirname "$0")"
CTX=${KUBE_CONTEXT:-docker-desktop}
NS=${NAMESPACE:-apisix}
K="kubectl --context $CTX -n $NS"

kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -

# Admin API keys: generated once, kept in a Secret.
if ! $K get secret apisix-admin >/dev/null 2>&1; then
  $K create secret generic apisix-admin \
    --from-literal=admin="$(openssl rand -hex 16)" \
    --from-literal=viewer="$(openssl rand -hex 16)"
fi

$K create configmap apisix-system-one \
  --from-file=ai-proxy-multi.lua=../../overlay/apisix/plugins/ai-proxy-multi.lua \
  --from-file=schema.lua=../../overlay/apisix/plugins/ai-proxy/schema.lua \
  --from-file=system-one.lua=../../overlay/apisix/plugins/ai-proxy/system-one.lua \
  --dry-run=client -o yaml | $K apply -f -

helm repo add apisix https://charts.apiseven.com >/dev/null 2>&1 || true
helm repo update apisix >/dev/null
helm upgrade --install apisix apisix/apisix --version "${CHART_VERSION:-2.18.2}" \
  --kube-context "$CTX" -n "$NS" -f values.yaml --wait --timeout 10m

# pick up a changed overlay ConfigMap
$K rollout restart deployment/apisix
$K rollout status deployment/apisix --timeout 5m
