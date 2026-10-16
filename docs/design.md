# Design notes

How the `system_one` algorithm fits into `ai-proxy-multi`, and why it is built this way.
Source references are to the
[feature branch](https://github.com/surak/apisix/tree/feat/ai-proxy-multi-system-one), based on
APISIX `master` (identical to 3.19.0 in the files involved).

## Why an algorithm of ai-proxy-multi

The first version of this project was a separate plugin, `ai-decision-router`, that ran after
`ai-proxy-multi` and overwrote the instance it had picked. That worked, but:

- it relied on `ai-proxy-multi`'s internal context fields (`ctx.picked_ai_instance`, the
  plugin list in `ctx.plugins`), which no other plugin should depend on;
- `ai-proxy-multi`'s retries did not know about the decision, so a retry went wherever the
  original balancer pointed;
- APISIX maintainers had already added prompt-based routing as an algorithm *inside*
  `ai-proxy-multi` (`semantic`, apache/apisix#13676).

So `system_one` is a `balancer.algorithm` next to `roundrobin`, `chash` and `semantic`, and the
plugin was removed.

## Files changed

| File | Change |
| --- | --- |
| `apisix/plugins/ai-proxy/system-one.lua` | New. Builds the System One request, sends it through the AI provider layer, turns the answer into a ranking. |
| `apisix/plugins/ai-proxy/schema.lua` | `system_one` in the algorithm enum, `instances.description`, `system_one_opts`, two `encrypt_fields`. |
| `apisix/plugins/ai-proxy-multi.lua` | Schema checks, the picker, ranked retries; health-checker setup factored out of `pick_target` into `fetch_checkers()`. |
| `t/plugin/ai-proxy-multi-system-one.t` | New Test::Nginx suite. |
| `docs/{en,zh}/latest/plugins/ai-proxy-multi.md` | Attribute rows and an example section. |

## How a request is routed

1. `pick_ai_instance` dispatches to `pick_system_one_instance` when the algorithm is
   `system_one`, the same way it dispatches to `pick_semantic_instance`.
2. `system_one_ranking` asks the model once per request and stores the ranking in
   `ctx.ai_system_one_ranking`. The prompt is the last user message, extracted with the same
   function `semantic` uses.
3. The picker walks the ranking and takes the first instance that clears
   `system_one_opts.threshold`, is not marked unhealthy by its active health checker, is not
   rate limited (when `fallback_strategy` includes rate limiting), and has not been tried in this
   request.
4. If nothing qualifies, it takes the `fallback` instance, then the rest in configured order,
   applying the same availability checks.
5. On a 429 or 5xx covered by `fallback_strategy`, `retry_on_error` calls the picker again. The
   failed instance is marked as tried and the stored ranking is reused, so the retry goes to the
   next instance without a second System One request.

`retry_on_error` used to return early when there was no server picker (only `roundrobin` and
`chash` have one). It now also continues when a System One ranking exists.

## Threshold and retries

The threshold applies to retries as well: when the top instance fails and the runners-up are
below the threshold, the retry goes to the fallback, not to an instance the model considered a
poor fit. With the default threshold of 0, every ranked instance is eligible and retries simply
walk down the ranking.

The live Blablador test hit exactly this: `alias-huge` was ranked first at 0.92 for an
architecture question but answered 503 ("temporarily unavailable"); every other model was below
the 0.3 threshold, so the request was retried on the fallback `alias-large` and succeeded.

## Following the `semantic` conventions

Reviewers of `semantic` asked for, and the code now has, the same properties in `system_one`:

- **Shared transport.** The System One request goes through
  `apisix.plugins.ai-providers.openai-compatible`'s `request()`, like the embedding request. It
  sets none of the `client_*` options, so no client header, cookie or query parameter is
  forwarded.
- **No upstream bodies in logs.** Errors report the status code only; the body may echo the
  prompt.
- **Defensive parsing.** A 200 response that is not an object, has no answer, or carries a
  probability that is not a finite number in [0, 1] (cjson decodes `1e999` to infinity) makes
  the request fail open to the fallback instead of raising.
- **Bounded input.** The state is truncated to 32 KiB, as `semantic` bounds its embedding input.
- **`*_opts` block.** Every option lives in `system_one_opts`; the only instance-level field is
  `description`, like `examples` for `semantic`.
- **Debugging headers** mirror `X-AI-Semantic-*`: `X-AI-System-One-Probabilities` and
  `X-AI-System-One-Picked-Instance`.

## Limits

- One System One request per client request adds its latency (bounded by
  `system_one_opts.timeout`, 3 s by default). Decisions are not cached.
- At most 64 instances: a System One choice question takes at most 64 options.
- The System One model sees only the last user message, not the whole conversation, as with
  `semantic`.
