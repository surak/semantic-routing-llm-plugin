#!/usr/bin/env bash
# Refresh overlay/ and patches/ from the feature branch of the APISIX fork,
# where the system_one algorithm is developed.
#
#   contrib/sync_from_apisix.sh /path/to/apisix [branch]
#
# The branch must be based on apache/apisix master. Development happens there;
# this repository carries:
#   patches/  the branch as a patch series (`git am` onto apache/apisix)
#   overlay/  the changed Lua modules, to run the feature on a released APISIX
#             (3.19.x) by putting overlay/ first on extra_lua_path
set -euo pipefail
APISIX=${1:?usage: $0 /path/to/apisix [branch]}
BRANCH=${2:-feat/ai-proxy-multi-system-one}
cd "$(dirname "$0")/.."
ROOT=$PWD

base=$(git -C "$APISIX" merge-base master "$BRANCH")
mkdir -p patches overlay/apisix/plugins/ai-proxy
find patches -name '*.patch' -delete
git -C "$APISIX" format-patch -q --no-signature -o "$ROOT/patches" "$base..$BRANCH"

for f in apisix/plugins/ai-proxy-multi.lua \
         apisix/plugins/ai-proxy/schema.lua \
         apisix/plugins/ai-proxy/system-one.lua; do
  git -C "$APISIX" show "$BRANCH:$f" > "overlay/$f"
done
echo "base: $(git -C "$APISIX" log -1 --format='%h %s' "$base")"
ls patches overlay/apisix/plugins overlay/apisix/plugins/ai-proxy
