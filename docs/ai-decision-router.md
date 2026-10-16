---
title: ai-decision-router
keywords:
  - Apache APISIX
  - API Gateway
  - Plugin
  - ai-decision-router
  - AI
  - LLM Routing
description: The ai-decision-router Plugin asks a decision model which LLM fits each request and routes the request to it, working with ai-proxy, ai-proxy-multi, or a plain Upstream.
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

## Description

The `ai-decision-router` Plugin routes each LLM request to the model best suited for it. For every request, it sends the prompt to a typed decision model together with your candidate models and a routing role for each, and routes the request to the candidate the decision model picks.

The decision model is any service that implements the Clef-compatible `/v1/systemone` API: it takes a `state` (the prompt) and typed `questions`, and returns a decision with per-option probabilities. The Plugin sends one `choice` question whose options are the candidates.

The Plugin works with the [`ai-proxy`](./ai-proxy.md) Plugin, the [`ai-proxy-multi`](./ai-proxy-multi.md) Plugin, or a plain Upstream:

- With `ai-proxy`, it rewrites the `model` field of the request body.
- With `ai-proxy-multi`, it replaces the instance picked by the balancer with the chosen candidate's instance.
- With a plain Upstream, it rewrites the `model` field of the forwarded request body.

Routing is advisory. When the decision model fails, times out, returns an unknown choice, or is less confident than `min_confidence`, the Plugin routes the request to the `fallback` candidate instead of rejecting it.

The Plugin reads the prompt in a protocol-aware way, so it supports every chat protocol that `ai-proxy` supports, such as OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages. It runs in the `access` phase with priority `1039`, after `ai-proxy-multi` and `ai-proxy` and before `ai-cache` and `ai-rate-limiting`, so those Plugins see the routed model.

Compared with the `semantic` algorithm of `ai-proxy-multi`, which picks the instance whose example prompts are most similar to the request, this Plugin needs no examples or embedding model: the routing policy is the plain-text routing role of each candidate.

## Attributes

| Name | Type | Required | Default | Valid values | Description |
|------|------|----------|---------|--------------|-------------|
| decision | object | True | | | Decision model configuration. |
| decision.endpoint | string | True | | URL starting with `http://` or `https://` | URL of the decision API, for example `https://example.com/v1/systemone`. |
| decision.model | string | True | | | Name of the decision model. |
| decision.auth.header | object | False | | | Request headers sent to the decision model, such as `Authorization`. The values are encrypted with AES before being stored in etcd. |
| decision.instructions | string | False | Generic routing instruction | | Instructions of the routing question. |
| decision.timeout | integer | False | `5000` | >= 1 | Decision request timeout in milliseconds. |
| decision.ssl_verify | boolean | False | `true` | | If `true`, verify the TLS certificate of the decision endpoint. |
| candidates | array[object] | True | | 2 to 64 items | Models to choose between. |
| candidates.name | string | True | | `^[A-Za-z0-9_.:-]+$`, unique | Option ID given to the decision model. |
| candidates.description | string | True | | | Routing role of the candidate: which requests it should receive. |
| candidates.model | string | False | `name` | | Value written into the `model` field of the request body. |
| candidates.instance | string | False | `name` | | Name of the `ai-proxy-multi` instance to use. |
| fallback | string | False | First candidate | A candidate `name` | Candidate used when no usable decision is available. |
| min_confidence | number | False | `0` | [0, 1] | Decisions with a lower confidence use `fallback`. |
| context | string | False | `last_user` | `last_user`, `conversation` | Text sent to the decision model. `last_user` sends the last user message. `conversation` sends every message as `role: text` lines. |
| max_chars | integer | False | `8000` | >= 1 | Keep only the last `max_chars` characters of that text. |
| trigger_models | array[string] | False | | | If set, only route requests whose `model` is in this list or missing, and pass other requests through unchanged. If unset or empty, route every request. |
| rewrite_model | boolean | False | `true` | | If `true`, rewrite the `model` field of the request body. Set to `false` when the `ai-proxy-multi` instances set `options.model`. |
| response_headers | boolean | False | `true` | | If `true`, add the `X-AI-Routed-Model`, `X-AI-Routing-Confidence`, and `X-AI-Routing-Fallback` response headers. |
| fail_mode | string | False | `skip` | `skip`, `warn`, `error` | Behavior when the request is not a JSON request the Plugin can read. `skip`: pass the request through unchanged. `warn`: pass through and log a warning. `error`: reject the request. |

The Plugin also sets the `$ai_routed_model` variable to the chosen model and updates `$request_llm_model`, so logger Plugins, `ai-rate-limiting`, and metrics see the routed model.

### Response Headers

| Header | Description |
|--------|-------------|
| `X-AI-Routed-Model` | Model the request was routed to. |
| `X-AI-Routing-Confidence` | Confidence of the decision model in its choice. |
| `X-AI-Routing-Fallback` | Reason the `fallback` was used: `decision error: ...`, `low confidence ...`, `unknown choice ...`, or `no prompt text`. |

## Examples

The examples below use OpenAI-compatible models served by a gateway that also hosts a decision model. Replace the endpoints, model names, and keys with your own.

:::note

You can fetch the `admin_key` from `config.yaml` and save it to an environment variable with the following command:

```bash
admin_key=$(yq '.deployment.admin.admin_key[0].key' conf/config.yaml | sed 's/"//g')
```

:::

You can optionally save the API information to environment variables:

```shell
# Replace with your data
export LLM_ENDPOINT=https://llm.example.com/v1/chat/completions
export DECISION_ENDPOINT=https://llm.example.com/v1/systemone
export API_KEY=your-api-key
```

### Route Requests to the Best Model

The following example demonstrates how to route requests that ask for the model `auto` to the best of four models. Requests that name a model are passed through unchanged.

