#!/usr/bin/env python3
"""Copy ai-decision-router into an Apache APISIX checkout, ready for a pull request.

  python3 contrib/prepare_apisix_pr.py /path/to/apisix

What it does (the same set of files every new AI plugin PR touches):
  apisix/plugins/ai-decision-router.lua        plugin, ASF license header
  t/plugin/ai-decision-router.t                Test::Nginx tests, ASF license header
  docs/en/latest/plugins/ai-decision-router.md English docs, ASF license comment
  docs/zh/latest/plugins/ai-decision-router.md Chinese docs, ASF license comment
  apisix/cli/config.lua                        default plugin list (after ai-proxy)
  conf/config.yaml.example                     plugin list with priority comment
  t/admin/plugins.t                            expected plugin list (priority order)
  docs/{en,zh}/latest/config.json              docs sidebar (AI category)

Files contributed to the ASF carry the ASF header instead of a personal copyright
line; see https://www.apache.org/legal/src-headers.html. Running it twice is safe.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAME = "ai-decision-router"
PRIORITY = 1039

ASF = """Licensed to the Apache Software Foundation (ASF) under one or more
contributor license agreements.  See the NOTICE file distributed with
this work for additional information regarding copyright ownership.
The ASF licenses this file to You under the Apache License, Version 2.0
(the "License"); you may not use this file except in compliance with
the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License."""


def comment_block(prefix):
    lines = [prefix] + [(prefix + " " + l).rstrip() for l in ASF.splitlines()] + [prefix]
    return "\n".join(lines) + "\n"


def swap_header(text, prefix):
    """Replace the leading personal license comment with the ASF one."""
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines) and lines[i].startswith(prefix):
        i += 1
    return comment_block(prefix) + "".join(lines[i:])


def doc_with_header(text):
    """Docs: ASF header as an HTML comment right after the front matter."""
    m = re.match(r"(---\n.*?\n---\n)", text, re.S)
    header = "\n<!--\n" + comment_block("#") + "-->\n"
    return m.group(1) + header + text[m.end():]


def write(apisix, rel, content):
    path = apisix / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    print("wrote   ", rel)


def insert_after(apisix, rel, anchor, new_line):
    path = apisix / rel
    text = path.read_text()
    if new_line in text:
        print("ok      ", rel)
        return
    if anchor not in text:
        sys.exit(f"anchor {anchor!r} not found in {rel}")
    path.write_text(text.replace(anchor, anchor + new_line, 1))
    print("patched ", rel)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    apisix = pathlib.Path(sys.argv[1]).resolve()
    if not (apisix / "apisix/plugins/ai-proxy.lua").exists():
        sys.exit(f"{apisix} is not an APISIX checkout")

    lua = (ROOT / "apisix/plugins" / f"{NAME}.lua").read_text()
    write(apisix, f"apisix/plugins/{NAME}.lua", swap_header(lua, "--"))
    test = (ROOT / "t/plugin" / f"{NAME}.t").read_text()
    write(apisix, f"t/plugin/{NAME}.t", swap_header(test, "#"))
    write(apisix, f"docs/en/latest/plugins/{NAME}.md",
          doc_with_header((ROOT / "docs" / f"{NAME}.md").read_text()))
    write(apisix, f"docs/zh/latest/plugins/{NAME}.md",
          doc_with_header((ROOT / "docs/zh" / f"{NAME}.md").read_text()))

    insert_after(apisix, "apisix/cli/config.lua",
                 '    "ai-proxy",\n', f'    "{NAME}",\n')
    insert_after(apisix, "conf/config.yaml.example",
                 "  - ai-proxy                       # priority: 1040\n",
                 f"  - {NAME:<30} # priority: {PRIORITY}\n")
    insert_after(apisix, "t/admin/plugins.t", "\nai-proxy\n", f"{NAME}\n")
    for lang in ("en", "zh"):
        insert_after(apisix, f"docs/{lang}/latest/config.json",
                     '            "plugins/ai-proxy-multi",\n',
                     f'            "plugins/{NAME}",\n')


if __name__ == "__main__":
    main()
