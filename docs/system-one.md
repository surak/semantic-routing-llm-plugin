---
title: system_one algorithm
---

# The `system_one` algorithm of ai-proxy-multi

This page documents the `system_one` balancer algorithm proposed for the [`ai-proxy-multi`](https://apisix.apache.org/docs/apisix/plugins/ai-proxy-multi/) Plugin of Apache APISIX. It is generated from the APISIX docs on the [feature branch](https://github.com/surak/apisix/tree/feat/ai-proxy-multi-system-one), so it matches what the pull request adds. Attributes not listed here are those of `ai-proxy-multi`.

## Attributes

| Name                               | Type            | Required | Default                           | Valid values | Description |
|------------------------------------|----------------|----------|-----------------------------------|--------------|-------------|
| balancer.algorithm                 | string         | False    | roundrobin                     | [roundrobin, chash, semantic, system_one] | Load balancing algorithm. When set to `roundrobin`, weighted round robin algorithm is used. When set to `chash`, consistent hashing algorithm is used. When set to `semantic`, the Plugin picks an instance by the semantic similarity between the request prompt and each instance's `examples`, and its options are configured under `semantic_opts`. Note that `semantic` does not participate in health checks or `fallback_strategy` / retry — an upstream failure on the chosen instance is returned to the client; it only falls back (to the `semantic_opts.fallback` instance, else the first instance) when no instance clears its threshold or embedding fails. When set to `system_one`, the Plugin asks a System One model to rank the instances by their `description` and picks the most probable available instance; its options are configured under `system_one_opts`. Unlike `semantic`, `system_one` skips instances that fail health checks or are rate limited, and retries down the ranking on `fallback_strategy` errors. |
| instances.description               | string         | False    |                                   | 1 to 4096 characters | Used when `algorithm` is `system_one`. Routing role of the instance in plain language, for example `Debugging existing code and reviewing patches.` It is sent to the System One model as the criterion of the instance's option. Required for every instance when `algorithm` is `system_one`, including the one named by `system_one_opts.fallback`. |
| system_one_opts                     | object         | False    |                                   |              | Options for the `system_one` balancer. Required when `balancer.algorithm` is `system_one`. |
| system_one_opts.endpoint            | string         | True     |                                   |              | URL of the System One API, for example `https://api.typesafe.ai/v1/systemone`. When the URL has no path, `/v1/systemone` is used. |
| system_one_opts.model               | string         | True     |                                   |              | System One model that ranks the instances, for example `jev-latest`. |
| system_one_opts.auth                | object         | False    |                                   |              | Authentication configurations for the System One API. |
| system_one_opts.auth.header         | object         | False    |                                   |              | Authentication headers. Encrypted at rest. |
| system_one_opts.auth.query          | object         | False    |                                   |              | Authentication query parameters. Encrypted at rest. |
| system_one_opts.instructions        | string         | False    |                                   |              | Instructions of the routing question. Defaults to a generic instruction to pick the best-suited instance. |
| system_one_opts.threshold           | number         | False    | 0                               | 0 to 1       | Minimum probability the System One model must assign to an instance for it to be picked. When no available instance clears it, the request goes to the `fallback` instance, or the first instance if none is named. This also applies to retries: a retry goes to the next instance in the ranking only if it clears the threshold, else to the `fallback` instance. |
| system_one_opts.fallback            | string         | False    |                                   |              | Name of the instance to route to when the System One request fails or no instance clears the threshold. It is otherwise a normal ranked instance and needs a `description` like the rest. Defaults to the first instance when unset. |
| system_one_opts.timeout             | integer        | False    | 3000                            | minimum = 1  | System One request timeout in milliseconds. The request is made synchronously for every client request, so this bounds the latency added when the endpoint is slow or down (the request then fails open to the fallback). |
| system_one_opts.ssl_verify          | boolean        | False    | true                            |              | If true, verify the System One API's certificate. |
| system_one_opts.debugging           | boolean        | False    | false                           |              | If true, expose the per-instance probabilities and the routing decision via `X-AI-System-One-Probabilities` and `X-AI-System-One-Picked-Instance` response headers, for debugging. |

## Example: Route with a System One Model

The following example demonstrates how you can use the `system_one` algorithm to have a System One model pick the instance for each request. A System One model, such as TypeSafe's Jev, is a discriminative model: instead of generating text, it answers typed questions about an input with probability distributions, served by the [System One API](https://docs.typesafe.ai/api) (`POST /v1/systemone`). The Plugin sends the request prompt as the `state` and asks one `choice` question whose options are the instance names, each described by the instance's `description`. It then forwards the request to the most probable instance that is healthy and not rate limited. The `weight` and `priority` of the instances are not used.

Compared with `semantic`, the routing policy is a plain-language description of each instance rather than a set of example prompts, and no embedding model is needed. Because the model gives every instance a probability, the Plugin can skip unhealthy or rate-limited instances and retry on the next most probable instance.

Create a Route as such and update the LLM providers, System One endpoint and model, and API keys accordingly. The `default` instance is named as the `system_one_opts.fallback`, used when the System One request fails or no instance clears the threshold:

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "ai-proxy-multi-route",
    "uri": "/anything",
    "methods": ["POST"],
    "plugins": {
      "ai-proxy-multi": {
        "balancer": {
          "algorithm": "system_one"
        },
        "system_one_opts": {
          "endpoint": "https://api.typesafe.ai/v1/systemone",
          "model": "jev-latest",
          "auth": {
            "header": {
              "Authorization": "Bearer '"$YOUR_SYSTEM_ONE_API_KEY"'"
            }
          },
          "threshold": 0.3,
          "fallback": "default"
        },
        "fallback_strategy": ["http_429", "http_5xx"],
        "instances": [
          {
            "name": "code",
            "provider": "openai",
            "weight": 1,
            "auth": {
              "header": {
                "Authorization": "Bearer '"$YOUR_LLM_API_KEY"'"
              }
            },
            "options": {
              "model": "gpt-4o"
            },
            "description": "Writing, debugging and reviewing code."
          },
          {
            "name": "translate",
            "provider": "openai",
            "weight": 1,
            "auth": {
              "header": {
                "Authorization": "Bearer '"$YOUR_LLM_API_KEY"'"
              }
            },
            "options": {
              "model": "gpt-4o-mini"
            },
            "description": "Translating and summarizing text."
          },
          {
            "name": "default",
            "provider": "openai",
            "weight": 1,
            "auth": {
              "header": {
                "Authorization": "Bearer '"$YOUR_LLM_API_KEY"'"
              }
            },
            "options": {
              "model": "gpt-4o-mini"
            },
            "description": "General questions and conversation with no specialist need."
          }
        ]
      }
    }
  }'
