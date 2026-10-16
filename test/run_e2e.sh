#!/usr/bin/env bash
# End-to-end tests: start APISIX + mocks, fire requests, check routing.
# Usage: test/run_e2e.sh [--keep]   (--keep leaves the stack running)
set -euo pipefail
cd "$(dirname "$0")"
export APISIX_PORT=${APISIX_PORT:-9080}
BASE="http://127.0.0.1:${APISIX_PORT}"
COMPOSE="docker compose -p ai-decision-router-test -f docker-compose.yml"

cleanup() { [[ "${1:-}" == "--keep" ]] || $COMPOSE down -v >/dev/null 2>&1; }
trap 'cleanup "${KEEP:-}"' EXIT
[[ "${1:-}" == "--keep" ]] && KEEP=--keep

$COMPOSE up -d --quiet-pull --force-recreate >/dev/null 2>&1
for _ in $(seq 60); do
  curl -s -o /dev/null "$BASE/" && break
  sleep 1
done

pass=0; fail=0
chat() {  # chat <route> <model> <prompt>  -> prints "headers\n\nbody"
  curl -s -i "$BASE$1" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$2\",\"messages\":[{\"role\":\"system\",\"content\":\"be brief\"},{\"role\":\"user\",\"content\":\"$3\"}]}"
}
expect() {  # expect <name> <haystack> <needle>
  if grep -qF -- "$3" <<<"$2"; then
    pass=$((pass + 1)); echo "ok   - $1"
  else
    fail=$((fail + 1)); echo "FAIL - $1 (wanted '$3')"; echo "$2" | sed 's/^/       /'
  fi
}

r=$(chat /single auto "Why does my python function segfault?")
expect "ai-proxy: code prompt -> mock-coder"      "$r" "model=mock-coder path=/llm/"
expect "ai-proxy: routed-model header"            "$r" "X-AI-Routed-Model: mock-coder"
expect "ai-proxy: confidence header"              "$r" "X-AI-Routing-Confidence: 0.9"

r=$(chat /single auto "Prove that the integral converges")
expect "ai-proxy: math prompt -> mock-math"       "$r" "model=mock-math"

r=$(chat /single auto "Write a haiku about autumn")
expect "ai-proxy: other prompt -> mock-general"   "$r" "model=mock-general"

r=$(chat /single auto "FAIL please")
expect "decision error -> fallback served"        "$r" "model=mock-general"
expect "decision error -> fallback header"        "$r" "X-AI-Routing-Fallback: decision error"

for i in 1 2 3; do
  r=$(chat /multi auto "fix this bug in my code")
  expect "ai-proxy-multi: code instance ($i/3)"   "$r" "model=inst-code path=/inst-code/"
done
r=$(chat /multi auto "solve this equation")
expect "ai-proxy-multi: math instance"            "$r" "path=/inst-math/"

r=$(chat /plain auto "compile error in my code")
expect "plain upstream: body rewritten"           "$r" "model=mock-coder path=/plain/"

r=$(chat /trigger gpt-explicit "fix my python bug")
expect "trigger_models: explicit model kept"      "$r" "model=gpt-explicit"
r=$(chat /trigger auto "fix my python bug")
expect "trigger_models: auto is routed"           "$r" "model=mock-coder"

r=$(chat /lowconf auto "LOWCONF integral")
expect "min_confidence: unsure -> fallback"       "$r" "model=mock-general"
expect "min_confidence: fallback reason header"   "$r" "X-AI-Routing-Fallback: low confidence 0.2"

# OpenAI Responses-style body
r=$(curl -s "$BASE/plain" -H 'Content-Type: application/json' \
      -d '{"model":"auto","input":"prove this theorem"}')
expect "responses input string is understood"     "$r" "model=mock-math"

# the decision request itself
d=$($COMPOSE exec -T mock tail -n 1 /tmp/decisions.jsonl)
expect "decision call carries auth header"        "$d" '"auth": "Bearer test-token"'
expect "decision call uses alias-clef"            "$d" '"model": "alias-clef"'
expect "decision call is a choice question"       "$d" '"type": "choice"'

echo "---"; echo "passed: $pass  failed: $fail"
if (( fail )); then
  $COMPOSE logs apisix | grep -E "error|ai-decision-router" | tail -n 30
  exit 1
fi
