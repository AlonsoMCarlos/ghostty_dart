#!/usr/bin/env bash
# Prints the CI matrices derived from native/prebuilt_assets.json, one
# `key=<compact JSON>` line each (appended to $GITHUB_OUTPUT when set), so the
# workflows never repeat the asset table:
#   linux              assets built on Linux (each built twice)
#   macos              assets built on macOS
#   smoke              required smoke tests: [{asset, runner, dart}]
#   smoke_best_effort  best-effort smoke tests, same shape
#
# Usage: tool/native/matrix.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"
manifest="$root/native/prebuilt_assets.json"

smoke='[.assets | to_entries[] | select(.value.smoke) | {asset: .key, runner: .value.smoke.runner, dart: .value.smoke.dart, best_effort: (.value.smoke.best_effort // false)}]'
lines="$(
  printf 'linux=%s\n' "$(jq_raw '[.assets | to_entries[] | select(.value.builder == "linux") | .key]' "$manifest" -c)"
  printf 'macos=%s\n' "$(jq_raw '[.assets | to_entries[] | select(.value.builder == "macos") | .key]' "$manifest" -c)"
  printf 'smoke=%s\n' "$(jq_raw "$smoke | map(select(.best_effort | not) | del(.best_effort))" "$manifest" -c)"
  printf 'smoke_best_effort=%s\n' "$(jq_raw "$smoke | map(select(.best_effort) | del(.best_effort))" "$manifest" -c)"
)"
printf '%s\n' "$lines"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s\n' "$lines" >>"$GITHUB_OUTPUT"; fi
