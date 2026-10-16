# ai-decision-router

[![CI](https://github.com/surak/semantic-routing-llm-plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/surak/semantic-routing-llm-plugin/actions/workflows/ci.yml)

Documentation: **https://surak.github.io/semantic-routing-llm-plugin/**

An [Apache APISIX](https://apisix.apache.org/ai-gateway/) plugin that routes every
LLM request to the model best suited for it. For each request it asks a typed
**decision model** (a Clef-compatible `/v1/systemone` endpoint, such as
Blablador's `alias-clef`) to pick one of your candidate models, then sends the
request there.

```
client ──► APISIX ──► ai-decision-router ──► decision model  (alias-clef: "which candidate?")
                           │                    ◄── choice + confidence
                           ▼
                    ai-proxy / ai-proxy-multi / plain upstream ──► chosen model
```

It works with any of APISIX's ways of reaching an LLM:

| Route also uses | What the plugin changes |
| --- | --- |
| `ai-proxy` | rewrites the request body's `model` to the chosen candidate |
| `ai-proxy-multi` | overrides the balancer's picked instance with the chosen one (and optionally the `model`) |
| a plain `upstream` | rewrites the forwarded JSON body's `model` |

Unlike `ai-proxy-multi`'s built-in `semantic` algorithm (embedding similarity
against example prompts), the decision model reads natural-language **routing
roles** you write for each candidate, and returns a calibrated probability per
candidate. No example corpus or embedding model is needed, and the policy is a
plain-text description you can review and change.

## Quick start (Blablador)

```sh
cd examples/blablador
export BLABLADOR_API_KEY=...          # your Blablador API token
docker compose up -d

curl -i localhost:9080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "auto",
  "messages": [{"role": "user", "content": "Prove that there are infinitely many primes."}]
}'
```

```
HTTP/1.1 200 OK
X-AI-Routed-Model: alias-mimo-v2.6-pro
X-AI-Routing-Confidence: 0.9326
...
```

Clients that ask for `"model": "auto"` (or send no model) are routed; a client
asking for a concrete model such as `alias-code` is passed through untouched.
The example's 14 candidates and their routing roles come from the
`LLM router` preset of
decision-model-frontend.

Observed with the live Blablador API (2026-10-16):

| Prompt | Routed to | Confidence |
| --- | --- | --- |
| Python traceback: KeyError in a loop | `alias-code` | 0.83 |
| Prove there are infinitely many primes | `alias-mimo-v2.6-pro` | 0.93 |
| Land-use change from Sentinel-2 time series | `alias-eve` | 0.97 |
| German press release for the Forschungszentrum | `alias-apertus` | 0.86 |
| What is the capital of France? (streamed) | `alias-fast` | 0.95 |

## Installation

1. Put the plugin on APISIX's Lua path. Either copy
   `apisix/plugins/ai-decision-router.lua` into APISIX's own
   `apisix/plugins/` directory, or mount this repository and point
   `extra_lua_path` at it:

   ```yaml
   # conf/config.yaml
   apisix:
     extra_lua_path: "/opt/ai-decision-router/?.lua"   # dir containing apisix/plugins/
   ```

2. Enable it. Listing `plugins` in `config.yaml` **replaces** the default
   list, so keep the plugins you use. `ai-proxy` needs `prometheus` loaded too:

   ```yaml
   plugins:
     - ai-decision-router
     - ai-proxy-multi
     - ai-proxy
     - prometheus
     # ... the rest of your plugins
   ```

3. Restart APISIX (or `apisix reload`), then attach the plugin to a route
   together with `ai-proxy` / `ai-proxy-multi` (see
   [`examples/`](examples/)).

Tested with APISIX 3.19.0 (`apache/apisix:3.19.0-debian`), and on Kubernetes with
the official Helm chart: see [`deploy/kubernetes/`](deploy/kubernetes/README.md).

## Configuration

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `candidates` | array, 2–64, **required** | | The models to choose between. |
| `candidates[].name` | string, **required** | | Option id given to the decision model (`[A-Za-z0-9_.:-]+`). |
| `candidates[].description` | string, **required** | | Routing role: what requests this model should get. This is the routing policy. |
| `candidates[].model` | string | `name` | Value written into the request's `model` field. |
| `candidates[].instance` | string | `name` | `ai-proxy-multi` instance to use. |
| `decision.endpoint` | string, **required** | | Decision model API (`http(s)://…/v1/systemone`). |
| `decision.model` | string, **required** | | Decision model name, e.g. `alias-clef`. |
| `decision.auth.header` | object | | Headers sent to the decision model, e.g. `{"Authorization": "Bearer …"}`. Encrypted at rest when APISIX data encryption is on. |
| `decision.instructions` | string | built-in | Instructions of the routing question. |
| `decision.timeout` | integer (ms) | `5000` | Decision request timeout. |
| `decision.ssl_verify` | boolean | `true` | Verify the decision endpoint's TLS certificate. |
| `fallback` | string | first candidate | Candidate used when the decision fails or is unsure. |
| `min_confidence` | number 0–1 | `0` | Decisions below this confidence use `fallback`. |
| `context` | `last_user` \| `conversation` | `last_user` | What the decision model sees: the last user message, or the whole conversation (`role: text` lines, system prompt included). |
| `max_chars` | integer | `8000` | Keep only the last `max_chars` characters of that text. |
| `trigger_models` | array of strings | unset | Only route requests whose `model` is in this list (or missing). Unset: route every request. |
| `rewrite_model` | boolean | `true` | Rewrite the body's `model` field. Turn off with `ai-proxy-multi` instances that set `options.model` themselves. |
| `response_headers` | boolean | `true` | Add the `X-AI-Routing-*` response headers below. |
| `fail_mode` | `skip` \| `warn` \| `error` | `skip` | What to do with requests that are not JSON: pass through, pass through and log a warning, or reject with 400. |

### Response headers

| Header | Value |
| --- | --- |
| `X-AI-Routed-Model` | the model the request was sent to |
| `X-AI-Routing-Confidence` | decision model's confidence for that choice (absent on fallback without a decision) |
| `X-AI-Routing-Fallback` | why the fallback was used: `decision error: …`, `low confidence …`, `unknown choice …`, `no prompt text` |

### Variables for logging

`$ai_routed_model` holds the chosen model. It is an APISIX context variable, so
logger plugins' `log_format` (e.g. `http-logger`) can use it; nginx's own
`access_log_format` cannot. `$request_llm_model` (APISIX's own variable) is updated to the
chosen model as well, so `ai-rate-limiting`, prometheus labels and loggers see it.

## Using it with ai-proxy-multi

Name each instance like the candidate (or set `candidates[].instance`). The
plugin then replaces the instance the balancer picked:

```yaml
plugins:
  ai-decision-router:
    rewrite_model: false            # instances pin their own options.model
    fallback: general
    candidates:
      - { name: code,    description: "Programming and debugging." }
      - { name: general, description: "Everything else." }
  ai-proxy-multi:
    instances:
      - { name: code,    provider: openai, weight: 1, options: { model: gpt-5-codex }, auth: {...} }
      - { name: general, provider: openai, weight: 1, options: { model: gpt-5-mini },  auth: {...} }
```

`ai-proxy-multi`'s own retry logic (`fallback_strategy`) still applies: if the
chosen instance fails with a 429/5xx, ai-proxy-multi picks another instance
with its balancer.

## Failure behaviour

The decision model is advisory. It never blocks a request:

- decision endpoint down, slow (beyond `decision.timeout`), non-200 or malformed → `fallback`
- choice not among the candidates → `fallback`
- confidence below `min_confidence` → `fallback`
- no text in the request (e.g. image-only) → `fallback`
- body not JSON → controlled by `fail_mode` (default `skip`: pass through untouched)

The reason is logged at `warn` level and sent in `X-AI-Routing-Fallback`.

## Testing

```sh
t/run.sh                 # APISIX's Test::Nginx harness: 21 blocks, 75 assertions
```

```sh
test/run_e2e.sh          # needs Docker; --keep leaves the stack running
```

Starts APISIX 3.19 with the plugin and a Python mock that acts as both the
decision model and the LLM, then checks 20 cases: ai-proxy, ai-proxy-multi,
plain upstream, fallback on decision errors, `min_confidence`,
`trigger_models`, Responses-API bodies and the decision request itself.

Against a running gateway with real models:

```sh
python3 test/live_routing.py http://127.0.0.1:9080/v1/chat/completions
```

## Repository layout

```
apisix/plugins/ai-decision-router.lua   the plugin
examples/blablador/                     standalone gateway for Blablador (docker compose)
examples/admin-api-route.sh             same route via the Admin API (etcd mode)
test/                                   end-to-end tests (docker compose + mock), live_routing.py
deploy/kubernetes/                      Helm values + deploy script for Kubernetes
docs/ai-decision-router.md              plugin reference (APISIX plugin doc format); docs/zh/ in Chinese
t/plugin/ai-decision-router.t           Test::Nginx tests in APISIX's harness (t/run.sh)
contrib/prepare_apisix_pr.py            copies the plugin into an APISIX checkout for a PR
docs/design.md                          how it hooks into APISIX, design decisions
docs/upstreaming.md                     how to submit the plugin to Apache APISIX
site/                                   GitHub Pages homepage + docs viewer (site/build.sh)
.github/workflows/                      CI (lint + e2e) and Pages deployment
```

## License

Apache License 2.0 (same as Apache APISIX), see [LICENSE](LICENSE).