<Tabs
groupId="api"
defaultValue="admin-api"
values={[
{label: 'Admin API', value: 'admin-api'},
{label: 'ADC', value: 'adc'}
]}>

<TabItem value="admin-api">

Create a Route with the `ai-decision-router` and [`ai-proxy`](./ai-proxy.md) Plugins:

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "ai-decision-router-route",
    "uri": "/anything",
    "methods": ["POST"],
    "plugins": {
      "ai-decision-router": {
        "decision": {
          "endpoint": "'"$DECISION_ENDPOINT"'",
          "model": "alias-clef",
          "auth": {
            "header": {
              "Authorization": "Bearer '"$API_KEY"'"
            }
          }
        },
        "trigger_models": ["auto"],
        "fallback": "general",
        "min_confidence": 0.3,
        "candidates": [
          { "name": "fast", "description": "Routine factual questions, short summaries, and simple scripts." },
          { "name": "code", "description": "Debugging existing code and reviewing patches." },
          { "name": "reasoning", "description": "Rigorous mathematical proofs and deep multi-step reasoning." },
          { "name": "general", "description": "Broad synthesis with no dominant specialist." }
        ]
      },
      "ai-proxy": {
        "provider": "openai-compatible",
        "auth": {
          "header": {
            "Authorization": "Bearer '"$API_KEY"'"
          }
        },
        "override": {
          "endpoint": "'"$LLM_ENDPOINT"'"
        }
      }
    }
  }'
```

</TabItem>

<TabItem value="adc">

Create a Route with the `ai-decision-router` and [`ai-proxy`](./ai-proxy.md) Plugins configured as such:

```yaml title="adc.yaml"
services:
  - name: ai-decision-router-service
    routes:
      - name: ai-decision-router-route
        uris:
          - /anything
        methods:
          - POST
        plugins:
          ai-decision-router:
            decision:
              endpoint: "${DECISION_ENDPOINT}"
              model: alias-clef
              auth:
                header:
                  Authorization: "Bearer ${API_KEY}"
            trigger_models:
              - auto
            fallback: general
            min_confidence: 0.3
            candidates:
              - name: fast
                description: Routine factual questions, short summaries, and simple scripts.
              - name: code
                description: Debugging existing code and reviewing patches.
              - name: reasoning
                description: Rigorous mathematical proofs and deep multi-step reasoning.
              - name: general
                description: Broad synthesis with no dominant specialist.
          ai-proxy:
            provider: openai-compatible
            auth:
              header:
                Authorization: "Bearer ${API_KEY}"
            override:
              endpoint: "${LLM_ENDPOINT}"
```

Synchronize the configuration to the gateway:

```shell
adc sync -f adc.yaml
```

</TabItem>

</Tabs>

Send a request to the Route:

```shell
curl -i "http://127.0.0.1:9080/anything" -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [
      { "role": "user", "content": "Prove that there are infinitely many primes." }
    ]
  }'
```

You should receive an `HTTP/1.1 200 OK` response from the `reasoning` model, with headers similar to the following:

```text
X-AI-Routed-Model: reasoning
X-AI-Routing-Confidence: 0.9326
```

Send a request that names a model:

```shell
curl -i "http://127.0.0.1:9080/anything" -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "fast",
    "messages": [
      { "role": "user", "content": "Prove that there are infinitely many primes." }
    ]
  }'
```

You should receive an `HTTP/1.1 200 OK` response from the `fast` model, without the routing headers.

### Pick the Instance of ai-proxy-multi

The following example demonstrates how to use the Plugin with [`ai-proxy-multi`](./ai-proxy-multi.md), where each instance sets its own model. Name the instances like the candidates, or set `candidates.instance`.

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "ai-decision-router-multi-route",
    "uri": "/anything",
    "methods": ["POST"],
    "plugins": {
      "ai-decision-router": {
        "decision": {
          "endpoint": "'"$DECISION_ENDPOINT"'",
          "model": "alias-clef",
          "auth": { "header": { "Authorization": "Bearer '"$API_KEY"'" } }
        },
        "rewrite_model": false,
        "fallback": "general",
        "candidates": [
          { "name": "code", "description": "Programming, debugging, and code review." },
          { "name": "general", "description": "Everything else: chat, writing, and summaries." }
        ]
      },
      "ai-proxy-multi": {
        "instances": [
          {
            "name": "code",
            "provider": "openai-compatible",
            "weight": 1,
            "auth": { "header": { "Authorization": "Bearer '"$API_KEY"'" } },
            "options": { "model": "coder-model" },
            "override": { "endpoint": "'"$LLM_ENDPOINT"'" }
          },
          {
            "name": "general",
            "provider": "openai-compatible",
            "weight": 1,
            "auth": { "header": { "Authorization": "Bearer '"$API_KEY"'" } },
            "options": { "model": "general-model" },
            "override": { "endpoint": "'"$LLM_ENDPOINT"'" }
          }
        ]
      }
    }
  }'
```

Requests about code go to the `code` instance, and other requests go to the `general` instance. If the chosen instance fails with a status covered by the `fallback_strategy` of `ai-proxy-multi`, `ai-proxy-multi` retries another instance using its own balancer.

### Fall Back When the Decision Is Unsure

With `min_confidence` configured as in the first example, a decision with a lower confidence routes the request to `fallback`. The response then carries the reason:

```text
X-AI-Routed-Model: general
X-AI-Routing-Confidence: 0.21
X-AI-Routing-Fallback: low confidence 0.21
```

When the decision model is unreachable, times out, or returns an error, the request also goes to `fallback`, and the Plugin logs a warning:

```text
X-AI-Routed-Model: general
X-AI-Routing-Fallback: decision error: request failed: timeout
```
