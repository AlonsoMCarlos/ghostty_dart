#!/usr/bin/env bash
# Starts the runs that release-please's own actions cannot (ADR 0010).
#
# release-please runs with GITHUB_TOKEN, and what that token creates (tags,
# releases, pull requests, pushes) starts no workflow run; workflow_dispatch
# is the documented exception (docs.github.com, "Triggering a workflow from a
# workflow"). So:
#
#   dispatch.sh publish <tag>
#       gh workflow run publish.yml --ref <tag>. A dispatch on a tag ref gives
#       the OIDC token ref_type=tag, which pub.dev requires; pub.dev's
#       "Enable publishing from workflow_dispatch events" must be on.
#   dispatch.sh pr <branch>
#       gh workflow run ci.yml and dco.yml on the release PR branch, so the
#       release PR gets the checks a pull_request event would have given it.
#
# Needs GH_TOKEN (actions: write), GH_REPO (owner/name) and, for publish, a
# checkout whose origin it fetches the tag and main from. The names come from action outputs, so they are
# checked before use. REPO_ROOT overrides the root (tests).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tool/release/lib.sh
source "$here/lib.sh"
root="${REPO_ROOT:-$(cd "$here/../.." && pwd)}"

usage="usage: dispatch.sh publish <tag> | dispatch.sh pr <branch>"
what="${1:?$usage}"
ref="${2:?$usage}"
: "${GH_TOKEN:?GH_TOKEN is required}" "${GH_REPO:?GH_REPO is required}"

case "$what" in
  publish)
    is_release_tag "$ref" || die "'$ref' is not a ${release_tag_prefix}<X.Y.Z> tag"
    # publish.yml's checks are defined by the workflow file at the tag, so a
    # tag off main could carry its own; refuse it before dispatching.
    git -C "$root" fetch --quiet --no-tags origin \
      "+refs/tags/$ref:refs/tags/$ref" "+refs/heads/main:refs/remotes/origin/main"
    require_on_main "$root" "refs/tags/$ref" "$ref"
    gh workflow run publish.yml --ref "$ref"
    echo "dispatched publish.yml on $ref" >&2
    ;;
  pr)
    [[ "$ref" == "$release_pr_branch" ]] || die "'$ref' is not the release-please branch $release_pr_branch"
    gh workflow run ci.yml --ref "$ref"
    gh workflow run dco.yml --ref "$ref"
    echo "dispatched ci.yml and dco.yml on $ref" >&2
    ;;
  *) die "$usage" ;;
esac
