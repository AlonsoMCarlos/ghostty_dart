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
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"
version="$(jq_raw .version "$root/native/upstream.json")"
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
# Linux only; unprivileged user namespaces may still be disabled (Ubuntu 24.04+).
run=()
if [[ "$(uname -s)" == Linux ]] && unshare -rn true 2>/dev/null; then run=(unshare -rn); fi

(cd "$src" && ZIG_GLOBAL_CACHE_DIR="$(native_path "$zig_cache")" ${run[@]+"${run[@]}"} zig build \
  --prefix "$(native_path "$out")" \
  --system "$(native_path "$deps")" \
  -Dtarget="$target" \
  -Doptimize=ReleaseFast \
  -Dcpu=baseline \
  "$@")
echo "built $target -> $out"
