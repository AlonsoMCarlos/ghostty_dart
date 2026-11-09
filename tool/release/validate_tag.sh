#!/usr/bin/env bash
# Validates the ref of a publish.yml run (ADR 0010) before anything is built.
#
# Publishing needs all of:
#   - a `push` or `workflow_dispatch` event (the only ones pub.dev accepts);
#   - a tag ref (pub.dev requires an OIDC token with ref_type=tag, so a
#     dispatch on a branch is refused here, not at upload time);
#   - a tag named ghostty_dart-v<X.Y.Z> (no prerelease: ADR 0010);
#   - <X.Y.Z> equal to packages/ghostty_dart/pubspec.yaml `version` and to the
#     first heading of its CHANGELOG.md (pana and pub.dev check both);
#   - the checkout (HEAD) being the tagged commit, and that commit reachable
#     from origin/main, so only reviewed code is published (the checkout
#     needs fetch-depth: 0).
#
# Prints `tag=<tag>` and `version=<version>` (appended to $GITHUB_OUTPUT when
# set). Inputs (environment, as GitHub provides them): EVENT, REF_TYPE,
# REF_NAME. REPO_ROOT overrides the repository root (tests).
#
# Usage: tool/release/validate_tag.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tool/release/lib.sh
source "$here/lib.sh"
root="${REPO_ROOT:-$(cd "$here/../.." && pwd)}"

event="${EVENT:?EVENT is required}"
ref_type="${REF_TYPE:-}"
ref_name="${REF_NAME:-}"

case "$event" in
  push | workflow_dispatch) ;;
  *) die "publishing runs only on push or workflow_dispatch (pub.dev accepts no other event); got '$event'" ;;
esac

if [[ "$ref_type" != tag ]]; then
  die "publishing needs a tag ref (pub.dev requires ref_type=tag); got ${ref_type:-?} '$ref_name'. Dispatch with: gh workflow run publish.yml --ref ${release_tag_prefix}<version>"
fi
[[ "$ref_name" == "$release_tag_prefix"* ]] || die "tag '$ref_name' does not start with $release_tag_prefix"
version="${ref_name#"$release_tag_prefix"}"
is_release_version "$version" || die "tag '$ref_name': '$version' is not a plain X.Y.Z version (no prereleases, ADR 0010)"

# The versions below are read from the checkout, so it must be the tag.
head="$(git -C "$root" rev-parse HEAD)"
tagged="$(git -C "$root" rev-parse --verify --quiet "refs/tags/$ref_name^{commit}" || true)"
[[ -n "$tagged" ]] || die "tag $ref_name is not in the checkout (fetch-depth: 0 fetches tags)"
[[ "$tagged" == "$head" ]] || die "the checkout ($head) is not the commit of tag $ref_name ($tagged)"
require_on_main "$root" HEAD "$ref_name"

pubspec="$root/$release_package_dir/pubspec.yaml"
changelog="$root/$release_package_dir/CHANGELOG.md"
[[ -f "$pubspec" ]] || die "$pubspec not found"
[[ -f "$changelog" ]] || die "$changelog not found"
pubspec_v="$(pubspec_version "$pubspec")"
changelog_v="$(changelog_version "$changelog")"
[[ "$pubspec_v" == "$version" ]] || die "tag $ref_name is version $version, but $release_package_dir/pubspec.yaml has version '${pubspec_v}'"
[[ "$changelog_v" == "$version" ]] || die "tag $ref_name is version $version, but the first heading of $release_package_dir/CHANGELOG.md is '${changelog_v}'"

echo "will publish $release_package $version from $ref_name ($head, on main)" >&2
write_outputs "tag=$ref_name" "version=$version"
