#!/usr/bin/env bash
# Developer Certificate of Origin check (ADR 0010, CONTRIBUTING).
#
# Every non-merge commit in <base>..<head> needs a `Signed-off-by:` trailer
# whose name and email are the commit's author (`git commit -s` writes it).
# Trailers are read with `git interpret-trailers --parse`, so only the final
# trailer block counts, as git itself defines it; the email compares
# case-insensitively, the name exactly.
#
# Merge commits are skipped on purpose: git or GitHub writes them, their
# parents' commits are each checked (those in the range), and requiring a
# sign-off on "Merge branch 'main'" would only add noise. The residual risk is
# content added inside a merge itself (a conflict resolution or an "evil
# merge"); it is visible in the PR diff that the reviewer approves.
#
# An empty range (no non-merge commit) passes only if <base> and <head> have
# the same tree, i.e. the change merges nothing; otherwise the content came
# in through merge commits alone and nobody certified it, so it fails.
#
# One exception, off unless DCO_ALLOW_RELEASE_BOT=1: release-please's commits,
# authored by github-actions[bot] with GITHUB_TOKEN, carry the maintainer's
# sign-off from the `signoff` of release-please-config.json (the maintainer
# certifies them by merging). tool/dco_range.sh sets the variable only for
# the run that release-please.yml dispatches on its own branch, never for a
# pull_request run, so a contributor cannot forge such a commit into a PR.
#
# Exit status: 0 when every commit passes, 1 otherwise (including a bad
# argument or a ref missing from the checkout).
# Needs only bash, coreutils, sed and git (the DCO job installs no tools).
#
# Usage: tool/check_dco.sh <base> <head>
#   e.g. tool/check_dco.sh origin/main HEAD   (also: mise run dco)
#   DCO_BASE_LABEL names <base> in the fix hint (CI passes SHAs).
#   REPO_ROOT overrides the repository (tests).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tool/lib.sh
source "$root/tool/lib.sh"
base="${1:-}"
head="${2:-}"
[[ -n "$base" && -n "$head" ]] || die "usage: check_dco.sh <base> <head>"
repo="${REPO_ROOT:-$root}"

bot='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
bot_signoff=
if [[ "${DCO_ALLOW_RELEASE_BOT:-}" == 1 && -f "$repo/release-please-config.json" ]]; then
  bot_signoff="$(tr -d '\r' <"$repo/release-please-config.json" |
    sed -n -E 's/^[[:space:]]*"signoff":[[:space:]]*"([^"]+)".*$/\1/p' | head -n 1)"
fi

lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

# same_identity <a> <b>: "Name <email>" pairs, name exact, email any case.
same_identity() {
  [[ "${1% <*}" == "${2% <*}" ]] && [[ "$(lower "${1##* <}")" == "$(lower "${2##* <}")" ]]
}

for ref in "$base" "$head"; do
  git -C "$repo" rev-parse --verify --quiet "$ref^{commit}" >/dev/null ||
    die "'$ref' is not a commit in this checkout (fetch-depth: 0?)"
done

commits="$(git -C "$repo" rev-list --no-merges --reverse "$base..$head")"
total=0
bad=()
while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  total=$((total + 1))
  author="$(git -C "$repo" show -s --format='%an <%ae>' "$c")"
  signoffs="$(git -C "$repo" show -s --format=%B "$c" | git -C "$repo" interpret-trailers --parse |
    sed -n -E 's/^[Ss][Ii][Gg][Nn][Ee][Dd]-[Oo][Ff][Ff]-[Bb][Yy]:[[:space:]]*//p')"
  ok=false
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if same_identity "$s" "$author"; then ok=true; break; fi
    if [[ "$author" == "$bot" && -n "$bot_signoff" && "$s" == "$bot_signoff" ]]; then ok=true; break; fi
  done <<<"$signoffs"
  if [[ "$ok" != true ]]; then
    bad+=("$(git -C "$repo" show -s --format='%h %s' "$c") (author: $author)")
  fi
done <<<"$commits"

if [[ "$total" -eq 0 ]]; then
  if git -C "$repo" diff --quiet "$base" "$head" --; then
    echo "DCO: $base..$head has no commits and changes nothing: nothing to certify"
    exit 0
  fi
  die "DCO: $base..$head changes files but has no non-merge commit to certify them (merge commits only)"
fi

if [[ ${#bad[@]} -eq 0 ]]; then
  echo "DCO: all $total commit(s) in $base..$head are signed off by their author"
  exit 0
fi

{
  echo "DCO: ${#bad[@]} of $total commit(s) lack a 'Signed-off-by:' matching their author:"
  printf '  %s\n' "${bad[@]}"
  cat <<EOF

Each commit needs the trailer 'Signed-off-by: <author name> <author email>'
(the Developer Certificate of Origin, https://developercertificate.org/).
To fix, with git user.name and user.email set to the commits' author:
  git rebase --signoff ${DCO_BASE_LABEL:-$base}   # signs off every commit of the branch
  git push --force-with-lease
For the last commit only: git commit --amend --signoff --no-edit
From now on: git commit -s
EOF
} >&2
exit 1
