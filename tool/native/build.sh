#!/usr/bin/env bash
# Builds libghostty-vt from the verified upstream tarballs for one Zig target,
# offline (--system deps dir, fresh empty Zig cache).
#
# Usage: tool/native/build.sh <zig-target> [extra zig build args...]
#   e.g. tool/native/build.sh x86_64-linux-gnu
# Output: .native-cache/out/<zig-target>/{lib,include,...}
set -euo pipefail

target="${1:?usage: build.sh <zig-target> [args...]}"; shift
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="$(jq -r .version "$root/native/upstream.json")"
cache="$root/.native-cache"

"$root/tool/native/fetch_upstream.sh" >/dev/null

src="$cache/src/libghostty-vt-$version"
deps="$cache/src/libghostty-vt-$version-deps"
if [[ ! -f "$src/LIB_VERSION" ]]; then
  rm -rf "$cache/src" && mkdir -p "$cache/src"
  tar -xzf "$cache/libghostty-vt-$version.tar.gz" -C "$cache/src"
  tar -xzf "$cache/libghostty-vt-$version-deps.tar.gz" -C "$cache/src"
fi

out="$cache/out/$target"
zig_cache="$(mktemp -d)"
trap 'rm -rf "$zig_cache"' EXIT
rm -rf "$out"

# Run without network when the platform allows it, to prove the build is hermetic.
run=()
if unshare -rn true 2>/dev/null; then run=(unshare -rn); fi

(cd "$src" && ZIG_GLOBAL_CACHE_DIR="$zig_cache" "${run[@]}" zig build \
  --prefix "$out" \
  --system "$deps" \
  -Dtarget="$target" \
  -Doptimize=ReleaseFast \
  -Dcpu=baseline \
  "$@")
echo "built $target -> $out"
