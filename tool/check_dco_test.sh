#!/usr/bin/env bash
# Tests tool/check_dco.sh and tool/dco_range.sh in throwaway git repos.
# Run with `mise run test:release` (part of `mise run check`), or
# `bash tool/check_dco_test.sh`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tool/test_harness.sh
source "$root/tool/test_harness.sh"

me="$test_name"
me_email="$test_email"
bot_name='github-actions[bot]'
bot_email='41898282+github-actions[bot]@users.noreply.github.com'
maintainer='Carol Maintainer <carol@example.org>'
release_branch=release-please--branches--main--components--ghostty_dart

dco() { REPO_ROOT="$1" bash "$root/tool/check_dco.sh" "$2" "$3"; }
# bot_commit <dir> <message> <sign-off>: a commit authored as release-please.
bot_commit() {
  GIT_AUTHOR_NAME="$bot_name" GIT_AUTHOR_EMAIL="$bot_email" \
    git -C "$1" commit -q --allow-empty -m "$2" -m "Signed-off-by: $3"
}
write_config() {
  printf '{\n  "signoff": "%s",\n  "packages": {}\n}\n' "$maintainer" >"$1/release-please-config.json"
  git -C "$1" add release-please-config.json
  git -C "$1" commit -q -s -m "chore: release-please config"
}

# ---------------------------------------------------------- check_dco.sh
r="$tmp/dco"
new_repo "$r"
base="$(git -C "$r" rev-parse HEAD)"

check "empty range that changes nothing passes" 0 "nothing to certify" dco "$r" "$base" HEAD

commit "$r" "feat: signed" -s
check "signed-off commit passes" 0 "all 1 commit" dco "$r" "$base" HEAD

commit "$r" "fix: email case" -m "Signed-off-by: $me <ADA@Example.org>"
check "email compares case-insensitively" 0 "all 2 commit" dco "$r" "$base" HEAD

git -C "$r" checkout -q -b topic
commit "$r" "feat: on topic" -s
git -C "$r" checkout -q main
commit "$r" "feat: on main" -s
git -C "$r" merge -q --no-ff --no-edit topic # unsigned merge commit
check "merge commits are skipped" 0 "all 4 commit" dco "$r" "$base" HEAD

good="$(git -C "$r" rev-parse HEAD)"
commit "$r" "fix: unsigned"
check "unsigned commit fails" 1 "fix: unsigned \(author: $me <$me_email>\)" dco "$r" "$base" HEAD
check "failure explains the fix" 1 "git rebase --signoff $base" dco "$r" "$base" HEAD
check "fix hint uses DCO_BASE_LABEL" 1 "git rebase --signoff origin/main" \
  env DCO_BASE_LABEL=origin/main REPO_ROOT="$r" bash "$root/tool/check_dco.sh" "$base" HEAD

git -C "$r" reset -q --hard "$good"
commit "$r" "fix: someone else" -m "Signed-off-by: Bob <bob@example.org>"
check "sign-off by another identity fails" 1 "fix: someone else" dco "$r" "$good" HEAD

git -C "$r" reset -q --hard "$good"
commit "$r" "fix: other name" -m "Signed-off-by: A. Lovelace <$me_email>"
check "the name must match too" 1 "fix: other name" dco "$r" "$good" HEAD

git -C "$r" reset -q --hard "$good"
commit "$r" "fix: buried" -m "Signed-off-by: $me <$me_email>" -m "More text after it, so it is no trailer."
check "a sign-off outside the trailer block does not count" 1 "fix: buried" dco "$r" "$good" HEAD

git -C "$r" reset -q --hard "$good"
commit "$r" "fix: several trailers" -m "Co-authored-by: Bob <bob@example.org>
Signed-off-by: Bob <bob@example.org>
Signed-off-by: $me <$me_email>"
check "any matching sign-off of several passes" 0 "all 1 commit" dco "$r" "$good" HEAD

# Content that enters only through a merge commit: no commit certifies it.
git -C "$r" reset -q --hard "$good"
printf 'evil\n' >"$r/evil.txt"
git -C "$r" add evil.txt
tree="$(git -C "$r" write-tree)"
evil="$(git -C "$r" commit-tree "$tree" -p "$good" -p "$base" -m "Merge something")"
git -C "$r" reset -q --hard "$evil"
check "a merge-only range that changes files fails" 1 "no non-merge commit to certify" dco "$r" "$good" HEAD

