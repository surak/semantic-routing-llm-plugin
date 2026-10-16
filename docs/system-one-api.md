# The System One API

`system_one` talks to a *System One model* over the System One API. This page describes the
part of the API the balancer uses and the implementations it has been tested with.

## What a System One model is

The term comes from TypeSafe AI, which released [Jev](https://en.wikipedia.org/wiki/Jev_(AI_model))
on 15 September 2026 as "the first System One model", after Daniel Kahneman's fast, intuitive
"System 1" thinking. A System One model is discriminative, not generative: it returns typed
values with probability estimates instead of text. TypeSafe reports latencies of 70 to 500
milliseconds.

Requests carry a `state` (a string, JSON object or array) and up to 64 typed `questions`. There
are three question types:

| Type | Meaning | `criteria` |
| --- | --- | --- |
| `noul` | yes/no | none |
| `choice` | one of several unordered options | object: option → description |
| `score` | a level on an ordered scale | array of level descriptions |

The response holds one probability distribution per question. Derived values such as the most
likely `choice` and a `confidence` are computed from the distribution by fixed formulas.

## Implementations

| Implementation | Endpoint | Model |
| --- | --- | --- |
| TypeSafe Jev | TypeSafe API (limited early access since September 2026) | see TypeSafe's documentation |
| Cloudflare Clef, Clef-flash | Cloudflare (see Cloudflare's documentation) | see Cloudflare's documentation |
| Blablador | `https://api.blablador.fz-juelich.de/v1/systemone` | `alias-clef` |

The examples and live tests in this repository use Blablador's `alias-clef`.

## What `system_one` sends

One `choice` question with the id `instance`. The options are the instance names; each option's
criterion is the instance's `description`. The `state` is the last user message of the request,
read with APISIX's protocol-aware reader (OpenAI Chat, OpenAI Responses, Anthropic Messages,
Bedrock Converse), truncated to 32 KiB.

```http
POST /v1/systemone
Authorization: Bearer <system_one_opts.auth.header>
Content-Type: application/json
```

```json
{
  "model": "alias-clef",
  "state": "help me debug this python code",
  "questions": {
    "instance": {
      "type": "choice",
      "instructions": "Choose the option best suited to answer this request. Prefer the option whose criteria match the main task; options are not ordered by quality.",
      "criteria": {
        "code": "Writing, debugging and reviewing code.",
        "translate": "Translating and summarizing text.",
        "default": "General questions and conversation with no specialist need."
      }
    }
  }
}
```

The request goes through APISIX's shared AI provider layer, like the embedding request of the
`semantic` algorithm: none of the client's headers or query parameters are forwarded, only
`system_one_opts.auth`.

## What `system_one` reads

```json
{
  "model": "alias-clef",
  "answers": {
    "instance": {
      "choice": "code",
      "confidence": 0.91,
      "probabilities": { "code": 0.91, "default": 0.06, "translate": 0.03 }
    }
  },
  "usage": { "input_tokens": 42, "output_tokens": 1 }
}
```

- `answers.instance.probabilities` ranks the instances, most probable first. Ties keep the
  configured order. Options that are not instances are ignored; instances the model omits get 0.
- Every probability must be a finite number between 0 and 1, or the response is rejected and
  the request goes to the fallback.
- A response without `probabilities` but with a `choice` ranks that choice first, with
  `confidence` as its probability.
- Any other response (non-200 status, invalid JSON, no answer for `instance`) sends the request
  to the fallback. The response body is never logged, as it may echo the prompt.
