#!/usr/bin/env bash
# Assemble the GitHub Pages site into _site/: static files + the Markdown docs.
# Preview locally: site/build.sh && python3 -m http.server -d _site 8000
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf _site
mkdir -p _site/docs
cp site/*.html site/*.css site/*.js site/*.svg _site/
cp README.md _site/docs/README.md
cp docs/*.md _site/docs/
mkdir -p _site/docs/zh
cp docs/zh/*.md _site/docs/zh/
cp deploy/kubernetes/README.md _site/docs/kubernetes.md
