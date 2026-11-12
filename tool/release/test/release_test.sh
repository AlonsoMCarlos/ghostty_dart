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
check "validate_tag: the tag names its package" 0 "^package=ghostty_dart$" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.0
check "validate_tag: dispatch on the tag passes" 0 "^tag=ghostty_dart-v0\.1\.0$" vt EVENT=workflow_dispatch REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.0
check "validate_tag: a branch ref is refused" 1 "needs a tag ref" vt EVENT=workflow_dispatch REF_TYPE=branch REF_NAME=main
check "validate_tag: other events are refused" 1 "only on push or workflow_dispatch" vt EVENT=release REF_TYPE=tag REF_NAME=ghostty_dart-v0.1.0
check "validate_tag: another tag family is refused" 1 "'native' is not a package this pipeline publishes" vt EVENT=push REF_TYPE=tag REF_NAME=native-v1.0.0-r1
check "validate_tag: a package outside the allow-list is refused" 1 "'ghostty_dart_xterm' is not a package this pipeline publishes" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart_xterm-v0.1.0
check "validate_tag: a tag that is not <package>-v<version> is refused" 1 "is not a <package>-v<X.Y.Z> tag" vt EVENT=push REF_TYPE=tag REF_NAME=v0.1.0
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

# The second package: its tag alone selects packages/ghostty_dart_flutter.
mkdir -p "$r/packages/ghostty_dart_flutter"
printf 'name: ghostty_dart_flutter\nversion: 0.1.0\n' >"$r/packages/ghostty_dart_flutter/pubspec.yaml"
printf '## 0.1.0\n\n- Initial release.\n' >"$r/packages/ghostty_dart_flutter/CHANGELOG.md"
git -C "$r" add -A && commit "$r" "chore: release ghostty_dart_flutter 0.1.0" -s
git -C "$r" tag ghostty_dart_flutter-v0.1.0
git -C "$r" update-ref refs/remotes/origin/main HEAD
check "validate_tag: the widget's tag passes" 0 "^package=ghostty_dart_flutter$" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart_flutter-v0.1.0
check "validate_tag: the widget's tag gives its version" 0 "^version=0\.1\.0$" vt EVENT=workflow_dispatch REF_TYPE=tag REF_NAME=ghostty_dart_flutter-v0.1.0
git -C "$r" tag ghostty_dart_flutter-v0.1.1
check "validate_tag: the widget's tag does not read the other package" 1 "packages/ghostty_dart_flutter/pubspec.yaml has version '0.1.0'" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart_flutter-v0.1.1
printf 'name: ghostty_dart\nversion: 0.1.2\n' >"$r/packages/ghostty_dart_flutter/pubspec.yaml"
printf '## 0.1.2\n' >"$r/packages/ghostty_dart_flutter/CHANGELOG.md"
git -C "$r" add -A && commit "$r" "chore: wrong name" -s
git -C "$r" tag ghostty_dart_flutter-v0.1.2
git -C "$r" update-ref refs/remotes/origin/main HEAD
check "validate_tag: a pubspec named for another package fails" 1 "pubspec.yaml is named 'ghostty_dart'" vt EVENT=push REF_TYPE=tag REF_NAME=ghostty_dart_flutter-v0.1.2

# ------------------------------------------------------ release_ready
r="$tmp/ready"
new_repo "$r"
git -C "$r" tag native-v1.0.0-r1
ready() { REPO_ROOT="$r" bash "$root/tool/release/release_ready.sh"; }
check "release_ready: false before any package tag" 0 "^ready=false$" ready
git -C "$r" tag ghostty_dart-v0.1
git -C "$r" tag ghostty_dart-v0.1.0-dev.1
check "release_ready: a typo or prerelease tag does not count" 0 "^ready=false$" ready
git -C "$r" tag ghostty_dart-v0.1.0
check "release_ready: still false while the widget has no tag" 0 "^ready=false$" ready
check "release_ready: names the package without a tag" 0 "skipped until ghostty_dart_flutter has" ready
git -C "$r" tag ghostty_dart_flutter-v0.1.0-dev.1
git -C "$r" tag ghostty_dart_xterm-v0.1.0
check "release_ready: a widget prerelease or another package's tag does not count" 0 "^ready=false$" ready
git -C "$r" tag ghostty_dart_flutter-v0.1.0
check "release_ready: true once every package has a <package>-v<X.Y.Z> tag" 0 "^ready=true$" ready

