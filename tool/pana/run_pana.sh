#!/usr/bin/env bash
# Scores a package with the pinned pana (tool/pana/pubspec.lock), the way
# pub.dev does (ADR 0010):
#
# 1. `dart pub publish --to-archive` builds the exact archive pub.dev would
#    receive (.gitignore and .pubignore applied, nothing outside the package);
# 2. the archive is extracted into a fresh temporary directory;
# 3. pana scores that directory and fails on any lost point
#    (`--exit-code-threshold 0`). Documentation is scored with the dartdoc
#    locked in tool/pana/pubspec.lock (`--dartdoc-command`), never with an
#    unpinned `pub global activate dartdoc`. `--dartdoc-version sdk` is not
#    usable: Dart 3.13's `dart doc` rejects the `--sanitize-html`,
#    `--max-file-count` and `--max-total-size` flags pana 0.23.19 passes.
#
# Scoring the extracted archive, not the source directory, is what makes the
# result match pub.dev: the source directory also holds .dart_tool/, local
# docs output and files that the archive leaves out.
#
# Packages with pubspec `screenshots` also need libwebp's tools (cwebp,
# dwebp, webpinfo, gif2webp, webpmux) on PATH, as on pub.dev.
#
# pana needs network: it resolves the package's dependencies (latest and
# oldest, ignoring our dependency_overrides, as pub.dev does), clones the
# `repository` to verify it, and checks URLs. It never runs build hooks.
#
# Usage: tool/pana/run_pana.sh [package dir...]  (relative to the current
#   directory; `mise run pana` runs from the repo root)
#   (default: every published package, packages/ghostty_dart and
#   packages/ghostty_dart_flutter, scored one after the other; the first
#   package below 160/160 stops the run)
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"

if [[ $# -eq 0 ]]; then
  set -- "$root/packages/ghostty_dart" "$root/packages/ghostty_dart_flutter"
fi
# Every package is checked before any is scored, so a missing tool fails in
# seconds rather than after the first package's minutes of scoring.
packages=()
for package in "$@"; do
  [[ -f "$package/pubspec.yaml" ]] || { echo "error: no pubspec.yaml in $package" >&2; exit 1; }
  package="$(cd "$package" && pwd)"
  name="$(basename "$package")"
  # pana converts pubspec `screenshots` to WebP with libwebp's command-line
  # tools; without them it only reports "No such file or directory" and
  # takes 10 points. Fail with the fix instead (Debian/Ubuntu: apt install
  # webp; macOS: brew install webp).
  if grep -q '^screenshots:' "$package/pubspec.yaml"; then
    for tool in webpinfo cwebp dwebp gif2webp webpmux; do
      command -v "$tool" > /dev/null \
        || { echo "error: $name has screenshots, and pana needs libwebp's '$tool' (install the webp package)" >&2; exit 1; }
    done
  fi
  packages+=("$package")
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$root/tool/pana"
dart pub get --enforce-lockfile

# dartdoc runs with the package directory as its working directory, so it is
# started from tool/pana's locked package config rather than with `dart run`.
# bin/dartdoc_path.dart resolves its location (and fails if it is missing).
package_config="$root/tool/pana/.dart_tool/package_config.json"
dartdoc="$(dart run bin/dartdoc_path.dart)"
[[ -f "$dartdoc" ]] || { echo "error: dartdoc executable not found: '$dartdoc'" >&2; exit 1; }

# The Flutter SDK that mise pins (it bundles the Dart running pana), as
# Flutter itself reports it; `command -v flutter` could be a shim. pub.dev
# also runs pana with a Flutter SDK; without one pana only logs a warning.
flutter --version --machine > "$work/flutter.json"
flutter_root="${FLUTTER_ROOT:-$(jq_raw .flutterRoot "$work/flutter.json")}"
[[ -d "$flutter_root" ]] || { echo "error: Flutter SDK not found: '$flutter_root'" >&2; exit 1; }

for package in "${packages[@]}"; do
  name="$(basename "$package")"
  echo "pana: archiving $package"
  (cd "$package" && dart pub publish --to-archive="$work/$name.tar.gz" --skip-validation)
  mkdir "$work/$name"
  tar -xzf "$work/$name.tar.gz" -C "$work/$name"

  echo "pana: scoring $name"
  dart run pana \
    --flutter-sdk "$flutter_root" \
    --dartdoc-command dart \
    --dartdoc-command "--packages=$package_config" \
    --dartdoc-command "$dartdoc" \
    --exit-code-threshold 0 \
    "$work/$name"
done
