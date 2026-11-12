#!/usr/bin/env bash
# Validates the ref of a publish.yml run (ADR 0010) before anything is built.
#
# Publishing needs all of:
#   - a `push` or `workflow_dispatch` event (the only ones pub.dev accepts);
#   - a tag ref (pub.dev requires an OIDC token with ref_type=tag, so a
#     dispatch on a branch is refused here, not at upload time);
#   - a tag named <package>-v<X.Y.Z>, with <package> in the allow-list of
#     tool/release/lib.sh (ghostty_dart, ghostty_dart_flutter,
#     ghostty_dart_xterm) and no prerelease (ADR 0010); the tag alone
#     selects the package;
#   - <X.Y.Z> equal to packages/<package>/pubspec.yaml `version`, that pubspec
#     named <package>, and <X.Y.Z> equal to the first heading of its
#     CHANGELOG.md (pana and pub.dev check both);
#   - the checkout (HEAD) being the tagged commit, and that commit reachable
#     from origin/main, so only reviewed code is published (the checkout
#     needs fetch-depth: 0).
#
# Prints `tag=<tag>`, `package=<package>` and `version=<version>` (appended
# to $GITHUB_OUTPUT when set). Inputs (environment, as GitHub provides them):
# EVENT, REF_TYPE, REF_NAME. REPO_ROOT overrides the repository root (tests).
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
  die "publishing needs a tag ref (pub.dev requires ref_type=tag); got ${ref_type:-?} '$ref_name'. Dispatch with: gh workflow run publish.yml --ref <package>-v<version>"
fi
package="$(release_tag_package "$ref_name")" ||
  die "tag '$ref_name' is not a <package>-v<X.Y.Z> tag"
is_release_package "$package" ||
  die "tag '$ref_name': '$package' is not a package this pipeline publishes (${release_packages[*]})"
version="$(release_tag_version "$ref_name")"
is_release_version "$version" || die "tag '$ref_name': '$version' is not a plain X.Y.Z version (no prereleases, ADR 0010)"
package_dir="$(release_package_dir "$package")"

# The versions below are read from the checkout, so it must be the tag.
head="$(git -C "$root" rev-parse HEAD)"
tagged="$(git -C "$root" rev-parse --verify --quiet "refs/tags/$ref_name^{commit}" || true)"
[[ -n "$tagged" ]] || die "tag $ref_name is not in the checkout (fetch-depth: 0 fetches tags)"
[[ "$tagged" == "$head" ]] || die "the checkout ($head) is not the commit of tag $ref_name ($tagged)"
require_on_main "$root" HEAD "$ref_name"

pubspec="$root/$package_dir/pubspec.yaml"
changelog="$root/$package_dir/CHANGELOG.md"
[[ -f "$pubspec" ]] || die "$pubspec not found"
[[ -f "$changelog" ]] || die "$changelog not found"
pubspec_name="$(pubspec_name "$pubspec")"
[[ "$pubspec_name" == "$package" ]] || die "tag $ref_name is package $package, but $package_dir/pubspec.yaml is named '${pubspec_name}'"
pubspec_v="$(pubspec_version "$pubspec")"
changelog_v="$(changelog_version "$changelog")"
[[ "$pubspec_v" == "$version" ]] || die "tag $ref_name is version $version, but $package_dir/pubspec.yaml has version '${pubspec_v}'"
[[ "$changelog_v" == "$version" ]] || die "tag $ref_name is version $version, but the first heading of $package_dir/CHANGELOG.md is '${changelog_v}'"

echo "will publish $package $version from $ref_name ($head, on main)" >&2
write_outputs "tag=$ref_name" "package=$package" "version=$version"
