#!/usr/bin/env bash
# The canonical SHA256SUMS of a release directory (ADR 0008).
#
#   sums.sh write <dist>             write <dist>/SHA256SUMS
#   sums.sh output <dist>            append <dist>/SHA256SUMS to $GITHUB_OUTPUT
#                                    as `sums` (multi-line) and `sha256`
#   sums.sh verify <dist> <expected> fail unless <dist> holds exactly the
#                                    assets plus SHA256SUMS, its SHA256SUMS is
#                                    byte-identical to <expected>, and every
#                                    asset still hashes to its line.
#
# `verify` is how every job after `verify` (attest, smoke, release) proves it
# holds the very bytes that were compared and checked: artifacts can be
# re-uploaded by any job of the run, so their content is never trusted alone.
#
# Format: sha256sum's `<hex>  <file>`, one line per asset in
# native/prebuilt_assets.json, sorted by file name (C collation).
set -euo pipefail

cmd="${1:?usage: sums.sh write|output <dist> | verify <dist> <expected>}"
dist="${2:?usage: sums.sh write <dist> | verify <dist> <expected>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"

expected_assets="$(jq_raw '.assets | keys[]' "$root/native/prebuilt_assets.json" | LC_ALL=C sort)"

# The file names in <dist>, sorted, minus SHA256SUMS. Directories or anything
# else unexpected make the set differ and fail.
present() {
  local f
  for f in "$dist"/* "$dist"/.[!.]*; do
    [[ -e "$f" ]] || continue
    [[ "${f##*/}" == SHA256SUMS ]] && continue
    printf '%s\n' "${f##*/}"
  done | LC_ALL=C sort
}

require_exact_set() {
  if [[ "$(present)" != "$expected_assets" ]]; then
    echo "error: $dist does not hold exactly the ADR 0008 assets:" >&2
    diff <(printf '%s\n' "$expected_assets") <(present) >&2 || true
    exit 1
  fi
}

compute() {
  local asset
  while IFS= read -r asset; do
    printf '%s  %s\n' "$(sha256_of "$dist/$asset")" "$asset"
  done <<<"$expected_assets"
}

case "$cmd" in
  write)
    require_exact_set
    compute >"$dist/SHA256SUMS.part"
    mv "$dist/SHA256SUMS.part" "$dist/SHA256SUMS"
    cat "$dist/SHA256SUMS"
    ;;
  output)
    [[ -n "${GITHUB_OUTPUT:-}" ]] || { echo "error: GITHUB_OUTPUT is not set" >&2; exit 1; }
    require_exact_set
    [[ -f "$dist/SHA256SUMS" ]] || { echo "error: $dist has no SHA256SUMS" >&2; exit 1; }
    # Multi-line output with a delimiter that cannot occur in the file.
    delimiter="EOF_$(sha256_of "$dist/SHA256SUMS")"
    {
      echo "sums<<$delimiter"
      cat "$dist/SHA256SUMS"
      echo "$delimiter"
      echo "sha256=$(sha256_of "$dist/SHA256SUMS")"
    } >>"$GITHUB_OUTPUT"
    ;;
  verify)
    want="${3:?usage: sums.sh verify <dist> <expected>}"
    require_exact_set
    [[ -f "$dist/SHA256SUMS" ]] || { echo "error: $dist has no SHA256SUMS" >&2; exit 1; }
    cmp -s "$dist/SHA256SUMS" "$want" || { echo "error: $dist/SHA256SUMS differs from the expected one" >&2; exit 1; }
    if [[ "$(compute)" != "$(cat "$want")" ]]; then
      echo "error: the assets in $dist do not match the expected SHA256SUMS:" >&2
      diff "$want" <(compute) >&2 || true
      exit 1
    fi
    echo "verified $dist against SHA256SUMS ($(sha256_of "$want"))"
    ;;
  *) echo "error: unknown command '$cmd'" >&2; exit 64 ;;
esac