# release-please's commits: the exception is off unless explicitly allowed.
git -C "$r" reset -q --hard "$good"
write_config "$r"
cfg="$(git -C "$r" rev-parse HEAD)"
bot_commit "$r" "chore(main): release ghostty_dart 0.1.1" "$maintainer"
check "forged release-please commit fails by default (skeptic's case)" 1 "chore\(main\): release ghostty_dart 0.1.1" dco "$r" "$cfg" HEAD
check "release-please commit passes when the exception is allowed" 0 "all 1 commit" \
  env DCO_ALLOW_RELEASE_BOT=1 REPO_ROOT="$r" bash "$root/tool/check_dco.sh" "$cfg" HEAD
git -C "$r" reset -q --hard "$cfg"
bot_commit "$r" "chore: bot" "Mallory <m@example.org>"
check "bot commit with another sign-off fails even when allowed" 1 "chore: bot" \
  env DCO_ALLOW_RELEASE_BOT=1 REPO_ROOT="$r" bash "$root/tool/check_dco.sh" "$cfg" HEAD

check "unknown ref fails" 1 "not a commit" dco "$r" nope HEAD
check "missing argument fails" 1 "usage: check_dco.sh" bash "$root/tool/check_dco.sh" HEAD

# ---------------------------------------------------------- dco_range.sh
r="$tmp/range"
new_repo "$r"
write_config "$r"
git -C "$r" checkout -q -b pr
commit "$r" "feat: pr work" -s
pr_head="$(git -C "$r" rev-parse HEAD)"
git -C "$r" checkout -q main
commit "$r" "feat: main moved" # unsigned, but not the PR's
main_tip="$(git -C "$r" rev-parse HEAD)"
git -C "$r" update-ref refs/remotes/origin/main "$main_tip"
git -C "$r" checkout -q --detach
git -C "$r" merge -q --no-ff --no-edit "$pr_head" # GitHub's refs/pull/N/merge
range() { env REPO_ROOT="$r" "$@" bash "$root/tool/dco_range.sh"; }
pr_env=(EVENT=pull_request PR_HEAD="$pr_head" BASE_REF=main)
check "pull_request checks only the PR's commits" 0 "all 1 commit" range "${pr_env[@]}"
check "pull_request refuses a checkout that is not the PR merge" 1 "not the merge commit" \
  range EVENT=pull_request PR_HEAD="$main_tip" BASE_REF=main
check "pull_request rejects an option-like base" 1 "not a branch name" \
  range EVENT=pull_request PR_HEAD="$pr_head" BASE_REF=--all

# The skeptic's forged case: a contributor PR with a github-actions[bot]
# commit carrying the maintainer's sign-off. Even on a PR from a branch named
# like release-please's, and even with the variable set by the caller.
git -C "$r" checkout -q -B "$release_branch" "$pr_head"
bot_commit "$r" "chore(main): release ghostty_dart 9.9.9" "$maintainer"
forged="$(git -C "$r" rev-parse HEAD)"
git -C "$r" checkout -q --detach "$main_tip"
git -C "$r" merge -q --no-ff --no-edit "$forged"
check "pull_request never allows the bot exception" 1 "release ghostty_dart 9\.9\.9" \
  range EVENT=pull_request PR_HEAD="$forged" BASE_REF=main HEAD_REF="$release_branch" ACTOR="$bot_name" DCO_ALLOW_RELEASE_BOT=1

# workflow_dispatch: the exception only for release-please's own run.
git -C "$r" checkout -q "$release_branch"
check "dispatch by github-actions[bot] on release-please's branch allows it" 0 "all 2 commit" \
  range EVENT=workflow_dispatch HEAD_REF="$release_branch" ACTOR="$bot_name"
check "dispatch by a person on release-please's branch does not" 1 "release ghostty_dart 9\.9\.9" \
  range EVENT=workflow_dispatch HEAD_REF="$release_branch" ACTOR=mallory
git -C "$r" checkout -q -B other "$forged"
check "dispatch by github-actions[bot] on another branch does not" 1 "release ghostty_dart 9\.9\.9" \
  range EVENT=workflow_dispatch HEAD_REF=other ACTOR="$bot_name"
check "a caller-set DCO_ALLOW_RELEASE_BOT is ignored" 1 "release ghostty_dart 9\.9\.9" \
  range EVENT=workflow_dispatch HEAD_REF=other ACTOR=mallory DCO_ALLOW_RELEASE_BOT=1
git -C "$r" checkout -q pr
check "dispatch checks the branch against origin/main" 0 "all 1 commit" \
  range EVENT=workflow_dispatch HEAD_REF=pr ACTOR=mallory
check "other events are refused" 1 "unsupported event" range EVENT=push

finish
