# shellcheck shell=bash
# Release specifics for tool/release/*.sh (ADR 0010). Source it; do not run
# it. It sources tool/lib.sh (die, write_outputs, sha256_of, require_on_main).
# Needs only bash, coreutils, sed and git: the release-please jobs run these
# scripts without installing any tool.

# shellcheck source=tool/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# The one package release-please and publish.yml release. Its tags are
# `<package>-v<version>` (release-please-config.json: component, tag-separator,
# include-v-in-tag), the pattern pub.dev's automated publishing matches.
# shellcheck disable=SC2034 # read by the scripts that source this file
release_package=ghostty_dart
# shellcheck disable=SC2034
release_package_dir=packages/ghostty_dart
# shellcheck disable=SC2034
release_tag_prefix="${release_package}-v"
# release-please's PR branch. With separate-pull-requests (set in
# release-please-config.json) it is ComponentBranchName,
# release-please--branches--<target>--components--<component>
# (src/util/branch-name.ts and src/strategies/base.ts, release-please 17.6.0);
# without it, the Merge plugin would use release-please--branches--main.
# shellcheck disable=SC2034
release_pr_branch="release-please--branches--main--components--${release_package}"

# pubspec_version <pubspec.yaml>: the `version:` value, without quotes, a
# trailing comment or the CR of a Windows checkout.
pubspec_version() {
  tr -d '\r' <"$1" |
    sed -n -E 's/^version:[[:space:]]*["'\'']?([^"'\''#[:space:]]+)["'\'']?[[:space:]]*(#.*)?$/\1/p' |
    head -n 1
}

# changelog_version <CHANGELOG.md>: the version of the first `## ` heading,
# in either form the file uses: `## 0.1.0` (hand-written) or
# `## [0.1.1](https://.../compare/...) (2026-11-20)` (release-please).
changelog_version() {
  tr -d '\r' <"$1" |
    sed -n -E '/^## /{s/^## \[?([^] ]+)\]?.*$/\1/p;q;}'
}

# is_release_version <version>: true for a plain X.Y.Z. Prereleases are not
# released while release-please owns the version (its Dart updater mangles
# them, release-please issue #2400; ADR 0010).
is_release_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

# is_release_tag <tag>: true for ghostty_dart-v<X.Y.Z>.
is_release_tag() {
  [[ "$1" == "$release_tag_prefix"* ]] && is_release_version "${1#"$release_tag_prefix"}"
}
