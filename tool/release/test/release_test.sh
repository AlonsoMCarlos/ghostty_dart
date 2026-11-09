#!/usr/bin/env bash
# Tests the tool/release/ scripts in throwaway git repos, with no network:
# stubs stand in for gh, curl and dart. Also checks that every workflow pins
# the same mise version. Run with `mise run test:release` (part of
# `mise run check`), or `bash tool/release/test/release_test.sh`.
# shellcheck disable=SC2016 # stub bodies are single-quoted on purpose: they expand when the stub runs
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=tool/test_harness.sh
source "$root/tool/test_harness.sh"
# shellcheck source=tool/lib.sh
source "$root/tool/lib.sh"

# ------------------------------------------------------- validate_tag
r="$tmp/tag"
new_repo "$r"
mkdir -p "$r/packages/ghostty_dart"
printf 'name: ghostty_dart\nversion: 0.1.0\n' >"$r/packages/ghostty_dart/pubspec.yaml"
printf '## 0.1.0\n\n- Initial release.\n' >"$r/packages/ghostty_dart/CHANGELOG.md"
git -C "$r" add -A && commit "$r" "chore: release 0.1.0" -s
git -C "$r" tag ghostty_dart-v0.1.0
git -C "$r" update-ref refs/remotes/origin/main HEAD
vt() { env REPO_ROOT="$r" "$@" bash "$root/tool/release/validate_tag.sh"; }
check "validate_tag: matching tag on main passes" 0 "^version=0\.1\.0$" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.0
check "validate_tag: dispatch on the tag passes" 0 "^tag=ghostty_dart-v0\.1\.0$" vt EVENT=workflow_dispatch REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.0
check "validate_tag: a branch ref is refused" 1 "needs a tag ref" vt EVENT=workflow_dispatch REF_TYPE=branch REF_NAME=main
check "validate_tag: other events are refused" 1 "only on push or workflow_dispatch" vt EVENT=release REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.0
check "validate_tag: another package's tag is refused" 1 "does not start with" vt EVENT=push REF_TYPE=tag REF_NAME=native-v1.0.0-r1
check "validate_tag: prereleases are refused" 1 "not a plain X.Y.Z" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.0-dev.1
git -C "$r" tag ghostty_dart-v0.1.1
check "validate_tag: pubspec mismatch fails" 1 "pubspec.yaml has version '0.1.0'" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.1

printf 'name: ghostty_dart\nversion: "0.1.1" # bumped\n' >"$r/packages/ghostty_dart/pubspec.yaml"
git -C "$r" add -A && commit "$r" "chore: pubspec only" -s
git -C "$r" tag -f ghostty_dart-v0.1.1 >/dev/null
git -C "$r" update-ref refs/remotes/origin/main HEAD
check "validate_tag: CHANGELOG mismatch fails" 1 "CHANGELOG.md is '0.1.0'" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.1

{
  printf '# Changelog\n\n## [0.1.1](https://github.com/o/r/compare/ghostty_dart-v0.1.0...ghostty_dart-v0.1.1) (2026-11-20)\r\n\n'
  printf '### Bug Fixes\n\n## 0.1.0\n'
} >"$r/packages/ghostty_dart/CHANGELOG.md"
git -C "$r" add -A && commit "$r" "chore(main): release ghostty_dart 0.1.1" -s
git -C "$r" tag -f ghostty_dart-v0.1.1 >/dev/null
check "validate_tag: tag not on main fails" 1 "not reachable from main" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.1
git -C "$r" update-ref refs/remotes/origin/main HEAD
check "validate_tag: release-please heading and quoted version pass" 0 "^version=0\.1\.1$" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.1
git -C "$r" checkout -q HEAD~1
check "validate_tag: checkout other than the tagged commit fails" 1 "is not the commit of tag" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.1
git -C "$r" checkout -q main
check "validate_tag: missing tag fails" 1 "not in the checkout" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart-v9.9.9

# ------------------------------------------------------ release_ready
r="$tmp/ready"
new_repo "$r"
git -C "$r" tag native-v1.0.0-r1
ready() { REPO_ROOT="$r" bash "$root/tool/release/release_ready.sh"; }
check "release_ready: false before the first ghostty_dart tag" 0 "^ready=false$" ready
git -C "$r" tag ghostty_dart-v0.1
git -C "$r" tag ghostty_dart-v0.1.0-dev.1
check "release_ready: a typo or prerelease tag does not count" 0 "^ready=false$" ready
git -C "$r" tag ghostty_dart-v0.1.0
check "release_ready: true once ghostty_dart-v<X.Y.Z> exists" 0 "^ready=true$" ready

