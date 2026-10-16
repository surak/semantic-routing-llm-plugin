# Kubernetes deployment

Installs APISIX 3.19 (official Helm chart `apisix/apisix` 2.18.2) with etcd and the `system_one`
algorithm of `ai-proxy-multi`. Tested on Docker Desktop's Kubernetes (v1.34).

```sh
KUBE_CONTEXT=docker-desktop deploy/kubernetes/deploy.sh
```

What `deploy.sh` does:

1. creates the `apisix` namespace (override with `NAMESPACE=...`);
2. creates the Secret `apisix-admin` with random Admin API keys (once; kept on re-runs);
3. puts the three Lua modules of `overlay/` into the ConfigMap `apisix-system-one`;
4. `helm upgrade --install` with [`values.yaml`](values.yaml), which mounts the ConfigMap at
   `/opts/system-one` (chart `extraVolumes`) and puts it first on the Lua path, so the overlay's
   `ai-proxy-multi` replaces the bundled one. APISIX's default plugin list is kept;
5. restarts the APISIX deployment so a changed overlay is loaded.

etcd keeps its data on a 1 Gi PersistentVolume, so routes survive etcd restarts and Helm
upgrades. (With persistence off, an upgrade restarts etcd and wipes every route.)

## Create a route and try it

```sh
kubectl --context docker-desktop -n apisix port-forward svc/apisix-admin 9180:9180 &
kubectl --context docker-desktop -n apisix port-forward svc/apisix-gateway 9080:80 &

export ADMIN_KEY=$(kubectl --context docker-desktop -n apisix get secret apisix-admin \
  -o jsonpath='{.data.admin}' | base64 -d)
export BLABLADOR_API_KEY=...
examples/admin-api-route.sh          # the 14-model route of examples/blablador

python3 test/live_routing.py http://127.0.0.1:9080/v1/chat/completions
```

`examples/admin-api-route.sh` converts `examples/blablador/apisix.yaml` into an Admin API
request. The route stores the Blablador token in etcd; APISIX encrypts
`system_one_opts.auth.header` and `instances.auth.header` with its data encryption keyring,
which is on by default.

## Remove

```sh
helm uninstall apisix --kube-context docker-desktop -n apisix
kubectl --context docker-desktop delete namespace apisix
```
