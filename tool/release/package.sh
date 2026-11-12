#!/usr/bin/env bash
# Writes the publish archive of the package a release tag names
# (<package>-v<X.Y.Z>, a package of the allow-list in tool/release/lib.sh),
# offline, and prints its sha256 (ADR 0010, publish.yml `package` job).
#
# `dart pub publish --to-archive=<file> --skip-validation` is the hidden pub
# flag that setup-dart's three-job publish.yml uses (dart-lang/setup-dart
# a1d8526c926344e01ba48a7368788c05ac98cb29, .github/workflows/publish.yml);
# its definition is in dart-lang/pub ec276d10a7fa0f6c6ec005340fb9ad29f3b012d0
# (the pub of Dart 3.13.7), lib/src/command/lish.dart. With
# --skip-validation pub neither resolves nor downloads anything: it lists the
# package files (git ls-files rules, .pubignore) and tars them. Validation
# already ran in the `validate` job (`dart pub publish --dry-run`).
#
# No network while it runs: `unshare -rn` where unprivileged user namespaces
# work (as tool/native/build.sh does). GitHub's Ubuntu 24.04 images forbid
# those (AppArmor), so in CI it falls back to the root-made namespace that
# setup-dart uses (`sudo -E unshare -n sudo -u <user> ...`). In CI one of the
# two must work (fails closed); locally it warns and keeps the network.
#
# Dart: $DART (the pinned, verified SDK in CI), else `dart` on PATH. A plain
# Dart SDK is enough for the Flutter package ghostty_dart_flutter too: with
# --skip-validation nothing resolves, so the `flutter` SDK dependency is never
# looked up, and the archive is byte-identical to `flutter pub publish
# --to-archive` (checked 2026-11-12 with Dart 3.13.7 and Flutter 3.47.9).
# Prints `archive=<path>` and `sha256=<hex>` (appended to $GITHUB_OUTPUT when
# set).
#
# Usage: tool/release/package.sh <tag> <archive.tar.gz>
set -euo pipefail

tag="${1:?usage: package.sh <tag> <archive.tar.gz>}"
out="${2:?usage: package.sh <tag> <archive.tar.gz>}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=tool/release/lib.sh
source "$here/lib.sh"

is_release_tag "$tag" || die "'$tag' is not a <package>-v<X.Y.Z> tag of a published package (${release_packages[*]})"
package="$(release_tag_package "$tag")"
package_dir="$(release_package_dir "$package")"

mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
dart="${DART:-dart}"
command -v "$dart" >/dev/null || die "dart not found (set DART or put it on PATH)"

offline=()
if [[ "$(uname -s)" == Linux ]] && unshare -rn true 2>/dev/null; then
  offline=(unshare -rn)
elif [[ "${CI:-}" == true && "$(uname -s)" == Linux ]] && sudo -n true 2>/dev/null &&
  sudo -n unshare -n true 2>/dev/null; then
  offline=(sudo -E unshare -n sudo -u "$(id -un)" -E env "PATH=$PATH" "HOME=$HOME")
elif [[ "${CI:-}" == true ]]; then
  die "cannot drop the network for packaging (no user or root network namespace)"
else
  echo "warning: no network namespace available; packaging with the network on" >&2
fi

rm -f "$out"
${offline[@]+"${offline[@]}"} "$dart" pub publish --to-archive="$out" --skip-validation \
  --directory="$root/$package_dir" >&2
[[ -s "$out" ]] || die "pub wrote no archive at $out"

sha="$(sha256_of "$out")"
echo "packaged $package into $out" >&2
write_outputs "archive=$out" "sha256=$sha"