# ------------------------------------------------------ check_archive
a="$tmp/archive"
mkdir -p "$a/pkg/lib"
printf 'name: ghostty_dart\nversion: 0.1.1\n' >"$a/pkg/pubspec.yaml"
touch "$a/pkg/lib/x.dart" "$a/outside"
tar -czf "$a/good.tar.gz" -C "$a/pkg" pubspec.yaml lib
sha="$(sha256_of "$a/good.tar.gz")"
ca() { bash "$root/tool/release/check_archive.sh" "$@"; }
check "check_archive: the packaged bytes pass" 0 "verified" ca "$a/good.tar.gz" "$sha" 0.1.1
check "check_archive: another sha256 fails" 1 "differs from the packaged" ca "$a/good.tar.gz" "0000" 0.1.1
check "check_archive: another version fails" 1 "not 0.1.2" ca "$a/good.tar.gz" "$sha" 0.1.2
(cd "$a/pkg" && tar -P -czf "$a/escape.tar.gz" pubspec.yaml lib ../outside)
check "check_archive: a '..' path fails" 1 "absolute or '\.\.' path" ca "$a/escape.tar.gz" "$(sha256_of "$a/escape.tar.gz")" 0.1.1
printf 'name: ghostty_dart\nversion: 0.1.1\npublish_to: none\n' >"$a/pkg/pubspec.yaml"
tar -czf "$a/private.tar.gz" -C "$a/pkg" pubspec.yaml lib
check "check_archive: publish_to fails" 1 "sets publish_to" ca "$a/private.tar.gz" "$(sha256_of "$a/private.tar.gz")" 0.1.1
tar -czf "$a/nopubspec.tar.gz" -C "$a/pkg" lib
check "check_archive: no pubspec fails" 1 "no top-level pubspec" ca "$a/nopubspec.tar.gz" "$(sha256_of "$a/nopubspec.tar.gz")" 0.1.1

# ------------------------------------------------------------ package
bin="$tmp/bin"
stub "$bin" dart 'for a in "$@"; do case "$a" in --to-archive=*) printf archive >"${a#--to-archive=}" ;; esac; done
printf "%s\n" "$*" >>"'"$tmp"'/dart-package.log"'
pkg() { env "$@" bash "$root/tool/release/package.sh" "$tmp/out/a.tar.gz"; }
check "package: no argument fails" 1 "usage: package.sh" bash "$root/tool/release/package.sh"
check "package: a missing dart fails" 1 "dart not found" pkg CI= DART="$tmp/none/dart"
check "package: writes the archive and prints its sha256" 0 "^sha256=$(printf archive | sha256sum | cut -d' ' -f1)$" pkg CI= DART="$bin/dart"
# The repo root's spelling depends on how bash was started (on Windows mise
# may hand it D:/... or /d/...), so match the flags and the package dir apart.
check "package: runs pub with --to-archive and --skip-validation" 0 "pub publish --to-archive=$tmp/out/a.tar.gz --skip-validation --directory=" cat "$tmp/dart-package.log"
check "package: publishes the ghostty_dart package dir" 0 "/packages/ghostty_dart" cat "$tmp/dart-package.log"

