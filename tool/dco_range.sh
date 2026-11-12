#!/usr/bin/env bash
# Picks the commit range of a dco.yml run and runs tool/check_dco.sh on it.
#
#   pull_request: the checkout is GitHub's PR merge commit. Its first parent
#     is the base branch tip at the time of the run and its second the PR
#     head (PR_HEAD, checked), so HEAD^1..PR_HEAD is exactly the PR's
#     commits, even if the PR merged the base branch in since it was opened
#     (the event's base.sha can be older than the base tip). The release-bot
#     exception is never allowed here: a fork or contributor PR could forge
#     a github-actions[bot] commit with the maintainer's sign-off.
#   workflow_dispatch: origin/main..HEAD, the dispatched branch's commits
#     that main lacks. The base is always main, never an input: another
#     base could make a branch's range empty and its check green. The
#     release-bot exception is allowed only for the run release-please.yml
#     dispatches: on one of release-please's own branches (one per released
#     package, tool/release/lib.sh), started by
#     github-actions[bot] (GITHUB_TOKEN; no person can be that actor).
#
# Inputs (environment): EVENT; for pull_request PR_HEAD and BASE_REF (the
# PR's base branch, for the fix hint); for workflow_dispatch HEAD_REF
# (github.ref_name) and ACTOR (github.actor). Needs a checkout with
# fetch-depth: 0. REPO_ROOT overrides the repository (tests).
#
# Usage: tool/dco_range.sh   (dco.yml only; locally: mise run dco)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tool/release/lib.sh
source "$here/release/lib.sh"
root="${REPO_ROOT:-$(cd "$here/.." && pwd)}"
check="$here/check_dco.sh"
unset DCO_ALLOW_RELEASE_BOT

case "${EVENT:?EVENT is required}" in
  pull_request)
    pr_head="${PR_HEAD:?PR_HEAD is required}"
    second="$(git -C "$root" rev-parse --verify --quiet 'HEAD^2' || true)"
    [[ -n "$second" && "$second" == "$pr_head" ]] ||
      die "the checkout is not the merge commit of PR head $pr_head (HEAD^2 is '${second:-none}')"
    base_ref="${BASE_REF:?BASE_REF is required}"
    [[ "$base_ref" =~ ^[A-Za-z0-9._/-]+$ && "$base_ref" != -* ]] || die "'$base_ref' is not a branch name"
    DCO_BASE_LABEL="origin/$base_ref" exec bash "$check" "$(git -C "$root" rev-parse 'HEAD^1')" "$pr_head"
    ;;
  workflow_dispatch)
    if is_release_pr_branch "${HEAD_REF:-}" && [[ "${ACTOR:-}" == 'github-actions[bot]' ]]; then
      echo "release-please's dispatched run on $HEAD_REF: its own commits may carry the configured sign-off" >&2
      export DCO_ALLOW_RELEASE_BOT=1
    fi
    DCO_BASE_LABEL=origin/main exec bash "$check" refs/remotes/origin/main HEAD
    ;;
  *) die "unsupported event '$EVENT'" ;;
esac
