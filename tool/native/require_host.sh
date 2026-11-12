#!/usr/bin/env bash
# Fails fast, with the fix, when the library the root pubspec builds with is
# missing. The root pubspec.yaml sets `hooks: user_defines: ghostty_dart:
# source: path` (`path: .native-cache/host/`), so every flutter/dart command
# that runs ghostty_dart's build hook needs `mise run native:host` first. On
# a fresh clone Flutter only reports "Building native assets failed"; the
# hook's own message is in the verbose log. Every mise task that runs the hook
# depends on this check (`native:require-host`).
#
# Usage: tool/native/require_host.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"

pubspec="$root/pubspec.yaml"
# Someone who switched the root pubspec to `prebuilt` or `system` does not
# need the host build.
if ! grep -Eq '^[[:space:]]+source:[[:space:]]*path([[:space:]]|$)' "$pubspec"; then
  exit 0
fi
dir="$(sed -n -E 's/^[[:space:]]+path:[[:space:]]*([^#[:space:]]+).*$/\1/p' "$pubspec" | head -n 1)"
dir="${dir:-.native-cache/host/}"
[[ "$dir" == /* ]] || dir="$root/${dir%/}"

case "$(host_zig_target)" in
  *-windows-gnu) name=ghostty-vt.dll ;;
  *-macos) name=libghostty-vt.dylib ;;
  *) name=libghostty-vt.so ;;
esac
# `path` may name the library itself or the directory holding it.
lib="$dir"
[[ -d "$dir" || ! "$dir" =~ \.(so|dylib|dll)$ ]] && lib="${dir%/}/$name"

if [[ ! -f "$lib" ]]; then
  {
    echo "error: $lib is missing."
    echo "The root pubspec.yaml builds ghostty_dart against the host library"
    echo "(hooks: user_defines: ghostty_dart: source: path). Build it first with:"
    echo
    echo "  mise run native:host"
    echo
    echo "(after \`mise install\`; it builds libghostty-vt offline with the pinned Zig)."
  } >&2
  exit 1
fi
