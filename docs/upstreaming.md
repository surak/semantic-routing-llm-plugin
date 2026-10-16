# Submitting system_one to Apache APISIX

The change is ready on the branch
[`surak/apisix:feat/ai-proxy-multi-system-one`](https://github.com/surak/apisix/tree/feat/ai-proxy-multi-system-one),
one commit on top of apache/apisix `master`. No issue or pull request has been opened yet.

## Status against the APISIX requirements

| Requirement ([CONTRIBUTING.md](https://github.com/apache/apisix/blob/master/CONTRIBUTING.md), APISIX CI) | Status |
| --- | --- |
| `make lint`: luacheck, `lj-releng`, `reindex` | clean |
| Spell check (codespell 2.1.0), `eclint`, plugin code check | clean |
| Doc lint: markdownlint-cli 0.25.0, autocorrect, Chinese line breaks | clean |
| License headers (license-eye) | 0 invalid |
| Schema fields documented; secrets in `encrypt_fields` | `system_one_opts` and `instances.description` described; `system_one_opts.auth` encrypted |
| Tests in `t/plugin/` | `ai-proxy-multi-system-one.t`: 26 blocks, 100 assertions |
| Existing suites still pass | all `ai-proxy-multi*`, `ai-proxy-semantic*` and `ai-rate-limiting*` suites give the same results as on unmodified `master` (816 tests) |
| English and Chinese docs | `ai-proxy-multi.md` in `docs/en` and `docs/zh` |
| No new plugin, no new dependency | an algorithm of an existing plugin; uses the existing provider transport |
| Commit title in [semantic.yml](https://github.com/apache/apisix/blob/master/.github/workflows/semantic.yml) format | `feat(ai-proxy-multi): add system_one balancer algorithm` |

The `patch-check` job of this repository's CI applies the branch (`patches/`) to the current
apache/apisix `master` and runs those checks on every push. Locally, all `ai-proxy-multi*`,
`ai-proxy-semantic*` and `ai-rate-limiting*` suites were run on the branch and on unmodified
`master`; the 15 assertions that fail in the local harness (Redis, external network, an SSE
fixture) fail identically on both.

## Steps

### 1. Open an issue

CONTRIBUTING.md asks for an issue before a significant change. Open a feature request at
<https://github.com/apache/apisix/issues/new/choose>:

> **Title:** feat: As a user, I want ai-proxy-multi to route each prompt with a System One model,
> so that a plain-language policy picks the LLM instance
>
> **Description**
>
> As a user, I want `ai-proxy-multi` to ask a System One model which instance should answer each
> prompt, so that I can route by a one-sentence description of each instance, with health checks
> and retries.
>
> A System One model, such as TypeSafe's Jev (released September 2026), is a discriminative
> model: it answers typed questions about an input with calibrated probability distributions
> instead of generated text, in tens to hundreds of milliseconds. It is served over the System
> One API (`POST /v1/systemone`) by TypeSafe, OpenRouter and Blablador; Cloudflare describes its
> open-weight Clef decision models as compatible with that API.
>
> **Proposal:** a fourth `balancer.algorithm`, `system_one`, next to `roundrobin`, `chash` and
> `semantic`. Each instance gets a `description`, its routing role in one sentence. For each
> request, the gateway sends the prompt as the `state` of one `choice` question whose options are
> the instance names, with the descriptions as criteria, and ranks the instances by the returned
> probabilities:
>
> ```yaml
> balancer:
>   algorithm: system_one
> system_one_opts:
>   endpoint: https://api.typesafe.ai/v1/systemone
>   model: jev-latest
>   auth: { header: { Authorization: "Bearer ..." } }
>   threshold: 0.3
>   fallback: general
> fallback_strategy: [http_429, http_5xx]
> instances:
>   - name: code
>     description: "Writing, debugging and reviewing code."
>     # provider, auth, options as usual
>   - name: general
>     description: "General questions with no specialist need."
> ```
>
> Compared with `semantic`:
>
> - the policy is one sentence per instance: no example corpus, no embedding model;
> - every instance gets a probability, so `system_one` skips instances that fail active health
>   checks or are rate limited, and on `fallback_strategy` errors retries down the ranking without
>   a second System One request (`semantic` returns upstream failures to the client);
> - it fails open to `system_one_opts.fallback` when the System One request fails or no available
>   instance clears `threshold`.
>
> It follows the conventions of `semantic`: its options live in `system_one_opts`, the request goes
> through the shared provider transport (no client headers forwarded, no upstream body in logs),
> the answer is validated before use, and `X-AI-System-One-*` headers help with debugging.
>
> An implementation with Test::Nginx tests and English and Chinese docs is ready:
> <https://github.com/surak/apisix/tree/feat/ai-proxy-multi-system-one>. It has been tested live
> against 14 models on the Blablador gateway:
> <https://surak.github.io/semantic-routing-llm-plugin/>.
>
> Would you accept it as a pull request?

### 2. Open the pull request

When the maintainers agree, open the PR from the branch, as a draft until CI is green:

```sh
gh pr create --repo apache/apisix --base master \
  --head surak:feat/ai-proxy-multi-system-one \
  --title "feat(ai-proxy-multi): add system_one balancer algorithm" --draft
```

Use this description (the APISIX template):

```markdown
### Description

Adds a `system_one` balancer algorithm to `ai-proxy-multi`. A System One model, such as
TypeSafe's Jev, ranks the instances for each request: the prompt is sent to the System One API
(`POST /v1/systemone`) as the `state` of one `choice` question whose options are the instance
names, each described by the new `instances.description` field. The most probable instance that
is healthy, not rate limited and above `system_one_opts.threshold` is picked. On
`fallback_strategy` errors the request is retried down the ranking without a second System One
request. Failures fail open to `system_one_opts.fallback`.

- `apisix/plugins/ai-proxy/system-one.lua`: the System One client. It sends the request through
  the openai-compatible provider (no client headers forwarded, upstream body never logged), cuts
  the prompt to 16 KiB at a UTF-8 character boundary (the API refuses invalid UTF-8), and
  validates the returned distribution.
- `ai-proxy-multi.lua`: schema checks, `pick_system_one_instance`, ranked retries in
  `retry_on_error`. `fetch_checkers()` is factored out of `pick_target` so that both pickers share
  the health checks.
- `schema.lua`: `system_one` in the algorithm enum, `instances.description`, `system_one_opts`;
  `system_one_opts.auth` is encrypted at rest.
- Tests: `t/plugin/ai-proxy-multi-system-one.t`. Docs: `ai-proxy-multi.md` (en, zh).

#### Which issue(s) this PR fixes:
Fixes #<issue number>

### Checklist

- [x] I have explained the need for this PR and the problem it solves
- [x] I have explained the changes or the new features added to this PR
- [x] I have added tests corresponding to this change
- [x] I have updated the documentation to reflect this change
- [x] I have verified that this change is backward compatible (If not, please discuss on the [APISIX mailing list](https://github.com/apache/apisix/tree/master#community) first)
```

Mark it ready for review when CI is green.

### 3. During review

From the PR template: push new commits to address comments (no `push -f` once the PR is open),
merge `master` instead of rebasing, and use "request review" after changes. Develop on the
branch, then run `contrib/sync_from_apisix.sh` and `contrib/build_docs.py` here so the overlay,
patch and site follow.

## Expected review points

1. **Maturity of the API.** Jev has been in limited early access since September 2026. The API
   is already served by TypeSafe, OpenRouter and Blablador and forwarded by gateways such as
   TrueFoundry; Cloudflare's Clef (October 2026) is described as compatible with it. TypeSafe's
   [API reference](https://docs.typesafe.ai/api) is public.
2. **The name.** `system_one` follows the API's name (`/v1/systemone`, "System One API" at
   OpenRouter). Maintainers may prefer a generic name such as `classifier`; the change is
   mechanical.
3. **`instances.description`.** A generic field name, like `examples` for `semantic`; it could be
   scoped (`system_one_description`) if they want to avoid confusion with a human description.
4. **Latency.** One extra request per client request, bounded by `timeout` (3 s by default); they
   may ask for caching of rankings.
5. **Threshold on retries.** A retry goes to the fallback when the runners-up are below the
   threshold. They may prefer retries to ignore the threshold; that is a one-line change.
6. **The UTF-8-safe cut.** `semantic` cuts its embedding input at a byte offset, which can split a
   character. If asked, the same fix can be offered for `semantic` in a separate PR.

## Licensing

The PR is contributed under the Apache License 2.0. Files in the APISIX tree carry the standard
ASF header with no personal copyright line, as the ASF requires; your authorship is in the Git
history. A pull request is normally accepted under section 5 of the Apache License without a
signed agreement; for a sizeable contribution maintainers can ask for an
[ICLA](https://www.apache.org/licenses/contributor-agreements.html).
