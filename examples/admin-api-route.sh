#!/usr/bin/env bash
# Create the Blablador route of examples/blablador/apisix.yaml through the
# APISIX Admin API (etcd mode), with the token filled in.
#
#   ADMIN_KEY=...  BLABLADOR_API_KEY=...  ./examples/admin-api-route.sh
#
# Requires the system_one overlay (see README: Run on APISIX 3.19) and uv.
set -euo pipefail
cd "$(dirname "$0")"
: "${ADMIN_KEY:?set ADMIN_KEY}" "${BLABLADOR_API_KEY:?set BLABLADOR_API_KEY}"
export ADMIN_URL=${ADMIN_URL:-http://127.0.0.1:9180}

uv run --quiet --with pyyaml python - <<'PY'
import json, os, urllib.request
import yaml

text = open("blablador/apisix.yaml").read()
text = text.replace("${{BLABLADOR_API_KEY}}", os.environ["BLABLADOR_API_KEY"])
route = yaml.safe_load(text)["routes"][0]
route_id = route.pop("id")
req = urllib.request.Request(
    f"{os.environ['ADMIN_URL']}/apisix/admin/routes/{route_id}", method="PUT",
    data=json.dumps(route).encode(),
    headers={"X-API-KEY": os.environ["ADMIN_KEY"], "Content-Type": "application/json"})
try:
    print("created", json.load(urllib.request.urlopen(req))["key"])
except urllib.error.HTTPError as e:
    raise SystemExit(f"HTTP {e.code}: {e.read().decode()}")
PY
