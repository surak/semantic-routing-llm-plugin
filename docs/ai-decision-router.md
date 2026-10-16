---
title: ai-decision-router
keywords:
  - Apache APISIX
  - API Gateway
  - Plugin
  - ai-decision-router
  - AI Gateway
  - LLM routing
description: The ai-decision-router plugin asks a decision model which LLM fits each request and routes the request to it, working together with ai-proxy, ai-proxy-multi or a plain upstream.
---

## Description

The `ai-decision-router` plugin routes each LLM request to the model best suited for it.
For every request it sends the prompt to a typed decision model (a Clef-compatible
`/v1/systemone` endpoint, by default Blablador's `alias-clef`) together with your
candidate models and their routing roles. The decision model returns a choice and a
confidence, and the plugin sends the request there:

- with [`ai-proxy`](https://apisix.apache.org/docs/apisix/plugins/ai-proxy/), it rewrites the request body's `model`;
- with [`ai-proxy-multi`](https://apisix.apache.org/docs/apisix/plugins/ai-proxy-multi/), it replaces the instance the balancer picked;
- with a plain upstream, it rewrites the forwarded body's `model`.

Routing is advisory: when the decision model fails, times out or is unsure, the request
goes to the `fallback` candidate instead of failing.

The plugin runs in the `access` phase with priority `1039`, after `ai-proxy-multi` (1041)
and `ai-proxy` (1040) and before `ai-cache` (1035) and `ai-rate-limiting` (1030).

## Attributes

| Name | Type | Required | Default | Valid values | Description |
| --- | --- | --- | --- | --- | --- |
| candidates | array[object] | True | | 2–64 items | Models to choose between. |
| candidates.name | string | True | | `^[A-Za-z0-9_.:-]+$`, unique | Option id given to the decision model. |
| candidates.description | string | True | | | Routing role: which requests this model should get. |
| candidates.model | string | False | `name` | | Value written into the request body's `model`. |
| candidates.instance | string | False | `name` | | `ai-proxy-multi` instance to use. |
| decision | object | False | `{}` | | Decision model settings. |
| decision.endpoint | string | False | `https://api.blablador.fz-juelich.de/v1/systemone` | | Decision model API URL. |
| decision.model | string | False | `alias-clef` | | Decision model name. |
| decision.auth.header | object | False | | | Headers sent to the decision model, e.g. `Authorization`. Encrypted in etcd when data encryption is enabled. |
| decision.instructions | string | False | built-in | | Instructions of the routing question. |
| decision.timeout | integer | False | 5000 | ≥ 1 | Timeout of the decision request in milliseconds. |
| decision.ssl_verify | boolean | False | true | | Verify the decision endpoint's TLS certificate. |
| fallback | string | False | first candidate | a candidate name | Candidate used when no usable decision is available. |
| min_confidence | number | False | 0 | [0, 1] | Decisions below this confidence use `fallback`. |
| context | string | False | `last_user` | `last_user`, `conversation` | Text given to the decision model: the last user message, or the whole conversation. |
| max_chars | integer | False | 8000 | ≥ 1 | Keep only the last `max_chars` characters of that text. |
| trigger_models | array[string] | False | | | Route only requests whose `model` is in this list or missing. Unset: route all requests. |
| rewrite_model | boolean | False | true | | Rewrite the request body's `model`. |
| response_headers | boolean | False | true | | Add `X-AI-Routed-Model`, `X-AI-Routing-Confidence` and `X-AI-Routing-Fallback` to the response. |

The plugin sets the variable `$ai_routed_model` to the chosen model and updates
`$request_llm_model`, so logger plugins, `ai-rate-limiting` and metrics see the routed model.

## Enable plugin

`ai-decision-router` is not bundled with APISIX. Put the repository on APISIX's Lua path
and add the plugin to `plugins` in `config.yaml` (this list replaces the default one, so
keep the plugins you use; `ai-proxy` also needs `prometheus`):

```yaml
apisix:
  extra_lua_path: "/opt/ai-decision-router/?.lua"
plugins:
  - ai-decision-router
  - ai-proxy-multi
  - ai-proxy
  - prometheus
```

Then reload APISIX.

:::note
You can fetch the `admin_key` from `config.yaml` and save to an environment variable with the following command:

```bash
admin_key=$(yq '.deployment.admin.admin_key[0].key' conf/config.yaml | sed 's/"//g')
```

:::

## Examples

### Route requests for `auto` to the best model

The following example creates a route that answers OpenAI-style chat requests. Requests
with `"model": "auto"` are routed by `alias-clef`; requests naming a model pass through.

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "ai-decision-router-route",
    "uri": "/v1/chat/completions",
    "methods": ["POST"],
    "plugins": {
      "ai-decision-router": {
        "decision": {
          "auth": { "header": { "Authorization": "Bearer '"$BLABLADOR_API_KEY"'" } }
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
        "auth": { "header": { "Authorization": "Bearer '"$BLABLADOR_API_KEY"'" } },
        "override": { "endpoint": "https://api.blablador.fz-juelich.de/v1/chat/completions" }
      }
    }
  }'
```

Send a request:

```shell
curl -i "http://127.0.0.1:9080/v1/chat/completions" -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [{ "role": "user", "content": "Prove that there are infinitely many primes." }]
  }'
```

You should receive an `HTTP/1.1 200 OK` response from the chosen model, with:

```text
X-AI-Routed-Model: alias-mimo-v2.6-pro
X-AI-Routing-Confidence: 0.9326
```

### Pick the instance of ai-proxy-multi

Name the `ai-proxy-multi` instances like the candidates (or set `candidates.instance`).
The plugin replaces the instance the balancer picked. Set `rewrite_model` to `false` when
the instances set `options.model` themselves:

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "ai-decision-router-multi",
    "uri": "/v1/chat/completions",
    "methods": ["POST"],
    "plugins": {
      "ai-decision-router": {
        "decision": { "auth": { "header": { "Authorization": "Bearer '"$BLABLADOR_API_KEY"'" } } },
        "rewrite_model": false,
        "fallback": "general",
        "candidates": [
          { "name": "code",    "description": "Programming, debugging and code review." },
          { "name": "general", "description": "Everything else: chat, writing, summaries." }
        ]
      },
      "ai-proxy-multi": {
        "instances": [
          {
            "name": "code", "provider": "openai", "weight": 1,
            "auth": { "header": { "Authorization": "Bearer '"$OPENAI_API_KEY"'" } },
            "options": { "model": "gpt-5-codex" }
          },
          {
            "name": "general", "provider": "openai", "weight": 1,
            "auth": { "header": { "Authorization": "Bearer '"$OPENAI_API_KEY"'" } },
            "options": { "model": "gpt-5-mini" }
          }
        ]
      }
    }
  }'
```

If the chosen instance fails with a status covered by `ai-proxy-multi`'s
`fallback_strategy`, `ai-proxy-multi` retries on another instance with its own balancer.

### Fall back when the decision is unsure

With `min_confidence`, decisions below the threshold go to `fallback`. The response then
carries the reason:

```text
X-AI-Routed-Model: alias-large
X-AI-Routing-Fallback: low confidence 0.21
```

The same header reports `decision error: …` when the decision model is unreachable,
times out or returns an error, `unknown choice …` and `no prompt text`.

## Delete plugin

To remove the plugin, delete its entry from the route's `plugins`. APISIX reloads
automatically; no restart is needed.

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes/ai-decision-router-route" -X PATCH \
  -H "X-API-KEY: ${admin_key}" \
  -d '{ "plugins": { "ai-decision-router": null } }'
```
