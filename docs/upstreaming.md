# Submitting system_one to Apache APISIX

The change is ready on the branch
[`surak/apisix:feat/ai-proxy-multi-system-one`](https://github.com/surak/apisix/tree/feat/ai-proxy-multi-system-one),
one commit on top of apache/apisix `master`. No issue or pull request has been opened yet.

## Status against the APISIX requirements

| Requirement ([CONTRIBUTING.md](https://github.com/apache/apisix/blob/master/CONTRIBUTING.md)) | Status |
| --- | --- |
| Lua code style, `luacheck` with APISIX's `.luacheckrc` | 0 warnings |
| Every schema field has a `description`; secrets in `encrypt_fields` | done |
| Tests in `t/plugin/`, `reindex`-clean | `ai-proxy-multi-system-one.t`, 19 blocks, 71 assertions |
| Existing suites still pass | semantic, retry, balancer and health-check suites of `ai-proxy-multi` pass; the four suites that fail in the local harness fail identically on unmodified `master` |
| English and Chinese docs | `ai-proxy-multi.md` in `docs/en` and `docs/zh`; markdownlint and autocorrect pass |
| ASF license headers | license-eye: 0 invalid |
| No new plugin, no new dependency | an algorithm of an existing plugin; uses the existing provider transport |
| Commit title in [semantic.yml](https://github.com/apache/apisix/blob/master/.github/workflows/semantic.yml) format | `feat(ai-proxy-multi): add system_one balancer algorithm` |

The `patch-check` job of this repository's CI re-applies the branch (`patches/`) to the current
apache/apisix `master` and runs those checks on every push.

## Steps

### 1. Open an issue

CONTRIBUTING.md asks for an issue before a significant change. Open a feature request at
<https://github.com/apache/apisix/issues/new/choose>:

> **Title:** feat(ai-proxy-multi): route by a System One model (`system_one` algorithm)
>
> **Description**
>
> `ai-proxy-multi` can pick an instance by weight, consistent hash, or embedding similarity to
> example prompts (`semantic`). I'd like to propose a fourth algorithm, `system_one`, that asks
> a *System One model* which instance should answer the prompt.
>
> System One models (TypeSafe Jev, Cloudflare Clef, Blablador's `alias-clef`) are
> discriminative: given a `state` and typed questions they return probability distributions
> instead of text, in tens to hundreds of milliseconds. `system_one` sends the prompt as the
> state and one `choice` question whose options are the instance names, each described by a new
> `instances.description` field (its routing role in plain language).
>
> Compared with `semantic`:
>
> - the policy is one readable sentence per instance; no example corpus or embedding model;
> - every instance gets a probability, so `system_one` skips unhealthy (active health checks)
>   and rate-limited instances, and on `fallback_strategy` errors retries down the ranking
>   without asking the model again. `semantic` returns upstream failures to the client;
> - it fails open to `system_one_opts.fallback` when the model is unreachable or unsure
>   (`threshold`).
>
> It follows the `semantic` conventions: options in `system_one_opts`, the request goes through
> the shared provider transport (no client headers forwarded, no upstream body in logs),
> defensive parsing, `X-AI-System-One-*` debugging headers.
>
> An implementation with Test::Nginx tests and English/Chinese docs is ready:
> <https://github.com/surak/apisix/tree/feat/ai-proxy-multi-system-one>. Tested live against
> 14 models on the Blablador gateway; details and results at
> <https://surak.github.io/semantic-routing-llm-plugin/>.
>
> Would you accept this as a PR?

### 2. Open the pull request

When the maintainers agree, open the PR from the branch:

```sh
gh pr create --repo apache/apisix --base master \
  --head surak:feat/ai-proxy-multi-system-one \
  --title "feat(ai-proxy-multi): add system_one balancer algorithm" --draft
```

Use this description (the APISIX template):

```markdown
### Description

Adds a `system_one` balancer algorithm to `ai-proxy-multi`. A System One model (e.g. TypeSafe
Jev, Cloudflare Clef) ranks the instances for each request: the prompt is sent as the `state`
of one `choice` question whose options are the instance names, each described by the new
`instances.description` field. The most probable instance that is healthy, not rate limited and
above `system_one_opts.threshold` is picked; on `fallback_strategy` errors the request is retried
down the ranking without a second System One request. Failures fail open to
`system_one_opts.fallback`.

- `apisix/plugins/ai-proxy/system-one.lua`: request building, transport via the
  openai-compatible provider, ranking with validation of the returned distribution.
- `ai-proxy-multi.lua`: schema checks, `pick_system_one_instance`, ranked retries;
  `fetch_checkers()` factored out of `pick_target` so both pickers share the health checks.
- Tests: `t/plugin/ai-proxy-multi-system-one.t`. Docs: `ai-proxy-multi.md` (en, zh).

#### Which issue(s) this PR fixes:
Fixes #<issue number>

### Checklist

- [x] I have explained the need for this PR and the problem it solves
- [x] I have explained the changes or the new features added to this PR
- [x] I have added tests corresponding to this change
- [x] I have updated the documentation to reflect this change
- [x] I have verified that this change is backward compatible (If not, please discuss on the
      APISIX mailing list first)
```

Mark it ready for review when CI is green.

### 3. During review

From the PR template: push new commits to address comments (no `push -f` once the PR is open),
merge `master` instead of rebasing, and use "request review" after changes. Develop on the
branch, then run `contrib/sync_from_apisix.sh` and `contrib/build_docs.py` here so the overlay,
patch and site follow.

## Expected review points

1. **Maturity of the API.** Jev has been in limited early access since September 2026. Point to
   the three implementations, and to TypeSafe's API documentation if it is public.
2. **The name.** `system_one` follows the API's name; maintainers may prefer a generic name such
   as `classifier`. The change is mechanical.
3. **`instances.description`.** A generic field name; it could be scoped
   (`system_one_description`) if they want to avoid confusion with a human description.
4. **Latency.** One extra request per client request; they may ask for caching of rankings.
5. **Threshold on retries.** The current rule sends a retry to the fallback when the runners-up
   are below the threshold. They may prefer retries to ignore the threshold.

## Licensing

The PR is contributed under the Apache License 2.0. Files in the APISIX tree carry the standard
ASF header with no personal copyright line, as the ASF requires; your authorship is in the Git
history. A pull request is normally accepted under section 5 of the Apache License without a
signed agreement; for a sizeable contribution maintainers can ask for an
[ICLA](https://www.apache.org/licenses/contributor-agreements.html).
