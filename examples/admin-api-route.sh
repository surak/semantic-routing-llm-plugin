#!/usr/bin/env bash
# Create the auto-routing route through the APISIX Admin API (etcd mode).
#
#   ADMIN_KEY=...  BLABLADOR_API_KEY=...  ./examples/admin-api-route.sh
#
# Requires ai-decision-router to be loaded (see README: Installation).
set -euo pipefail
ADMIN=${ADMIN_URL:-http://127.0.0.1:9180}
: "${ADMIN_KEY:?set ADMIN_KEY}" "${BLABLADOR_API_KEY:?set BLABLADOR_API_KEY}"

curl -sS -X PUT "$ADMIN/apisix/admin/routes/blablador-auto" \
  -H "X-API-KEY: $ADMIN_KEY" -H 'Content-Type: application/json' -d @- <<JSON
{
  "uri": "/v1/chat/completions",
  "methods": ["POST"],
  "plugins": {
    "ai-decision-router": {
      "decision": {
        "endpoint": "https://api.blablador.fz-juelich.de/v1/systemone",
        "model": "alias-clef",
        "timeout": 10000,
        "auth": { "header": { "Authorization": "Bearer $BLABLADOR_API_KEY" } }
      },
      "trigger_models": ["auto"],
      "fallback": "alias-large",
      "min_confidence": 0.3,
      "candidates": [
        { "name": "alias-fast",  "description": "Routine factual questions, short summaries and simple scripts." },
        { "name": "alias-large", "description": "Broad multilingual synthesis with no dominant specialist." },
        { "name": "alias-code",  "description": "Debugging existing code and reviewing patches." },
        { "name": "alias-mimo-v2.6-pro", "description": "Rigorous mathematical proofs and deep multi-step reasoning." },
        { "name": "alias-eve",   "description": "Earth observation, remote sensing and geoscience." }
      ]
    },
    "ai-proxy": {
      "provider": "openai-compatible",
      "auth": { "header": { "Authorization": "Bearer $BLABLADOR_API_KEY" } },
      "override": { "endpoint": "https://api.blablador.fz-juelich.de/v1/chat/completions" }
    }
  }
}
JSON
echo