# ------------------------------------------------------------- upload
up="$tmp/up"
stub "$up" curl 'printf "%s\n" "$*" >"'"$tmp"'/curl.log"; for a in "$@"; do case "$a" in @*) cat "${a#@}" >"'"$tmp"'/curl-header.log" ;; esac; done
printf "{\"value\":\"oidc-tok\"}"'
stub "$up" dart 'printf "%s PUB_TOKEN=%s pwd-empty=%s\n" "$*" "${PUB_TOKEN:-}" "$([[ -z "$(ls -A)" ]] && echo yes || echo no)" >>"'"$tmp"'/dart-upload.log"'
printf 'archive' >"$tmp/a.tar.gz"
oidc=(ACTIONS_ID_TOKEN_REQUEST_URL='https://token.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-secret)
upload() { env PATH="$up:$PATH" "$@" bash "$root/tool/release/upload.sh" "$tmp/a.tar.gz"; }
check "upload: refuses to run outside GitHub Actions" 1 "runs only in publish.yml" upload GITHUB_ACTIONS= "${oidc[@]}" DART="$up/dart"
check "upload: refuses without id-token: write" 1 "id-token: write" upload GITHUB_ACTIONS=true ACTIONS_ID_TOKEN_REQUEST_URL= DART="$up/dart"
check "upload: refuses without the pinned Dart" 1 "DART must point" upload GITHUB_ACTIONS=true "${oidc[@]}" DART=
check "upload: refuses a missing archive" 1 "missing or empty" \
  env PATH="$up:$PATH" GITHUB_ACTIONS=true "${oidc[@]}" DART="$up/dart" bash "$root/tool/release/upload.sh" "$tmp/none.tar.gz"
check "upload: masks the minted token" 0 "^::add-mask::oidc-tok$" upload GITHUB_ACTIONS=true "${oidc[@]}" DART="$up/dart"
check "upload: requests the pub.dev audience" 0 "https://token\.example/x\?api-version=2\.0&audience=https%3A%2F%2Fpub\.dev" cat "$tmp/curl.log"
check "upload: sends the request token as a bearer header" 0 "^Authorization: Bearer req-secret$" cat "$tmp/curl-header.log"
check "upload: keeps the request token out of curl's argv" 1 "" grep -q req-secret "$tmp/curl.log"
check "upload: registers the token by env var name" 0 "^pub token add https://pub\.dev --env-var PUB_TOKEN PUB_TOKEN=oidc-tok" cat "$tmp/dart-upload.log"
check "upload: publishes the archive from an empty dir" 0 "^pub publish --from-archive=$tmp/a\.tar\.gz --force PUB_TOKEN=oidc-tok pwd-empty=yes$" cat "$tmp/dart-upload.log"

# ------------------------------------------------------------ dispatch
o="$tmp/origin"
new_repo "$o"
git -C "$o" tag ghostty_dart-v0.1.1
git -C "$o" checkout -q -b side
commit "$o" "feat: off main" -s
git -C "$o" tag ghostty_dart-v0.1.2
git -C "$o" checkout -q main
c="$tmp/clone"
git clone -q "$o" "$c"
stub "$bin" gh 'printf "gh %s\n" "$*" >>"'"$tmp"'/gh.log"'
disp() { env PATH="$bin:$PATH" REPO_ROOT="$c" GH_TOKEN=x GH_REPO=o/r bash "$root/tool/release/dispatch.sh" "$@"; }
check "dispatch: publish runs on a tag of main" 0 "dispatched publish.yml on ghostty_dart-v0.1.1" disp publish ghostty_dart-v0.1.1
check "dispatch: gh got the tag ref" 0 "^gh workflow run publish.yml --ref ghostty_dart-v0.1.1$" cat "$tmp/gh.log"
rm -f "$tmp/gh.log"
check "dispatch: refuses a tag off main" 1 "ghostty_dart-v0.1.2 \([0-9a-f]+\) is not reachable from main" disp publish ghostty_dart-v0.1.2
check "dispatch: gh was not called for it" 1 "" test -e "$tmp/gh.log"
check "dispatch: refuses a non-release tag" 1 "is not a ghostty_dart-v<X.Y.Z> tag" disp publish 'ghostty_dart-v0.1.1;x'
check "dispatch: refuses a branch as tag" 1 "is not a ghostty_dart-v" disp publish main
check "dispatch: pr runs ci and dco on release-please's branch" 0 "dispatched ci.yml and dco.yml" disp pr release-please--branches--main--components--ghostty_dart
check "dispatch: gh got both workflows" 0 "^gh workflow run dco.yml --ref release-please--branches--main--components--ghostty_dart$" cat "$tmp/gh.log"
check "dispatch: refuses other branches" 1 "not the release-please branch" disp pr release-please--branches--main

# ------------------------------------------------ workflows: mise version
versions="$(sed -n -E 's/^[[:space:]]*(MISE_VERSION|version):[[:space:]]*([0-9]{4}\.[0-9]+\.[0-9]+).*$/\2/p' "$root"/.github/workflows/*.yml | sort -u)"
count="$(grep -c . <<<"$versions" || true)"
check "workflows: one mise version everywhere (${versions//$'\n'/ })" 0 "" test "$count" = 1

finish
