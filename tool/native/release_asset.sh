#!/usr/bin/env bash
# Builds one prebuilt release asset, named as in native/prebuilt_assets.json
# (the frozen contract of ADR 0008), and stages it at
# .native-cache/release/<asset>, plus <asset>.buildinfo (toolchain and runner
# image, for the release notes). Prints the asset's sha256 as the last line.
#
# Release settings on top of build.sh's (offline, --system deps, ReleaseFast,
# verified tarballs freshly extracted, empty Zig caches):
#   - `release_zig_args` from the manifest (-Dstrip=true: no DWARF, so no temp
#     or checkout paths are embedded and the output is bit-identical across
#     runs and machines, and ~5x smaller);
#   - the per-asset -Dcpu from the manifest (armv7: NEON + VFPv3-D16);
#   - Android: ANDROID_NDK_HOME set explicitly to the pinned NDK, freshly
#     extracted, never the "latest NDK under ANDROID_HOME" upstream would
#     otherwise pick;
#   - Apple: the pinned Xcode (DEVELOPER_DIR, checked against the pinned
#     version), because on a macOS host upstream links dylibs with its `ld`.
#
# Usage: tool/native/release_asset.sh <asset>
set -euo pipefail

asset="${1:?usage: release_asset.sh <asset>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"

target="$(asset_field "$root" "$asset" zig_target)"
cpu="$(asset_field "$root" "$asset" cpu)"
builder="$(asset_field "$root" "$asset" builder)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
toolchain="zig $(zig version)"

case "$builder" in
  linux)
    [[ "$(uname -s)" == Linux ]] || { echo "error: $asset is built on Linux (native/prebuilt_assets.json)" >&2; exit 1; }
    ;;
  macos)
    [[ "$(uname -s)" == Darwin ]] || { echo "error: $asset needs a macOS host with Xcode (Apple ld, iOS SDK)" >&2; exit 1; }
    xcode_path="$(jq_raw .xcode.path "$root/native/toolchain.json")"
    xcode_version="$(jq_raw .xcode.version "$root/native/toolchain.json")"
    export DEVELOPER_DIR="${DEVELOPER_DIR:-$xcode_path}"
    [[ -d "$DEVELOPER_DIR" ]] || { echo "error: Xcode not found at $DEVELOPER_DIR; install Xcode $xcode_version or bump native/toolchain.json" >&2; exit 1; }
    got="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
    [[ "$got" == "$xcode_version" ]] || { echo "error: $DEVELOPER_DIR is Xcode $got; release assets need the pinned $xcode_version" >&2; exit 1; }
    toolchain="$toolchain, $(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
    ;;
  *) echo "error: $asset: unknown builder '$builder'" >&2; exit 1 ;;
esac

if [[ "$target" == *-android* ]]; then
  ANDROID_NDK_HOME="$("$root/tool/native/fetch_ndk.sh" "$work/ndk")"
  export ANDROID_NDK_HOME
  toolchain="$toolchain, NDK $(jq_raw '.android_ndk | "\(.release) (\(.revision))"' "$root/native/toolchain.json")"
fi

args=()
while IFS= read -r arg; do args+=("$arg"); done < <(jq_raw '.release_zig_args[]' "$root/native/prebuilt_assets.json")
if [[ -n "$cpu" ]]; then args+=("-Dcpu=$cpu"); fi

"$root/tool/native/build.sh" "$target" ${args[@]+"${args[@]}"}

lib="$(built_lib "$root/.native-cache/out/$target" "$target")"
[[ -f "$lib" ]] || { echo "error: $target: expected $lib was not produced" >&2; exit 1; }

release="$root/.native-cache/release"
mkdir -p "$release"
# -L: the .so and .dylib are symlink chains to the versioned file.
cp -L "$lib" "$release/$asset.part"
mv "$release/$asset.part" "$release/$asset"
# ImageOS/ImageVersion are set on GitHub-hosted runners only.
printf '%s\t%s\t%s\t%s\n' "$asset" "$target" "${ImageOS:-local} ${ImageVersion:-}" "$toolchain" \
  >"$release/$asset.buildinfo"
if [[ "$builder" == macos ]]; then
  # Apple's own view of the binary, next to check_binary.dart's.
  xcrun vtool -show-build "$release/$asset" >&2
  otool -L "$release/$asset" >&2
fi
echo "staged $asset ($target) -> $release/$asset" >&2
sha256_of "$release/$asset"
