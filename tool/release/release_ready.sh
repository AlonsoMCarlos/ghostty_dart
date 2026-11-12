#!/usr/bin/env bash
# Decides whether release-please may run (ADR 0010): only once the first
# version of every released package (the allow-list in tool/release/lib.sh,
# which test:release keeps equal to release-please-config.json's components)
# has been published by hand and tagged <package>-v<X.Y.Z>.
#
# Why: release-please finds the last release of a package by the tag of the
# version in .release-please-manifest.json (Manifest.backfillReleasesFromTags,
# release-please 17.6.0, src/manifest.ts). For a component without that tag
# it falls back to every commit after the shared `bootstrap-sha` that touches
# the package, and builds a release PR on top of the manifest version (the
# backfilled "previous version" in buildPullRequests): a bogus release of a
# version never published by hand.
#
# Why every package and not each one apart: release-please-action v5.0.0
# passes `path` only to the single-package (release-type) mode, never to
# Manifest.fromManifest (src/index.ts at 45996ed1), and reads the config
# file through the GitHub API at main, so one run always handles every
# component of the config. Skipping the whole run until the last component
# has its first tag is the only gate that cannot let a bogus PR or tag
# through. The pause lasts from merging a package into the config to its
# manual first publish (docs/internal/release-checklist.md).
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

missing=()
for package in "${release_packages[@]}"; do
  # Only real release tags count: a typo such as <package>-v0.1 does not.
  first=
  while IFS= read -r t; do
    if is_release_tag "$t" && [[ "$(release_tag_package "$t")" == "$package" ]]; then
      first="$t"
      break
    fi
  done < <(git -C "$root" tag --list "${package}-v*")
  if [[ -n "$first" ]]; then
    echo "$package: found $first" >&2
  else
    echo "$package: no ${package}-v<X.Y.Z> tag yet: publish its first version by hand (docs/internal/release-checklist.md)" >&2
    missing+=("$package")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "every released package has a release tag: release-please may run" >&2
  write_outputs "ready=true"
else
  echo "release-please is skipped until ${missing[*]} has a release tag" >&2
  write_outputs "ready=false"
fi
