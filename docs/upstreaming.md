# Submitting ai-decision-router to Apache APISIX

How to propose this plugin for inclusion in [apache/apisix](https://github.com/apache/apisix),
following its [CONTRIBUTING.md](https://github.com/apache/apisix/blob/master/CONTRIBUTING.md)
and the way recent AI plugins were merged (`ai-lakera-guard` #13570, `ai-cache` #13578,
the `semantic` balancer of `ai-proxy-multi` #13676).

## Status of this repository against the APISIX requirements

| Requirement | Where | Status |
| --- | --- | --- |
| Lua code style, `luacheck` with APISIX's `.luacheckrc` | `apisix/plugins/ai-decision-router.lua` | 0 warnings |
| Schema: a `description` per field, required fields, URL pattern, `encrypt_fields` for secrets | plugin schema | done |
| No vendor-specific defaults | `decision.endpoint` / `decision.model` are required | done |
| Reuse of shared AI helpers | `ai-protocols` (prompt extraction), `ai-protocols.binding` (`fail_mode`) | done |
| Test::Nginx tests in `t/plugin/` | `t/plugin/ai-decision-router.t`, 21 blocks | passing on APISIX 3.19.0 and master |
| `t/admin/plugins.t` (plugin list in priority order) | patched by the prepare script | passing on master |
| `reindex` test style | test file | no changes needed |
| English docs, current plugin-doc format | `docs/ai-decision-router.md` | markdownlint passes |
| Chinese docs | `docs/zh/ai-decision-router.md` | autocorrect passes |
| ASF license headers | added by the prepare script | license-eye: 0 invalid |
| Registration in `apisix/cli/config.lua`, `conf/config.yaml.example`, docs sidebars | prepare script | done |

CI (`apisix-pr` and `test-nginx` jobs) re-checks all of this on every push.

## Steps

### 1. Open an issue first

CONTRIBUTING.md asks for an issue before any significant change. Open one at
<https://github.com/apache/apisix/issues/new/choose> ("Feature request"). Draft:

> **Title:** feat: decision-model based LLM routing (ai-decision-router)
>
> **Description**
>
> `ai-proxy-multi` can route by weight, consistent hashing, or embedding similarity to
> example prompts (`semantic`). I'd like to propose routing by a *decision model*: a small
> classifier LLM that reads the prompt and plain-text routing roles of each candidate
> model, and returns a choice with calibrated per-candidate probabilities (Clef-compatible
> `/v1/systemone` API).
>
> Compared with `semantic`, the routing policy is a readable description per model rather
> than an example corpus, no embedding model is needed, and a confidence threshold allows
> falling back when the decision is unsure.
>
> I have a working implementation as a separate plugin, `ai-decision-router` (priority
> 1039, runs after `ai-proxy`/`ai-proxy-multi`): it rewrites the request `model` for
> `ai-proxy`, or overrides the picked instance of `ai-proxy-multi`. It falls back to a
> configured candidate on decision errors, timeouts or low confidence, and never fails a
> request. Tests (Test::Nginx), English and Chinese docs are ready:
> <https://github.com/surak/semantic-routing-llm-plugin>
>
> **Question for maintainers:** would you prefer this as
> (a) a standalone plugin, as implemented, or
> (b) a new `balancer.algorithm` of `ai-proxy-multi` (e.g. `decision`), next to `semantic`?

Wait for an answer to the question before opening the PR (see "Expected review points").

### 2. Create the pull request branch

```sh
gh repo fork apache/apisix --clone --remote
cd apisix
git checkout -b feat/ai-decision-router
python3 /path/to/semantic-routing-llm-plugin/contrib/prepare_apisix_pr.py .
git add -A
git commit -m "feat: add ai-decision-router plugin"
git push -u origin feat/ai-decision-router
```

The commit goes out under your own name, with no extra trailers. The PR title must start
with a type from APISIX's
[semantic.yml](https://github.com/apache/apisix/blob/master/.github/workflows/semantic.yml),
e.g. `feat: add ai-decision-router plugin`.

### 3. Open the PR as a draft

Open it against `master`, mark it as a draft until CI is green, and fill in the template:

```markdown
### Description

Adds `ai-decision-router`, a plugin that routes each LLM request to the best-suited model
as chosen by a decision model (Clef-compatible `/v1/systemone` API).

- Runs in `access` at priority 1039, after `ai-proxy-multi` (1041) and `ai-proxy` (1040).
- Extracts the prompt with `ai-protocols`; sends one `choice` question whose options are
  the configured candidates and their routing roles.
- With `ai-proxy`, rewrites the request `model`; with `ai-proxy-multi`, overrides the
  picked instance; with a plain upstream, rewrites the forwarded body.
- Advisory: decision errors, timeouts, unknown choices and confidence below
  `min_confidence` route to `fallback`, reported in `X-AI-Routing-Fallback`.
- `trigger_models` limits routing to e.g. `"model": "auto"`; explicit models pass through.
- `decision.auth.header` is in `encrypt_fields`; `fail_mode` follows the shared binding helper.

#### Which issue(s) this PR fixes:
Fixes #<issue number>

### Checklist

- [x] I have explained the need for this PR and the problem it solves
- [x] I have explained the changes or the new features added to this PR
- [x] I have added tests corresponding to this change
- [x] I have updated the documentation to reflect this change
- [x] I have verified that this change is backward compatible
```

### 4. During review

From the PR template: push new commits to address comments (no `push -f`), merge
`master` instead of rebasing, and use "request review" after changes. Keep this repository
in sync: make changes here, re-run `prepare_apisix_pr.py`, commit in the APISIX branch.

## Expected review points

1. **Plugin or balancer algorithm.** Maintainers added prompt-based routing as a
   `semantic` algorithm *inside* `ai-proxy-multi`. They may ask for `decision` as another
   algorithm there. That would remove the plugin's main weakness (it overrides
   `ai-proxy-multi`'s `ctx.picked_ai_instance` from outside, and retries after a failure
   use the balancer, not the decision model) and get health checks for free. Porting means
   moving `decide()` into `apisix/plugins/ai-proxy/` and calling it from
   `pick_ai_instance`, as `pick_semantic_instance` does.
2. **Clef API as a dependency.** The decision API is not an industry standard yet. Expect a
   question about which services implement it; be ready to name them and to describe the
   request/response format in the docs.
3. **Internal context fields.** `ctx.plugins`, `ctx.picked_ai_instance(_name)` and the
   cached body table are internal. Reviewers may prefer a hook in `ai-proxy-multi`.
4. **Latency.** Every routed request waits for one decision call. Reviewers may ask for a
   cache of decisions (e.g. an LRU keyed by prompt hash) or for a lower default timeout.
5. **Ingress Controller tab.** Newer plugin docs often have a third example tab for the
   APISIX Ingress Controller. Add it if asked.
6. **Metrics.** The decision call's token usage and latency are not exported to
   Prometheus yet.

## Licensing

The PR is contributed under the Apache License 2.0, the same license as this repository.
The prepare script replaces the personal copyright header with the standard ASF header, as
the ASF requires for files in its repositories; your authorship stays in the Git history.
A pull request is normally accepted under the license grant in section 5 of the Apache
License, without a signed agreement. For a sizeable piece of code written outside the
project, maintainers can ask for an Individual Contributor License Agreement (ICLA); it is
a short form at <https://www.apache.org/licenses/contributor-agreements.html>.
