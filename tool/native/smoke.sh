#!/usr/bin/env bash
# Smoke-tests one release asset on this machine: runs the full ghostty_dart
# test suite against it, through the root pubspec's `source: path`
# (.native-cache/host/<bundled name>). ADR 0008, "Smoke tests".
#
# 1. `sums.sh verify`: <dist> must be exactly the canonical, checked release
#    set (<expected> is the SHA256SUMS the `verify` job exported).
# 2. Stage <dist>/<asset> as .native-cache/host/<bundled name>; a host build
#    already there is restored on exit.
# 3. `dart test` in packages/ghostty_dart (what `mise run test` runs), after
#    `mise run deps` (Flutter from mise), or, where the manifest's
#    `smoke.dart` names a platform (no Flutter SDK exists there), with the
#    pinned Dart SDK inside pub_get_without_flutter.sh.
#
# Usage: tool/native/smoke.sh <asset> <dist> <expected SHA256SUMS>
set -euo pipefail

asset="${1:?usage: smoke.sh <asset> <dist> <expected SHA256SUMS>}"
dist="${2:?usage: smoke.sh <asset> <dist> <expected SHA256SUMS>}"
expected="${3:?usage: smoke.sh <asset> <dist> <expected SHA256SUMS>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"

# shellcheck disable=SC2016 # $a is a jq variable, bound with --arg
dart_mode="$(jq_raw '.assets[$a].smoke.dart // empty' "$root/native/prebuilt_assets.json" --arg a "$asset")"
[[ -n "$dart_mode" ]] || { echo "error: $asset has no smoke runner in native/prebuilt_assets.json" >&2; exit 1; }

"$root/tool/native/sums.sh" verify "$dist" "$expected"

work="$(mktemp -d)"
host="$root/.native-cache/host"
had_host=false
restore() {
  rm -rf "$host"
  if [[ "$had_host" == true ]]; then mv "$work/host" "$host"; fi
  rm -rf "$work"
}
trap restore EXIT

if [[ -d "$host" ]]; then mv "$host" "$work/host" && had_host=true; fi
mkdir -p "$host"
name="$(bundled_name "$asset")"
cp "$dist/$asset" "$host/$name"
echo "testing $asset ($(sha256_of "$host/$name")) as $host/$name"

# Inside the package: from the workspace root `dart test` would not run the
# build hook (same reason as the `test` task).
run_tests() { (cd "$root/packages/ghostty_dart" && dart --version && dart test); }

if [[ "$dart_mode" == mise ]]; then
  (cd "$root" && mise run deps)
  run_tests
else
  bin="$("$root/tool/native/fetch_dart_sdk.sh" "$dart_mode" "$work/dart")"
  export PATH="$bin:$PATH"
  # The tests must run while the Flutter-free resolution is in place.
  # shellcheck disable=SC2016 # $1 expands in the inner bash, on purpose
  "$root/tool/native/pub_get_without_flutter.sh" \
    bash -c 'cd "$1/packages/ghostty_dart" && dart --version && dart test' _ "$root"
fi
