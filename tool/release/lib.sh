# shellcheck shell=bash
# Release specifics for tool/release/*.sh (ADR 0010). Source it; do not run
# it. It sources tool/lib.sh (die, write_outputs, sha256_of, require_on_main).
# Needs only bash, coreutils, sed and git: the release-please jobs run these
# scripts without installing any tool.

# shellcheck source=tool/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# The packages release-please and publish.yml release: an allow-list, kept
# equal to the components of release-please-config.json (checked by
# test:release). ghostty_dart_xterm is not in it until its first publish
# (docs/internal/release-checklist.md). Each package lives in
# packages/<package> and its tags are `<package>-v<X.Y.Z>`
# (release-please-config.json: component, tag-separator, include-v-in-tag),
# the pattern pub.dev's automated publishing matches per package.
# shellcheck disable=SC2034 # read by the scripts that source this file
release_packages=(ghostty_dart ghostty_dart_flutter)

# is_release_package <name>: true for a package of the allow-list.
is_release_package() {
  local p
  for p in "${release_packages[@]}"; do
    [[ "$1" == "$p" ]] && return 0
  done
  return 1
}

# release_package_dir <package>: its directory, relative to the repo root.
release_package_dir() {
  printf 'packages/%s\n' "$1"
}

# release_pr_branch <package>: release-please's PR branch for it. With
# separate-pull-requests (set in release-please-config.json) it is
# ComponentBranchName, release-please--branches--<target>--components--<component>
# (src/util/branch-name.ts and src/strategies/base.ts, release-please 17.6.0);
# without it, the Merge plugin would use release-please--branches--main.
release_pr_branch() {
  printf 'release-please--branches--main--components--%s\n' "$1"
}

# is_release_pr_branch <branch>: true for the release PR branch of a package
# of the allow-list.
is_release_pr_branch() {
  local p
  for p in "${release_packages[@]}"; do
    [[ "$1" == "$(release_pr_branch "$p")" ]] && return 0
  done
  return 1
}

# pubspec_version <pubspec.yaml>: the `version:` value, without quotes, a
# trailing comment or the CR of a Windows checkout.
pubspec_version() {
  tr -d '\r' <"$1" |
    sed -n -E 's/^version:[[:space:]]*["'\'']?([^"'\''#[:space:]]+)["'\'']?[[:space:]]*(#.*)?$/\1/p' |
    head -n 1
}

# pubspec_name <pubspec.yaml>: the `name:` value.
pubspec_name() {
  tr -d '\r' <"$1" | sed -n -E 's/^name:[[:space:]]*([A-Za-z0-9_]+).*$/\1/p' | head -n 1
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

# release_tag_package <tag>: prints the package of a `<package>-v<rest>` tag
# (a package name has no '-', so the split is unambiguous); fails for any
# other shape. It does not check the allow-list or <rest>: see is_release_tag.
release_tag_package() {
  [[ "$1" =~ ^([a-z][a-z0-9_]*)-v(.+)$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# release_tag_version <tag>: prints the <rest> of a `<package>-v<rest>` tag.
release_tag_version() {
  [[ "$1" =~ ^([a-z][a-z0-9_]*)-v(.+)$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[2]}"
}

# is_release_tag <tag>: true for <package>-v<X.Y.Z> with <package> in the
# allow-list.
is_release_tag() {
  local package version
  package="$(release_tag_package "$1")" || return 1
  version="$(release_tag_version "$1")" || return 1
  is_release_package "$package" && is_release_version "$version"
}
