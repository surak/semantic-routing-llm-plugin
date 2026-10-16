# System One routing for Apache APISIX

[![CI](https://github.com/surak/semantic-routing-llm-plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/surak/semantic-routing-llm-plugin/actions/workflows/ci.yml)

Documentation: **https://surak.github.io/semantic-routing-llm-plugin/**

A new load-balancing algorithm for the [`ai-proxy-multi`](https://apisix.apache.org/docs/apisix/plugins/ai-proxy-multi/)
plugin of [Apache APISIX](https://apisix.apache.org/ai-gateway/): **`system_one`** routes each LLM
request to the instance that a *System One model* ranks highest.

A System One model, such as [TypeSafe Jev](https://en.wikipedia.org/wiki/Jev_(AI_model)),
Cloudflare Clef or Blablador's `alias-clef`, is a discriminative model: instead of generating
text, it answers typed questions about an input with a probability distribution, in tens to
hundreds of milliseconds. `system_one` asks one question per request, "which of these instances
should answer this prompt?", where each option is an instance described by its routing role in
plain language:

```
client ──► APISIX ai-proxy-multi ──► System One model: rank code / math / general for this prompt
                    │                  ◄── {code: 0.91, general: 0.06, math: 0.03}
                    ▼
          most probable healthy instance ──► LLM
          (on 429/5xx: next in the ranking, else the fallback)
```

```yaml
ai-proxy-multi:
  balancer:
    algorithm: system_one
  system_one_opts:
    endpoint: https://api.blablador.fz-juelich.de/v1/systemone
    model: alias-clef
    auth: { header: { Authorization: "Bearer ..." } }
    threshold: 0.3
    fallback: general
  fallback_strategy: [http_429, http_5xx]
  instances:
    - name: code
      description: "Debugging existing code and reviewing patches."
      provider: openai-compatible
      ...
    - name: general
      description: "Broad questions with no dominant specialist."
      ...
```

Compared with `ai-proxy-multi`'s `semantic` algorithm (embedding similarity to example
prompts), the policy is one readable sentence per instance, no embedding model is needed, and
because every instance gets a probability, `system_one` can skip unhealthy or rate-limited
instances and retry down the ranking.

## Status

The algorithm is implemented as a change to APISIX itself, on the branch
[`surak/apisix:feat/ai-proxy-multi-system-one`](https://github.com/surak/apisix/tree/feat/ai-proxy-multi-system-one),
to be proposed upstream (see [Submitting to APISIX](docs/upstreaming.md)). This repository is the
project home: documentation, examples, deployment and tests, and a way to run the feature on a
released APISIX today:

| Directory | Contents |
| --- | --- |
| `patches/` | The branch as a patch series for `git am` on apache/apisix `master` |
| `overlay/` | The three changed Lua modules, to run `system_one` on APISIX 3.19 unchanged |
| `examples/blablador/` | Gateway routing to 14 Blablador models with `alias-clef` (Docker Compose) |
| `deploy/kubernetes/` | Helm values and a deploy script for Kubernetes |
| `test/` | End-to-end tests (Docker Compose + mock System One API and LLMs), live routing test |
| `t/` | Runs APISIX's Test::Nginx suites with the patch applied |
| `docs/`, `site/` | Documentation and the GitHub Pages site |
| `contrib/` | Refreshes `patches/` and `overlay/` from the APISIX branch |

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
X-AI-System-One-Picked-Instance: alias-mimo-v2.6-pro
X-AI-System-One-Probabilities: alias-mimo-v2.6-pro:0.9410,alias-mimo-v2.6-flash:0.0201,...
```

The example has `debugging` on, which adds those headers; turn it off in production.

Observed with the live Blablador API (2026-10-16):

| Prompt | Picked instance | Probability |
| --- | --- | --- |
| Python traceback: KeyError in a loop | `alias-code` | 0.81 |
| Implement an LRU cache in Rust | `alias-glm-5.3-flash` | 0.74 |
| One-line bash, "in 2 seconds" | `alias-qwen38-quick` | 0.95 |
| Prove √2 is irrational | `alias-mimo-v2.6-pro` | 0.94 |
| Sentinel-2 deforestation pipeline | `alias-eve` | 0.95 |
| German press release | `alias-apertus` | 0.91 |
| Rainy-Monday motivation | `alias-muse` | 0.89 |
| 400 PDFs of meeting minutes | `alias-kimi-k3-1m` | 0.93 |
| Capital of Australia | `alias-fast` | 0.94 |
| Multi-agent deployment system | `alias-huge` (0.92) answered 503, so the request was retried on the fallback `alias-large` | |

## Run on APISIX 3.19

`ai-proxy-multi.lua` and `apisix/plugins/ai-proxy/` are identical in APISIX 3.19.0 and `master`,
so the overlay works on the released version. Put `overlay/` first on the Lua path:

```yaml
# conf/config.yaml
apisix:
  extra_lua_path: "/path/to/overlay/?.lua"
```

and reload. Keep the default plugin list (do not set `plugins`), or keep `ai-proxy-multi` in it.
On Kubernetes, `deploy/kubernetes/deploy.sh` does this with the official Helm chart; see
[deploy/kubernetes](deploy/kubernetes/README.md).

## Configuration

`balancer.algorithm: system_one`, the options under `system_one_opts`, and a `description` on
every instance. See the [configuration reference](docs/system-one.md) and the
[System One API](docs/system-one-api.md) it talks to.

## Testing

```sh
t/run.sh                 # APISIX's Test::Nginx suites with the patch applied
test/run_e2e.sh          # stock APISIX 3.19 + overlay + mocks (Docker Compose)
python3 test/live_routing.py http://127.0.0.1:9080/v1/chat/completions   # a live gateway
```

`t/run.sh` runs the new `t/plugin/ai-proxy-multi-system-one.t` (19 blocks) and, as regression
checks, the semantic, retry and balancer suites of `ai-proxy-multi`. CI also applies the patch to
APISIX `master` and runs APISIX's linters on it.

## License

Apache License 2.0, see [LICENSE](LICENSE). `overlay/` and `patches/` contain modified Apache
APISIX source files and keep their ASF license headers; see [NOTICE](NOTICE).