# ------------------------------------------------------ check_archive
a="$tmp/archive"
mkdir -p "$a/pkg/lib"
printf 'name: ghostty_dart\nversion: 0.1.1\n' >"$a/pkg/pubspec.yaml"
touch "$a/pkg/lib/x.dart" "$a/outside"
tar -czf "$a/good.tar.gz" -C "$a/pkg" pubspec.yaml lib
sha="$(sha256_of "$a/good.tar.gz")"
ca() { bash "$root/tool/release/check_archive.sh" "$@"; }
check "check_archive: the packaged bytes pass" 0 "verified" ca "$a/good.tar.gz" "$sha" ghostty_dart-v0.1.1
check "check_archive: another sha256 fails" 1 "differs from the packaged" ca "$a/good.tar.gz" "0000" ghostty_dart-v0.1.1
check "check_archive: another version fails" 1 "not 0.1.2" ca "$a/good.tar.gz" "$sha" ghostty_dart-v0.1.2
check "check_archive: another package's tag fails" 1 "name is 'ghostty_dart', not ghostty_dart_flutter" ca "$a/good.tar.gz" "$sha" ghostty_dart_flutter-v0.1.1
check "check_archive: a tag outside the allow-list fails" 1 "not a <package>-v<X.Y.Z> tag of a published package" ca "$a/good.tar.gz" "$sha" ghostty_dart_xterm-v0.1.1
check "check_archive: a bare version fails" 1 "not a <package>-v<X.Y.Z> tag" ca "$a/good.tar.gz" "$sha" 0.1.1
mkdir -p "$a/widget/lib"
printf 'name: ghostty_dart_flutter\nversion: 0.1.0\n' >"$a/widget/pubspec.yaml"
touch "$a/widget/lib/w.dart"
tar -czf "$a/widget.tar.gz" -C "$a/widget" pubspec.yaml lib
check "check_archive: the widget's archive passes with its tag" 0 "verified .*: ghostty_dart_flutter 0\.1\.0" ca "$a/widget.tar.gz" "$(sha256_of "$a/widget.tar.gz")" ghostty_dart_flutter-v0.1.0
(cd "$a/pkg" && tar -P -czf "$a/escape.tar.gz" pubspec.yaml lib ../outside)
check "check_archive: a '..' path fails" 1 "absolute or '\.\.' path" ca "$a/escape.tar.gz" "$(sha256_of "$a/escape.tar.gz")" ghostty_dart-v0.1.1
printf 'name: ghostty_dart\nversion: 0.1.1\npublish_to: none\n' >"$a/pkg/pubspec.yaml"
tar -czf "$a/private.tar.gz" -C "$a/pkg" pubspec.yaml lib
check "check_archive: publish_to fails" 1 "sets publish_to" ca "$a/private.tar.gz" "$(sha256_of "$a/private.tar.gz")" ghostty_dart-v0.1.1
tar -czf "$a/nopubspec.tar.gz" -C "$a/pkg" lib
check "check_archive: no pubspec fails" 1 "no top-level pubspec" ca "$a/nopubspec.tar.gz" "$(sha256_of "$a/nopubspec.tar.gz")" ghostty_dart-v0.1.1

# ------------------------------------------------------------ package
bin="$tmp/bin"
stub "$bin" dart 'for a in "$@"; do case "$a" in --to-archive=*) printf archive >"${a#--to-archive=}" ;; esac; done
printf "%s\n" "$*" >>"'"$tmp"'/dart-package.log"'
pkg() { env "$@" bash "$root/tool/release/package.sh" ghostty_dart-v0.1.0 "$tmp/out/a.tar.gz"; }
check "package: no argument fails" 1 "usage: package.sh" bash "$root/tool/release/package.sh"
check "package: a tag outside the allow-list fails" 1 "not a <package>-v<X.Y.Z> tag of a published package" \
  env CI= DART="$bin/dart" bash "$root/tool/release/package.sh" ghostty_dart_xterm-v0.1.0 "$tmp/out/x.tar.gz"
check "package: a prerelease tag fails" 1 "not a <package>-v<X.Y.Z> tag" \
  env CI= DART="$bin/dart" bash "$root/tool/release/package.sh" ghostty_dart_flutter-v0.1.0-dev.1 "$tmp/out/x.tar.gz"
