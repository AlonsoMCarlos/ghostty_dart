#!/usr/bin/env bash
# Decides whether release-please may run (ADR 0010): only once the first
# version has been published by hand and tagged ghostty_dart-v<version>.
#
# Why: release-please finds the last release of a package by the tag of the
# version in .release-please-manifest.json (Manifest.backfillReleasesFromTags,
# release-please 17.6.0, src/manifest.ts). Until the manual 0.1.0 tag exists
# it would treat the whole history as unreleased and open a bogus release PR
# on every push to main. Once a ghostty_dart-v<X.Y.Z> tag exists, release-please
# runs normally (its own later tags keep satisfying this check).
#
# Prints `ready=<true|false>` (appended to $GITHUB_OUTPUT when set). Needs a
# checkout with tags (fetch-depth: 0). REPO_ROOT overrides the root (tests).
#
# Usage: tool/release/release_ready.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tool/release/lib.sh
source "$here/lib.sh"
root="${REPO_ROOT:-$(cd "$here/../.." && pwd)}"

# Only real release tags count: a typo such as ghostty_dart-v0.1 does not.
first=
while IFS= read -r t; do
  if is_release_tag "$t"; then first="$t"; break; fi
done < <(git -C "$root" tag --list "${release_tag_prefix}*")
if [[ -n "$first" ]]; then
  echo "found $first: release-please may run" >&2
  write_outputs "ready=true"
else
  echo "no ${release_tag_prefix}<X.Y.Z> tag yet: publish the first version by hand (docs/internal/release-checklist.md); release-please is skipped" >&2
  write_outputs "ready=false"
fi