```

Send a request with a programming prompt:

```shell
curl "http://127.0.0.1:9080/anything" -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [
      { "role": "user", "content": "help me debug this python code" }
    ]
  }'
```

The request should be routed to the `code` instance and served by `gpt-4o`. If the `code` instance answers with a `429` or `5xx` status, the request is retried on the next most probable instance that clears `threshold`, or else on the `default` fallback instance, without asking the System One model again. Each instance is tried at most once per request, and `max_retries` and `retry_on_failure_within_ms` apply as with the other algorithms.

The Plugin sends the System One API a request similar to the following, with the prompt cut to at most 16 KiB:

```json
{
  "model": "jev-latest",
  "state": "help me debug this python code",
  "questions": {
    "instance": {
      "type": "choice",
      "instructions": "Choose the option best suited to answer this request. ...",
      "criteria": {
        "code": "Writing, debugging and reviewing code.",
        "translate": "Translating and summarizing text.",
        "default": "General questions and conversation with no specialist need."
      }
    }
  }
}
```

It ranks the instances by `answers.instance.probabilities` in the response, most probable first; an instance missing from the distribution has probability 0. Any other response sends the request to the fallback instance.

### Debugging the routing decision

Set `system_one_opts.debugging` to `true` to have the Plugin report the probability of each instance and which one it picked:

```text
HTTP/1.1 200 OK
X-AI-System-One-Picked-Instance: code
X-AI-System-One-Probabilities: code:0.9100,default:0.0600,translate:0.0300
```

`X-AI-System-One-Probabilities` lists every instance, most probable first. Use it to calibrate `threshold` and the `description` of each instance. After a retry, `X-AI-System-One-Picked-Instance` names the instance that served the request.

When the System One request fails, or no available instance clears the threshold, the Plugin logs the reason at `warn` level and routes to the fallback instance:

```text
system_one routing: system one request failed: request: timeout, falling back
system_one routing: no available instance cleared the threshold, falling back to default
```

Because `debugging` reveals instance names to the caller, keep it off in production and rely on the log lines instead.
