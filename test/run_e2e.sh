#!/usr/bin/env bash
# End-to-end tests: start APISIX + mocks, fire requests, check routing.
# Usage: test/run_e2e.sh [--keep]   (--keep leaves the stack running)
set -euo pipefail
cd "$(dirname "$0")"
export APISIX_PORT=${APISIX_PORT:-9080}
BASE="http://127.0.0.1:${APISIX_PORT}"
COMPOSE="docker compose -p system-one-test -f docker-compose.yml"

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
    -H 'Cookie: session=secret' \
    -d "{\"model\":\"$2\",\"messages\":[{\"role\":\"system\",\"content\":\"be brief\"},{\"role\":\"user\",\"content\":\"$3\"}]}"
}
expect() {  # expect <name> <haystack> <needle>
  if grep -qF -- "$3" <<<"$2"; then
    pass=$((pass + 1)); echo "ok   - $1"
  else
    fail=$((fail + 1)); echo "FAIL - $1 (wanted '$3')"; echo "$2" | sed 's/^/       /'
  fi
}

r=$(chat /route auto "Why does my python function segfault?")
expect "code prompt -> code instance"             "$r" "model=mock-coder path=/code/"
expect "debugging: picked instance header"        "$r" "X-AI-System-One-Picked-Instance: code"
expect "debugging: probabilities header"          "$r" "X-AI-System-One-Probabilities: code:0.9000"

r=$(chat /route auto "Prove that the integral converges")
expect "math prompt -> math instance"             "$r" "model=mock-math path=/math/"

r=$(chat /route auto "Write a haiku about autumn")
expect "other prompt -> general instance"         "$r" "model=mock-general path=/general/"

r=$(chat /route auto "FAIL please")
expect "System One error -> fallback served"      "$r" "model=mock-general"
expect "System One error -> no ranking header"    "$(grep -c Probabilities <<<"$r" || true)" "0"

r=$(chat /route auto "LOWCONF integral")
expect "below threshold -> fallback"              "$r" "model=mock-general"
expect "below threshold -> ranking still shown"   "$r" "X-AI-System-One-Probabilities:"

r=$(chat /retry auto "fix this bug in my code")
expect "failing top pick -> next in ranking"      "$r" "path=/math/"
r=$(chat /retry-threshold auto "fix this bug in my code")
expect "failing top pick, rest below threshold -> fallback" "$r" "path=/general/"

# OpenAI Responses-style body
r=$(curl -s "$BASE/route" -H 'Content-Type: application/json' \
      -d '{"model":"auto","input":"prove this theorem"}')
expect "Responses input string is understood"     "$r" "model=mock-math"

# the System One request itself
d=$($COMPOSE exec -T mock tail -n 1 /tmp/decisions.jsonl)
expect "System One call carries auth header"      "$d" '"auth": "Bearer s1-token"'
expect "System One call uses the model"           "$d" '"model": "jev"'
expect "System One call is a choice question"     "$d" '"type": "choice"'
expect "instance descriptions are the criteria"   "$d" '"code": "Programming, debugging and code review."'
expect "client cookie is not forwarded"           "$d" '"cookie": null'

echo "---"; echo "passed: $pass  failed: $fail"
if (( fail )); then
  $COMPOSE logs apisix | grep -E "\[(error|warn)\]" | cut -c1-300 | tail -n 20
  exit 1
fi