check "package: nothing ran for them" 1 "" test -e "$tmp/dart-package.log"
check "package: a missing dart fails" 1 "dart not found" pkg CI= DART="$tmp/none/dart"
check "package: writes the archive and prints its sha256" 0 "^sha256=$(printf archive | sha256sum | cut -d' ' -f1)$" pkg CI= DART="$bin/dart"
# The repo root's spelling depends on how bash was started (on Windows mise
# may hand it D:/... or /d/...), so match the flags and the package dir apart.
check "package: runs pub with --to-archive and --skip-validation" 0 "pub publish --to-archive=$tmp/out/a.tar.gz --skip-validation --directory=" cat "$tmp/dart-package.log"
check "package: publishes the ghostty_dart package dir" 0 "/packages/ghostty_dart$" cat "$tmp/dart-package.log"
rm -f "$tmp/dart-package.log"
check "package: the widget's tag packages the widget" 0 "packaged ghostty_dart_flutter" \
  env CI= DART="$bin/dart" bash "$root/tool/release/package.sh" ghostty_dart_flutter-v0.1.0 "$tmp/out/w.tar.gz"
check "package: publishes the ghostty_dart_flutter package dir" 0 "/packages/ghostty_dart_flutter$" cat "$tmp/dart-package.log"

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
git -C "$o" tag ghostty_dart_flutter-v0.1.0
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
check "dispatch: refuses a non-release tag" 1 "is not a <package>-v<X.Y.Z> tag" disp publish 'ghostty_dart-v0.1.1;x'
check "dispatch: refuses a branch as tag" 1 "is not a <package>-v<X.Y.Z> tag" disp publish main
check "dispatch: refuses a tag of a package outside the allow-list" 1 "is not a <package>-v<X.Y.Z> tag of a published package" disp publish ghostty_dart_xterm-v0.1.1
rm -f "$tmp/gh.log"
check "dispatch: publish runs on the widget's tag of main" 0 "dispatched publish.yml on ghostty_dart_flutter-v0.1.0" disp publish ghostty_dart_flutter-v0.1.0
check "dispatch: gh got the widget's tag ref" 0 "^gh workflow run publish.yml --ref ghostty_dart_flutter-v0.1.0$" cat "$tmp/gh.log"
check "dispatch: pr runs ci and dco on release-please's branch" 0 "dispatched ci.yml and dco.yml" disp pr release-please--branches--main--components--ghostty_dart
check "dispatch: gh got both workflows" 0 "^gh workflow run dco.yml --ref release-please--branches--main--components--ghostty_dart$" cat "$tmp/gh.log"
check "dispatch: refuses other branches" 1 "not a release-please branch" disp pr release-please--branches--main
check "dispatch: pr runs on the widget's release branch" 0 "dispatched ci.yml and dco.yml" disp pr release-please--branches--main--components--ghostty_dart_flutter
check "dispatch: refuses the branch of a component outside the allow-list" 1 "not a release-please branch" disp pr release-please--branches--main--components--ghostty_dart_xterm

# ------------------------------- allow-list = release-please components
# tool/release/lib.sh's allow-list, the components and paths of
# release-please-config.json and the manifest's keys must be the same set,
# or release_ready.sh would gate on a package release-please does not run
# (or miss one it does). Read with sed: the release jobs have no jq.
# shellcheck source=tool/release/lib.sh
source "$root/tool/release/lib.sh"
allow="$(printf '%s\n' "${release_packages[@]}" | sort)"
components="$(sed -n -E 's/^[[:space:]]*"component":[[:space:]]*"([^"]+)".*$/\1/p' "$root/release-please-config.json" | sort)"
paths="$(sed -n -E 's#^[[:space:]]*"packages/([^"]+)":[[:space:]]*\{.*$#\1#p' "$root/release-please-config.json" | sort)"
manifest="$(sed -n -E 's#^[[:space:]]*"packages/([^"]+)":[[:space:]]*"[^"]+".*$#\1#p' "$root/.release-please-manifest.json" | sort)"
check "release-please components equal the allow-list (${allow//$'\n'/ })" 0 "" test "$components" = "$allow"
check "release-please package paths equal the allow-list" 0 "" test "$paths" = "$allow"
check "manifest packages equal the allow-list" 0 "" test "$manifest" = "$allow"
for p in "${release_packages[@]}"; do
  check "publish.yml triggers on $p-v* tags" 0 "" grep -qF "'$p-v*'" "$root/.github/workflows/publish.yml"
  check "release-please.yml dispatches publish.yml for $p" 0 "" grep -qF "outputs['packages/$p--tag_name']" "$root/.github/workflows/release-please.yml"
done

# ------------------------------------------------ workflows: mise version
versions="$(sed -n -E 's/^[[:space:]]*(MISE_VERSION|version):[[:space:]]*([0-9]{4}\.[0-9]+\.[0-9]+).*$/\2/p' "$root"/.github/workflows/*.yml | sort -u)"
count="$(grep -c . <<<"$versions" || true)"
check "workflows: one mise version everywhere (${versions//$'\n'/ })" 0 "" test "$count" = 1

finish
