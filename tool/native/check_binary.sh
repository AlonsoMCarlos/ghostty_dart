#!/usr/bin/env bash
# Checks prebuilt binaries: format, architecture, exported API, dependencies
# and platform floors (tool/native/src/binary_check.dart). The expected API
# comes from the minisign- and sha256-verified upstream headers, freshly
# extracted, never from a binary under test; the floors come from
# native/prebuilt_assets.json.
#
# Usage:
#   check_binary.sh <asset> [file]   one asset (file default: .native-cache/release/<asset>)
#   check_binary.sh --dist <dir>     every asset of the manifest, as <dir>/<asset>
#   check_binary.sh --host           the native:host build in .native-cache/host/,
#                                    checked as this machine's release asset
#
# Uses `dart` from PATH. Without one (the release `verify` job installs no
# Flutter), Linux x64 fetches the pinned Dart SDK (fetch_dart_sdk.sh).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"
manifest="$root/native/prebuilt_assets.json"

glibc_floor="$(jq_raw .floors.glibc "$manifest")"
macos_floor="$(jq_raw .floors.macos "$manifest")"
ios_floor="$(jq_raw .floors.ios "$manifest")"

pairs=()
case "${1:?usage: check_binary.sh <asset> [file] | --dist <dir> | --host}" in
  --dist)
    dir="${2:?usage: check_binary.sh --dist <dir>}"
    while IFS= read -r asset; do pairs+=("$asset" "$dir/$asset"); done < <(jq_raw '.assets | keys[]' "$manifest")
    ;;
  --host)
    asset="$(host_asset)"
    pairs=("$asset" "$root/.native-cache/host/$(bundled_name "$asset")")
    # native:host builds the plain `<arch>-linux-gnu` target, whose glibc
    # floor is Zig 0.17.1's default (2.31, lib/std/Target.zig), not the
    # release's pinned 2.28.
    glibc_floor=2.31
    ;;
  *)
    asset="$1"
    asset_field "$root" "$asset" zig_target >/dev/null # rejects unknown names
    pairs=("$asset" "${2:-$root/.native-cache/release/$asset}")
    ;;
esac

for ((i = 1; i < ${#pairs[@]}; i += 2)); do
  [[ -f "${pairs[i]}" ]] || { echo "error: ${pairs[i]} not found (build it with: mise run native:release-asset ${pairs[i - 1]})" >&2; exit 1; }
  pairs[i]="$(native_path "${pairs[i]}")"
done

work="$(build_work_dir "$root")"
trap 'rm -rf "$work"' EXIT
src="$(extract_upstream_src "$root" "$work/src")"

if ! command -v dart >/dev/null 2>&1; then
  [[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] || { echo "error: dart not on PATH" >&2; exit 1; }
  PATH="$("$root/tool/native/fetch_dart_sdk.sh" linux-x64 "$work/dart"):$PATH"
fi

# `dart <file>` (not `dart run`): the checker imports only dart: libraries and
# relative files, so it needs no package resolution.
dart "$(native_path "$root/tool/native/check_binary.dart")" \
  --headers "$(native_path "$src/include")" \
  --glibc-floor "$glibc_floor" --macos-floor "$macos_floor" --ios-floor "$ios_floor" \
  "${pairs[@]}"
