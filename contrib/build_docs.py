#!/usr/bin/env python3
"""Regenerate docs/system-one.md and docs/zh/system-one.md from the APISIX docs
on the feature branch, so this site documents exactly what the PR adds.

  python3 contrib/build_docs.py /path/to/apisix [branch]
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BRANCH_URL = "https://github.com/surak/apisix/tree/feat/ai-proxy-multi-system-one"

TEXT = {
    "en": {
        "title": "system_one algorithm",
        "h1": "# The `system_one` algorithm of ai-proxy-multi",
        "intro": "This page documents the `system_one` balancer algorithm proposed for the "
                 "[`ai-proxy-multi`](https://apisix.apache.org/docs/apisix/plugins/ai-proxy-multi/) "
                 "Plugin of Apache APISIX. It is generated from the APISIX docs on the "
                 f"[feature branch]({BRANCH_URL}), so it matches what the pull request adds. "
                 "Attributes not listed here are those of `ai-proxy-multi`.",
        "attrs": "## Attributes",
        "section": "### Route with a System One Model",
        "example": "## Example: Route with a System One Model",
        "out": "docs/system-one.md",
    },
    "zh": {
        "title": "system_one 算法",
        "h1": "# ai-proxy-multi 的 `system_one` 算法",
        "intro": "本页介绍为 Apache APISIX "
                 "[`ai-proxy-multi`](https://apisix.apache.org/zh/docs/apisix/plugins/ai-proxy-multi/) "
                 "插件提议的 `system_one` 负载均衡算法。它由"
                 f"[功能分支]({BRANCH_URL})上的 APISIX 文档生成，因此与拉取请求所添加的内容一致。"
                 "此处未列出的属性与 `ai-proxy-multi` 相同。",
        "attrs": "## 属性",
        "section": "### 使用 System One 模型路由",
        "example": "## 示例：使用 System One 模型路由",
        "out": "docs/zh/system-one.md",
    },
}


def build(apisix, branch, lang):
    t = TEXT[lang]
    src = subprocess.run(
        ["git", "-C", apisix, "show", f"{branch}:docs/{lang}/latest/plugins/ai-proxy-multi.md"],
        check=True, capture_output=True, text=True).stdout
    lines = src.splitlines()
    algo = next(i for i, l in enumerate(lines) if l.startswith("| balancer.algorithm"))
    head = algo
    while not lines[head - 1].startswith("| --") and not lines[head - 1].startswith("|--"):
        head -= 1
    header, sep = lines[head - 2], lines[head - 1]
    rows = [l for l in lines
            if l.startswith("| instances.description") or l.startswith("| system_one_opts")]
    rest = src[src.index(t["section"]):].split("\n", 1)[1]
    # sub-headings move up one level, as the section becomes a top-level example
    rest = rest.replace("\n#### ", "\n### ")
    out = "\n".join([
        "---", f"title: {t['title']}", "---", "", t["h1"], "", t["intro"], "",
        t["attrs"], "", header, sep, lines[algo], *rows, "", t["example"], "", rest.strip(), "",
    ])
    (ROOT / t["out"]).write_text(out)
    print("wrote", t["out"])


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    apisix = sys.argv[1]
    branch = sys.argv[2] if len(sys.argv) > 2 else "feat/ai-proxy-multi-system-one"
    for lang in TEXT:
        build(apisix, branch, lang)


if __name__ == "__main__":
    main()
