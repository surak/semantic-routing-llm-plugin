# The System One API

`system_one` talks to a model over the System One API (`POST /v1/systemone`). This page
describes the part of the API the balancer uses, where the API is served, and what has been
tested. Sources are listed at the end.

## What a System One model is

The term comes from TypeSafe AI, which released Jev on 15 September 2026, in limited early
access, as the first System One model, after Daniel Kahneman's fast, intuitive "System 1"
thinking. In TypeSafe's words, "System One models are a class of AI models built to make fast,
structured decisions that software can use directly". A System One model is discriminative, not
generative: for each question it returns a probability distribution over the allowed answers
instead of text. TypeSafe reports latencies of 70 to 500 milliseconds and trains the models for
calibrated probabilities.

A request carries a `state` (a string, JSON object or array) and a map of typed `questions`:

| Type | Meaning | `criteria` |
| --- | --- | --- |
| `noul` | Is a statement true? | optional |
| `choice` | One of several unordered options | object: option → description, up to 255 options |
| `score` | A level on an ordered scale | array of 2 to 10 level descriptions |

The response holds one answer per question. A `choice` answer carries the probability of every
option in `probabilities`, plus the most likely option (`choice`) and a `confidence`, both
derived from the distribution.

TypeSafe's API takes UTF-8 JSON bodies of up to 32 MiB with finite numbers only. By default a
request may use 64k tokens, and the state plus a question 32k tokens; longer inputs need its
long-context mode.

## Where it is served

| Provider | Endpoint | Model |
| --- | --- | --- |
| TypeSafe | `https://api.typesafe.ai/v1/systemone` | `jev-latest` |
| OpenRouter | `https://openrouter.ai/api/v1/systemone` | `typesafe/jev-1.14` |
| Blablador | `https://api.blablador.fz-juelich.de/v1/systemone` | `alias-clef` |

AI gateways such as TrueFoundry forward `/v1/systemone` unchanged. Cloudflare describes its Clef
and Clef-flash decision models (October 2026, open weights under Apache 2.0) as "fully Jev-API
compatible"; on Workers AI they are called through the Workers AI endpoint
`/ai/run/@cf/cloudflare/clef` rather than `/v1/systemone`.

The examples and live tests of this repository use Blablador's `alias-clef`. The Test::Nginx and
end-to-end tests use mocks of the API.

## What `system_one` sends

One `choice` question with the id `instance`. The options are the instance names; each option's
criterion is the instance's `description`. The `state` is the last user message of the request,
read with APISIX's protocol-aware reader (OpenAI Chat, OpenAI Responses, Anthropic Messages,
Bedrock Converse) and cut to 16 KiB at a UTF-8 character boundary, so that it stays valid UTF-8
and well within the default 32k-token limit. A cut inside a character would not be harmless:
Blablador answers such a state with HTTP 500 (checked on 16 October 2026), which would send the
request to the fallback instance.

```http
POST /v1/systemone
Authorization: Bearer <system_one_opts.auth.header>
Content-Type: application/json
```

```json
{
  "model": "jev-latest",
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

`system_one_opts.endpoint` is the URL of the API. A URL without a path, such as
`https://api.typesafe.ai`, gets the path `/v1/systemone`; a URL with a path, such as OpenRouter's,
is used as it is.

The request goes through APISIX's shared AI provider layer, like the embedding request of the
`semantic` algorithm: none of the client's headers or query parameters are forwarded, only
`system_one_opts.auth`.

## What `system_one` reads

```json
{
  "model": "jev-latest",
  "answers": {
    "instance": {
      "choice": "code",
      "confidence": 0.865,
      "probabilities": { "code": 0.91, "default": 0.06, "translate": 0.03 }
    }
  },
  "usage": { "input_tokens": 42, "output_tokens": 1 }
}
```

- `answers.instance.probabilities` ranks the instances, most probable first. Ties keep the
  configured order. An instance missing from the distribution has probability 0, and options
  that are not instances are ignored.
- The probability of every instance must be a number between 0 and 1. Otherwise, or if no
  instance has a positive probability, the request goes to the fallback instance.
- `choice` and `confidence` are not read. Both are derived from the distribution, and
  implementations define `confidence` differently: TypeSafe documents
  `(p_max - 1/n) / (1 - 1/n)` for `n` options, while Blablador returns `p_max`.
- Any other response (a status other than 200, invalid JSON, no `probabilities`) sends the
  request to the fallback instance. The response body is never logged, as it may echo the
  prompt.

## Sources

- TypeSafe: [API reference](https://docs.typesafe.ai/api), [models](https://docs.typesafe.ai/models),
  [System One models](https://docs.typesafe.ai/concepts/system-one)
- [Jev (AI model)](https://en.wikipedia.org/wiki/Jev_(AI_model)), Wikipedia
- OpenRouter: [Jev](https://openrouter.ai/docs/guides/community/jev)
- TrueFoundry: [Jev](https://www.truefoundry.com/docs/ai-gateway/jev)
- Cloudflare: [Clef and Clef-flash](https://blog.cloudflare.com/clef-decision-models/),
  [Clef on Workers AI](https://developers.cloudflare.com/workers-ai/models/clef/)
