# Kubernetes deployment

Installs APISIX 3.19 (official Helm chart `apisix/apisix` 2.18.2) with etcd and
the `ai-decision-router` plugin. Tested on Docker Desktop's Kubernetes (v1.34).

```sh
KUBE_CONTEXT=docker-desktop deploy/kubernetes/deploy.sh
```

What `deploy.sh` does:

1. creates the `apisix` namespace (override with `NAMESPACE=...`);
2. creates the Secret `apisix-admin` with random Admin API keys (once; kept on re-runs);
3. puts `apisix/plugins/ai-decision-router.lua` into the ConfigMap `ai-decision-router`;
4. `helm upgrade --install` with [`values.yaml`](values.yaml), which mounts the
   ConfigMap at `/opts/custom_plugins/apisix/plugins/` and adds the plugin to the list;
5. restarts the APISIX deployment so a changed plugin file is loaded.

The chart only enables custom plugins when `apisix.plugins` is set, and that list
replaces APISIX's default list, so `values.yaml` repeats the APISIX 3.19 defaults.
When upgrading APISIX, regenerate it from `apisix/cli/config.lua` of the new image.

## Create a route and try it

```sh
kubectl --context docker-desktop -n apisix port-forward svc/apisix-admin 9180:9180 &
kubectl --context docker-desktop -n apisix port-forward svc/apisix-gateway 9080:80 &

export ADMIN_KEY=$(kubectl --context docker-desktop -n apisix get secret apisix-admin \
  -o jsonpath='{.data.admin}' | base64 -d)
export BLABLADOR_API_KEY=...
examples/admin-api-route.sh                     # 5-candidate route on /v1/chat/completions

python3 test/live_routing.py http://127.0.0.1:9080/v1/chat/completions
```

The route stores the Blablador token in etcd; APISIX encrypts
`decision.auth.header` (like `ai-proxy`'s `auth.header`) with its data
encryption keyring, which is on by default.

## Results (2026-10-16, Docker Desktop, live Blablador API)

With the 14-candidate policy of `examples/blablador/apisix.yaml` loaded through
the Admin API:

| Case | Routed to | Confidence | Total time (s) |
| --- | --- | --- | --- |
| Python traceback | `alias-code` | 0.82 | 1.2 |
| Implement an LRU cache in Rust | `alias-glm-5.3-flash` | 0.74 | 1.7 |
| One-line bash, "in 2 seconds" | `alias-qwen38-quick` | 0.95 | 0.7 |
| Prove √2 is irrational | `alias-mimo-v2.6-pro` | 0.94 | 2.0 |
| Train catch-up calculation | `alias-mimo-v2.6-flash` | 0.52 | 0.7 |
| Sentinel-2 deforestation pipeline | `alias-eve` | 0.95 | 0.7 |
| German press release | `alias-apertus` | 0.91 | 1.0 |
| Rainy-Monday motivation | `alias-muse` | 0.89 | 0.6 |
| 400 PDFs of meeting minutes | `alias-kimi-k3-1m` | 0.93 | 2.4 |
| Multi-agent deployment system | `alias-huge` | 0.92 | 0.5 |
| Capital of Australia | `alias-fast` | 0.94 | 0.3 |
| explicit `alias-fast` | not routed | | 0.2 |

Times include the decision call and a 16-token answer. Failure checks on the same
cluster: a 1 ms decision timeout and a wrong decision endpoint both fell back to
`alias-large` with `X-AI-Routing-Fallback` set, and the Admin API rejected a
route with duplicate candidate names (HTTP 400).

## Remove

```sh
helm uninstall apisix --kube-context docker-desktop -n apisix
kubectl --context docker-desktop delete namespace apisix
```
