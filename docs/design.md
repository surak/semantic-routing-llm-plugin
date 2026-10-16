# Design notes

How `ai-decision-router` hooks into APISIX, and why it is built this way.
Source references are to APISIX 3.19.0.

## Where it runs: priority 1039

APISIX runs a route's plugins in each phase in descending priority. The AI
plugins involved:

| Plugin | Priority | Access phase |
| --- | --- | --- |
| `ai-prompt-*`, `ai-rag` | 1060–1073 | rewrite / augment the prompt |
| `ai-proxy-multi` | 1041 | parse body, detect protocol, **pick an instance** |
| `ai-proxy` | 1040 | parse body, detect protocol |
| **`ai-decision-router`** | **1039** | **ask the decision model, override model / instance** |
| `ai-cache` | 1035 | |
| `ai-rate-limiting` | 1030 | |

The request is sent to the LLM later, in `before_proxy`
(`apisix/plugins/ai-proxy/base.lua`). Running at 1039 means:

- prompt plugins (`ai-prompt-decorator`, `ai-rag`, ...) have already changed
  the prompt, so the decision is made on what the LLM will actually receive;
- `ai-proxy-multi` has already picked an instance, which we can overwrite;
- `ai-cache` and `ai-rate-limiting` run afterwards and see the routed model.

1039 is not used by any built-in plugin.

## How the override works

**Body `model`.** `core.request.get_json_request_body_table()` parses the body
once per request and caches the table in `ctx._request_body_table`.
`before_proxy` reads that same cached table, deep-copies it and takes
`model` from it unless the instance pins `options.model`. Changing
`body.model` on the cached table is therefore enough for `ai-proxy` and
`ai-proxy-multi`. The plugin also calls `ngx.req.set_body_data()` so a plain
`upstream` receives the rewritten body, and updates `ctx.var.request_llm_model`
which `ai-proxy`'s access phase set from the original body.

**ai-proxy-multi instance.** `ai-proxy-multi`'s access phase stores its choice in
`ctx.picked_ai_instance_name`, `ctx.picked_ai_instance` and `ctx.balancer_ip`;
`before_proxy` uses `ctx.picked_ai_instance`. The plugin finds the
`ai-proxy-multi` conf in `ctx.plugins` (a flat `{plugin, conf, plugin, conf, ...}`
list) and sets those three fields to the instance named like the candidate. On a
429/5xx, ai-proxy-multi's `retry_on_error` re-picks with its own balancer, so
retries are not routed by the decision model.

Instances that use active health checks get their resolved endpoint
(`_resolved_endpoint`) from `ai-proxy-multi`'s picker only for the instance the
picker chose. For the overriding instance `before_proxy` falls back to
`override.endpoint`, which is what instances without health checks use anyway.

## The decision request

One `choice` question named `route`; the criteria are the candidates' names and
descriptions:

```json
POST /v1/systemone
{
  "model": "alias-clef",
  "state": "<last user message, or the whole conversation>",
  "questions": {
    "route": {
      "type": "choice",
      "instructions": "Choose the model best suited ...",
      "criteria": { "alias-code": "Routing role: debugging ...", "...": "..." }
    }
  }
}
```

The response's `answers.route.choice` is the winner; `confidence` (or, when
absent, `probabilities[choice]`) is compared to `min_confidence`.

The call uses `resty.http` (a non-blocking cosocket, allowed in the access
phase) with `decision.timeout`. It adds one decision round-trip to every routed
request.

### Text extraction

The prompt is read with APISIX's `ai-protocols` module
(`ai_protocols.get_messages(body, ctx)`), the same protocol-aware reader that
`ai-proxy-multi`'s semantic routing and the prompt plugins use. Every chat
protocol `ai-proxy` understands therefore works: OpenAI Chat Completions,
OpenAI Responses, Anthropic Messages and Bedrock Converse. It detects the
protocol itself, so it also works on routes without `ai-proxy`.

Only text parts are used. `context: last_user` sends the last user message
(the usual signal for "what is this request about"); `conversation` sends
every message as `role: text` lines. Long text keeps its tail (`max_chars`),
since the latest turn matters most.

Requests that are not JSON follow `fail_mode` (the shared
`ai-protocols.binding` helper): `skip` (default) passes them through,
`warn` also logs, `error` rejects them with 400.

### No vendor defaults

`decision.endpoint` and `decision.model` are required. An earlier version
defaulted to the Blablador endpoint, which is fine for a private deployment
but not for a general-purpose plugin.

## Why a separate plugin, not a new ai-proxy-multi balancer

`ai-proxy-multi` balancer algorithms are built into its source
(`roundrobin`, `chash`, `semantic`); there is no extension point for a custom
picker. A separate plugin:

- needs no patch to APISIX and survives upgrades;
- works with `ai-proxy` and plain upstreams too, not only `ai-proxy-multi`;
- can be enabled per route next to an unchanged `ai-proxy(-multi)` config.

The cost is that it relies on the `ctx` fields listed above, which are internal.
`test/run_e2e.sh` checks them against a real APISIX; run it when upgrading.

## Why fail open

Routing is an optimisation. If the decision model is unreachable, sending the
request to a reasonable default (`fallback`) is better than failing it, so
every error path ends in the fallback and is reported in a response header
and a `warn` log line.

## Not done (yet)

- No caching of decisions: identical prompts are decided again.
- Retries by `ai-proxy-multi` after a failure do not consult the decision model.
- The decision model's token usage is not added to APISIX's LLM metrics.
