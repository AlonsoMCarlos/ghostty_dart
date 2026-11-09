#!/usr/bin/env bash
# Verifies the Dart SDK pinned in native/toolchain.json for one platform
# (downloading it into .native-cache/ when needed), extracts it into <dest>, a
# new empty directory, and prints its bin/ directory as the only line on
# stdout (a bash path: prepend it to PATH in bash; convert it with
# native_path before handing it to anything else, e.g. $GITHUB_PATH).
#
# For jobs without Flutter: the release `verify` job (linux-x64), and the
# arm64 smoke tests, because Flutter 3.47.9 (the mise pin) has no linux-arm64
# or windows-arm64 SDK. The pinned version is the Dart SDK that Flutter 3.47.9
# bundles. The archive is re-hashed on every call; the extraction is fresh.
#
# Usage: tool/native/fetch_dart_sdk.sh <linux-x64 | linux-arm64 | windows-arm64> <dest>
#   The platform is an argument, not detected: Git Bash on Windows arm64 may
#   itself run emulated and report x86_64.
set -euo pipefail

platform="${1:?usage: fetch_dart_sdk.sh <platform> <dest>}"
dest="${2:?usage: fetch_dart_sdk.sh <platform> <dest>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"
manifest="$root/native/toolchain.json"

base_url="$(jq_raw .dart_sdk.base_url "$manifest")"
# shellcheck disable=SC2016 # $p is a jq variable, bound with --arg
pinned="$(jq_raw '.dart_sdk.sha256[$p] // empty' "$manifest" --arg p "$platform")"
[[ -n "$pinned" ]] || { echo "error: no Dart SDK pinned for $platform in native/toolchain.json" >&2; exit 1; }

file="dartsdk-$platform-release.zip"
zip="$root/.native-cache/$file"
mkdir -p "$root/.native-cache"
fetch_verified "$base_url/$file" "$zip" "$pinned"
echo "verified $file" >&2

mkdir -p "$dest"
[[ -z "$(ls -A "$dest")" ]] || { echo "error: $dest is not empty" >&2; exit 1; }
if command -v unzip >/dev/null 2>&1; then
  unzip -q "$zip" -d "$dest"
else
  # Git Bash on Windows may lack unzip; PowerShell is always there. The paths
  # go through the environment so no quoting can break the command.
  # shellcheck disable=SC2016 # $env:ZIP/$env:DEST are PowerShell, not bash
  ZIP="$(native_path "$zip")" DEST="$(native_path "$dest")" \
    powershell -NoProfile -Command 'Expand-Archive -LiteralPath $env:ZIP -DestinationPath $env:DEST'
fi
[[ -d "$dest/dart-sdk/bin" ]] || { echo "error: $file has no dart-sdk/bin" >&2; exit 1; }
printf '%s\n' "$dest/dart-sdk/bin"
