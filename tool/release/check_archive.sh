#!/usr/bin/env bash
# Checks a publish archive before it is uploaded (ADR 0010, publish.yml
# `publish` job): the approval wait in the `pub.dev` environment can last
# hours, so only the exact bytes the `package` job produced may go out.
#
#   - its sha256 equals <sha256> (the `package` job's output);
#   - it lists pubspec.yaml at the top level and no absolute or `..` path;
#   - that pubspec has the name and version of <tag> (<package>-v<X.Y.Z>,
#     a package of the allow-list in tool/release/lib.sh) and no `publish_to`.
#
# Usage: tool/release/check_archive.sh <archive.tar.gz> <sha256> <tag>
set -euo pipefail

archive="${1:?usage: check_archive.sh <archive> <sha256> <tag>}"
expected="${2:?usage: check_archive.sh <archive> <sha256> <tag>}"
tag="${3:?usage: check_archive.sh <archive> <sha256> <tag>}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=tool/release/lib.sh
source "$here/lib.sh"

is_release_tag "$tag" || die "'$tag' is not a <package>-v<X.Y.Z> tag of a published package (${release_packages[*]})"
package="$(release_tag_package "$tag")"
version="$(release_tag_version "$tag")"

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
name="$(pubspec_name "$pubspec")"
[[ "$name" == "$package" ]] || die "archive pubspec name is '$name', not $package"
archive_v="$(pubspec_version "$pubspec")"
[[ "$archive_v" == "$version" ]] || die "archive pubspec version is '$archive_v', not $version"
if grep -qE '^publish_to:' "$pubspec"; then die "archive pubspec sets publish_to"; fi

echo "verified $archive: $package $version, sha256 $actual, $(wc -l <<<"$listing" | tr -d ' ') entries" >&2
