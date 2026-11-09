#!/usr/bin/env bash
# Downloads pinned libghostty-vt release files into .native-cache/ and verifies
# them twice: the minisign signature of SHA256SUMS, and the sha256 pinned in
# native/upstream.json. Fails closed on any mismatch.
#
# Usage: tool/native/fetch_upstream.sh [file...]   (default: source + deps tarballs)
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
manifest="$root/native/upstream.json"
cache="$root/.native-cache"
mkdir -p "$cache"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"

base_url="$(jq_raw .base_url "$manifest")"
pubkey="$(jq_raw .minisign_public_key "$manifest")"
version="$(jq_raw .version "$manifest")"

if [[ $# -eq 0 ]]; then
  set -- "libghostty-vt-$version.tar.gz" "libghostty-vt-$version-deps.tar.gz"
fi

cd "$cache"
curl -sSfL --proto '=https' "$base_url/SHA256SUMS" -o SHA256SUMS
curl -sSfL --proto '=https' "$base_url/SHA256SUMS.minisig" -o SHA256SUMS.minisig
minisign -Vq -P "$pubkey" -m SHA256SUMS

for file in "$@"; do
  # shellcheck disable=SC2016 # $f is a jq variable, bound with --arg
  pinned="$(jq_raw '.files[$f] // empty' "$manifest" --arg f "$file")"
  [[ -n "$pinned" ]] || { echo "error: $file is not pinned in upstream.json" >&2; exit 1; }
  signed="$(tr -d '\r' <SHA256SUMS | awk -v f="$file" '$2 == f { print $1 }')"
  [[ "$signed" == "$pinned" ]] || { echo "error: $file: signed sum differs from pinned sum" >&2; exit 1; }

  # Re-hashes a cached copy on every run; downloads and verifies otherwise.
  fetch_verified "$base_url/$file" "$cache/$file" "$pinned"
  echo "verified $file"
done
