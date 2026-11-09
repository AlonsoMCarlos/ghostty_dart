#!/usr/bin/env bash
# Verifies the Android NDK pinned in native/toolchain.json (downloading it into
# .native-cache/ndk/ when needed), extracts its sysroot into <dest>, a new
# empty directory, and prints the NDK root inside <dest> (the value for
# ANDROID_NDK_HOME) as the only line on stdout.
#
# The archive is verified on every call, cached or not, and fails closed on
# either check:
#   - sha1: the only checksum Google publishes (repository2-3.xml);
#   - sha256: computed once from a SHA-1-verified download and pinned in the
#     repo, so a SHA-1 collision alone cannot substitute the archive.
# The extraction is always fresh: an extracted tree is never reused.
#
# Upstream (pkg/android-ndk/build.zig) uses only the NDK sysroot: headers, crt
# objects and bionic stubs, through a generated libc.txt; the compiler stays
# Zig's clang. So only the sysroot is extracted (no NDK executables land on
# disk). Upstream looks it up under prebuilt/linux-x86_64 on every Linux host,
# so the archive works on Linux of any architecture, and only there.
#
# Usage: tool/native/fetch_ndk.sh <dest>
set -euo pipefail

dest="${1:?usage: fetch_ndk.sh <dest dir>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"
manifest="$root/native/toolchain.json"

release="$(jq_raw .android_ndk.release "$manifest")"
url="$(jq_raw .android_ndk.url "$manifest")"
pinned_sha1="$(jq_raw .android_ndk.sha1 "$manifest")"
pinned_sha256="$(jq_raw .android_ndk.sha256 "$manifest")"

if [[ "$(uname -s)" != Linux ]]; then
  echo "error: the pinned NDK archive is the Linux one; this host is $(uname -s)" >&2
  exit 1
fi

dir="$root/.native-cache/ndk"
zip="$dir/${url##*/}"
mkdir -p "$dir"

# sha256 first (download or re-hash), then Google's sha1 on the same bytes.
fetch_verified "$url" "$zip" "$pinned_sha256"
sha1="$(sha1sum "$zip" | cut -d' ' -f1)"
if [[ "$sha1" != "$pinned_sha1" ]]; then
  echo "error: ${zip##*/}: sha1 $sha1 differs from pinned $pinned_sha1" >&2
  exit 1
fi
echo "verified ${zip##*/} (sha256 + sha1)" >&2

mkdir -p "$dest"
[[ -z "$(ls -A "$dest")" ]] || { echo "error: $dest is not empty" >&2; exit 1; }
sysroot="android-ndk-$release/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
unzip -q "$zip" "$sysroot/*" -d "$dest"
[[ -d "$dest/$sysroot" ]] || { echo "error: the archive has no linux-x86_64 sysroot" >&2; exit 1; }
printf '%s\n' "$dest/android-ndk-$release"
