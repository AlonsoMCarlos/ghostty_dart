#!/usr/bin/env bash
# Publishes a verified release directory as the GitHub release <tag>, with
# `gh` (GH_TOKEN with contents: write). ADR 0008, "Release".
#
# Draft first, then upload, then publish: with immutable releases a release
# must be complete the moment it is published. A draft left by a failed
# earlier attempt is not immutable yet, so it is replaced; an already
# published release is never touched (cut a new -r<n>). The native release
# is never marked "Latest", so it does not compete with the package releases.
#
# Usage: tool/native/publish_release.sh <tag> <dist> <notes file>
set -euo pipefail

tag="${1:?usage: publish_release.sh <tag> <dist> <notes>}"
dist="${2:?usage: publish_release.sh <tag> <dist> <notes>}"
notes="${3:?usage: publish_release.sh <tag> <dist> <notes>}"
repo="${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY to <owner>/<repo>}"

if draft="$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2>/dev/null)"; then
  [[ "$draft" == true ]] || { echo "error: release $tag is already published; cut a new -r<n>" >&2; exit 1; }
  echo "replacing the unpublished draft $tag" >&2
  gh release delete "$tag" --repo "$repo" --yes
fi

gh release create "$tag" --repo "$repo" --draft --verify-tag --latest=false \
  --title "libghostty-vt prebuilt binaries $tag" --notes-file "$notes"
gh release upload "$tag" --repo "$repo" "$dist"/*
gh release edit "$tag" --repo "$repo" --draft=false --latest=false
echo "published $tag" >&2
