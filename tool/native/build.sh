#!/usr/bin/env bash
# Builds libghostty-vt from the verified upstream tarballs for one Zig target,
# offline (--system deps dir). Every run verifies the tarballs and extracts
# them into a fresh temp dir, with an empty Zig global cache, and Zig's local
# cache inside that fresh tree: nothing from an earlier build (or a restored
# cache) can leak in.
#
# Usage: tool/native/build.sh <zig-target> [extra zig build args...]
#   e.g. tool/native/build.sh x86_64-linux-gnu
#   A -Dcpu=... in the extra args replaces the default -Dcpu=baseline.
# Output: .native-cache/out/<zig-target>/{lib,include,...}
set -euo pipefail

target="${1:?usage: build.sh <zig-target> [args...]}"; shift
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"
cache="$root/.native-cache"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
src="$(extract_upstream_src "$root" "$work/src")"
deps="$src-deps"
zig_cache="$work/zig-cache"
mkdir -p "$zig_cache"

out="$cache/out/$target"
rm -rf "$out"

# Run without network when the platform allows it, to prove the build is hermetic.
# Linux only; unprivileged user namespaces may still be disabled (Ubuntu 24.04+).
run=()
if [[ "$(uname -s)" == Linux ]] && unshare -rn true 2>/dev/null; then run=(unshare -rn); fi

# -Dcpu defaults to baseline (portable). A caller that passes its own -Dcpu
# replaces it: zig turns a repeated -D option into a list and rejects it.
cpu=(-Dcpu=baseline)
for arg in "$@"; do
  if [[ "$arg" == -Dcpu=* ]]; then cpu=(); fi
done

(cd "$src" && ZIG_GLOBAL_CACHE_DIR="$(native_path "$zig_cache")" ${run[@]+"${run[@]}"} zig build \
  --prefix "$(native_path "$out")" \
  --system "$(native_path "$deps")" \
  -Dtarget="$target" \
  -Doptimize=ReleaseFast \
  ${cpu[@]+"${cpu[@]}"} \
  "$@")
echo "built $target -> $out"
