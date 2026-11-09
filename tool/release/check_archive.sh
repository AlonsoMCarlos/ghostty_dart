#!/usr/bin/env bash
# Checks a publish archive before it is uploaded (ADR 0010, publish.yml
# `publish` job): the approval wait in the `pub.dev` environment can last
# hours, so only the exact bytes the `package` job produced may go out.
#
#   - its sha256 equals <sha256> (the `package` job's output);
#   - it lists pubspec.yaml at the top level and no absolute or `..` path;
#   - that pubspec has `name: ghostty_dart`, `version: <version>` and no
#     `publish_to`.
#
# Usage: tool/release/check_archive.sh <archive.tar.gz> <sha256> <version>
set -euo pipefail

archive="${1:?usage: check_archive.sh <archive> <sha256> <version>}"
expected="${2:?usage: check_archive.sh <archive> <sha256> <version>}"
version="${3:?usage: check_archive.sh <archive> <sha256> <version>}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=tool/release/lib.sh
source "$here/lib.sh"

[[ -s "$archive" ]] || die "$archive is missing or empty"
actual="$(sha256_of "$archive")"
[[ "$actual" == "$expected" ]] || die "$archive: sha256 $actual differs from the packaged $expected"

listing="$(tar -tzf "$archive")"
grep -qxE '(\./)?pubspec\.yaml' <<<"$listing" || die "$archive has no top-level pubspec.yaml"
if grep -qE '(^/|(^|/)\.\.(/|$))' <<<"$listing"; then
  die "$archive lists an absolute or '..' path"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xzf "$archive" -C "$work" pubspec.yaml 2>/dev/null || tar -xzf "$archive" -C "$work" ./pubspec.yaml
pubspec="$work/pubspec.yaml"
name="$(tr -d '\r' <"$pubspec" | sed -n -E 's/^name:[[:space:]]*([A-Za-z0-9_]+).*$/\1/p' | head -n 1)"
[[ "$name" == "$release_package" ]] || die "archive pubspec name is '$name', not $release_package"
archive_v="$(pubspec_version "$pubspec")"
[[ "$archive_v" == "$version" ]] || die "archive pubspec version is '$archive_v', not $version"
if grep -qE '^publish_to:' "$pubspec"; then die "archive pubspec sets publish_to"; fi

echo "verified $archive: $release_package $version, sha256 $actual, $(wc -l <<<"$listing" | tr -d ' ') entries" >&2
