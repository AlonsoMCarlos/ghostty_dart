# shellcheck shell=bash
# Tiny test harness for the repo's bash test scripts (tool/check_dco_test.sh,
# tool/release/test/release_test.sh). Source it; do not run it.
# It isolates git from the user's configuration and gives every test a
# throwaway directory ($tmp), removed on exit.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passed=0
failed=0

# check <name> <expected exit code> <expected output ERE|''> <command...>:
# runs the command, comparing its exit code and its stdout+stderr.
check() {
  local name="$1" want="$2" pattern="$3" got=0 out
  shift 3
  out="$("$@" 2>&1)" || got=$?
  if [[ "$got" != "$want" ]]; then
    echo "FAIL $name: exit $got, want $want"; printf '%s\n' "$out" | sed 's/^/    /'
    failed=$((failed + 1)); return 0
  fi
  if [[ -n "$pattern" ]] && ! grep -qE -- "$pattern" <<<"$out"; then
    echo "FAIL $name: output lacks /$pattern/"; printf '%s\n' "$out" | sed 's/^/    /'
    failed=$((failed + 1)); return 0
  fi
  echo "ok   $name"
  passed=$((passed + 1))
}

# finish: prints the summary; the status is 1 if any check failed.
finish() {
  echo
  echo "$passed passed, $failed failed"
  [[ "$failed" -eq 0 ]]
}

test_name='Ada Lovelace'
test_email='ada@example.org'

# new_repo <dir>: a repo with one signed-off root commit on main.
new_repo() {
  git init -q -b main "$1"
  git -C "$1" config user.name "$test_name"
  git -C "$1" config user.email "$test_email"
  git -C "$1" config commit.gpgsign false
  git -C "$1" config tag.gpgsign false
  git -C "$1" commit -q --allow-empty -s -m "chore: root"
}

# commit <dir> <message> [git commit args...]: an empty commit.
commit() {
  local dir="$1" msg="$2"
  shift 2
  git -C "$dir" commit -q --allow-empty -m "$msg" "$@"
}

# stub <dir> <name> <body>: an executable <dir>/<name> running <body> in bash.
stub() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\n%s\n' "$3" >"$1/$2"
  chmod +x "$1/$2"
}
