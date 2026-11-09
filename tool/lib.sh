# shellcheck shell=bash
# Generic helpers shared by every repo shell script (tool/native/*,
# tool/release/*, tool/pana/*, the DCO check). Source it; do not run it.
# tool/native/lib.sh and tool/release/lib.sh source it, so their scripts get
# these through their own library.
# Portable: bash 3.2 (macOS), Git Bash, coreutils or BSD tools, git.

# die <message>: prints `error: <message>` to stderr and exits 1.
die() {
  echo "error: $*" >&2
  exit 1
}

# write_outputs <key=value>...: prints the lines and appends them to
# $GITHUB_OUTPUT when it is set (a step's outputs).
write_outputs() {
  printf '%s\n' "$@"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s\n' "$@" >>"$GITHUB_OUTPUT"; fi
}

# sha256_of <file>: prints the lowercase hex sha256 of a file.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# require_on_main <root> <rev> [label]: dies unless <rev> is a commit of the
# checkout at <root> that is reachable from origin/main, so only reviewed
# code is released (the checkout needs fetch-depth: 0).
require_on_main() {
  local root="$1" rev="$2" label="${3:-$2}" commit
  git -C "$root" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null ||
    die "origin/main is not fetched (checkout fetch-depth: 0)"
  commit="$(git -C "$root" rev-parse --verify --quiet "$rev^{commit}")" ||
    die "$label is not in the checkout (fetch-depth: 0 fetches tags)"
  git -C "$root" merge-base --is-ancestor "$commit" refs/remotes/origin/main ||
    die "$label ($commit) is not reachable from main"
}
