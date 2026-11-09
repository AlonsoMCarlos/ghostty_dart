#!/usr/bin/env bash
# Assembles the release directory from the build artifacts (ADR 0008,
# "Reproducibility check"):
#   - every Linux-built asset must exist twice, as
#     <built>/native-<asset>-a/<asset> and .../native-<asset>-b/<asset>, with
#     identical sha256 (independent builds), or this fails;
#   - every macOS-built asset exists once (Apple ld output carries toolchain
#     data, so it is not held to bit-identity);
#   - the a copies go to <dist>, which then gets SHA256SUMS (sums.sh write);
#   - the per-build <asset>.buildinfo lines go to <buildinfo>.
# A Markdown table of the comparison is appended to $GITHUB_STEP_SUMMARY when
# set (GitHub Actions), and printed otherwise.
#
# Usage: tool/native/assemble_dist.sh <built> <dist> <buildinfo>
set -euo pipefail

built="${1:?usage: assemble_dist.sh <built> <dist> <buildinfo>}"
dist="${2:?usage: assemble_dist.sh <built> <dist> <buildinfo>}"
buildinfo="${3:?usage: assemble_dist.sh <built> <dist> <buildinfo>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"
manifest="$root/native/prebuilt_assets.json"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

mkdir -p "$dist"
[[ -z "$(ls -A "$dist")" ]] || { echo "error: $dist is not empty" >&2; exit 1; }
: >"$buildinfo"

{
  echo "| Asset | sha256 | Second build |"
  echo "|---|---|---|"
} >>"$summary"

failed=0
while IFS=$'\t' read -r asset builder; do
  a="$built/native-$asset-a/$asset"
  [[ -f "$a" ]] || { echo "error: missing build $a" >&2; exit 1; }
  hash_a="$(sha256_of "$a")"
  cat "$built/native-$asset-a/$asset.buildinfo" >>"$buildinfo"
  if [[ "$builder" == linux ]]; then
    b="$built/native-$asset-b/$asset"
    [[ -f "$b" ]] || { echo "error: missing second build $b" >&2; exit 1; }
    hash_b="$(sha256_of "$b")"
    cat "$built/native-$asset-b/$asset.buildinfo" >>"$buildinfo"
    if [[ "$hash_a" == "$hash_b" ]]; then
      echo "| \`$asset\` | \`$hash_a\` | identical |" >>"$summary"
    else
      echo "| \`$asset\` | \`$hash_a\` | **differs**: \`$hash_b\` |" >>"$summary"
      echo "error: $asset is not reproducible: $hash_a vs $hash_b" >&2
      failed=1
    fi
  else
    echo "| \`$asset\` | \`$hash_a\` | single build (Apple ld) |" >>"$summary"
  fi
  cp "$a" "$dist/$asset"
done < <(jq_raw '.assets | to_entries[] | "\(.key)\t\(.value.builder)"' "$manifest")

[[ "$failed" == 0 ]] || exit 1
"$root/tool/native/sums.sh" write "$dist"
