#!/usr/bin/env bash
# Resolves the workspace with a plain Dart SDK (no Flutter), for the arm64
# smoke tests, without trusting the resolver to pick versions.
#
# `mise run deps` uses `flutter pub get` because some members need the
# Flutter SDK: benchmarks (it depends on xterm) and ghostty_dart_flutter.
# Where there is no Flutter SDK, this script drops those members from the
# root pubspec, runs `dart pub get`, and then fails unless every resolved
# package version is exactly the one in the committed pubspec.lock.
# Dropping a member only removes constraints, so the locked versions still satisfy everything; the
# check proves nothing new or different came in (AGENTS.md cooldown policy):
# every package's whole lock entry (version, source, sha256, hosted url) must
# be unchanged, which is what --enforce-lockfile would prove if it allowed
# removals.
#
# Then it runs the given command, if any, while the trimmed pubspec is still
# in place: restoring pubspec.yaml makes it newer than the resolution, and
# `dart test` would then re-resolve with the Flutter-only member and fail.
# pubspec.yaml and pubspec.lock are restored on exit either way, but
# .dart_tool/package_config.json keeps the resolution without the Flutter
# members: run `mise run deps` before working on them again.
#
# Usage: tool/native/pub_get_without_flutter.sh [command...]   (`dart` on PATH)
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
backup="$(mktemp -d)"
cp "$root/pubspec.yaml" "$root/pubspec.lock" "$backup/"
restore() {
  cp "$backup/pubspec.yaml" "$backup/pubspec.lock" "$root/"
  rm -rf "$backup"
}
trap restore EXIT

# One line per locked package: `<name>\t<its stanza>`, the stanza being every
# line of its entry (description: name, sha256, url; source; version) except
# `dependency:`, which legitimately changes from "direct" to "transitive" when
# a member is dropped. pubspec.lock is generated YAML with a fixed layout: a
# two-space package key, then four-space-or-deeper lines.
locked_stanzas() {
  tr -d '\r' <"$1" | awk '
    function flush() { if (name != "") print name "\t" stanza; name = ""; stanza = "" }
    /^packages:$/ { inside = 1; next }
    /^[^ ]/ { flush(); inside = 0; next }
    inside && /^  [^ ][^:]*:$/ { flush(); name = $1; sub(":$", "", name); next }
    inside && name != "" && /^    / && $1 != "dependency:" { stanza = stanza "|" $0 }
    END { flush() }' | LC_ALL=C sort
}

flutter_members=(benchmarks packages/ghostty_dart_flutter)
cp "$backup/pubspec.yaml" "$root/pubspec.yaml"
for member in "${flutter_members[@]}"; do
  grep -qxF "  - $member" "$root/pubspec.yaml" || { echo "error: root pubspec has no '  - $member' workspace entry" >&2; exit 1; }
  # grep exits 1 when no line is left (fine) and 2 on an I/O error (not).
  grep -vxF "  - $member" "$root/pubspec.yaml" >"$backup/trimmed" || [[ $? -eq 1 ]]
  cp "$backup/trimmed" "$root/pubspec.yaml"
done

(cd "$root" && dart pub get)

# Every package still resolved must have exactly its committed stanza.
changed="$(comm -13 <(locked_stanzas "$backup/pubspec.lock") <(locked_stanzas "$root/pubspec.lock"))"
if [[ -n "$changed" ]]; then
  echo "error: resolution without Flutter differs from the committed pubspec.lock for:" >&2
  printf '%s\n' "$changed" | cut -f1 | sed 's/^/  /' >&2
  exit 1
fi
echo "resolved $(locked_stanzas "$root/pubspec.lock" | wc -l | tr -d ' ') packages, each exactly as locked (version, source, sha256, url)"

if [[ $# -gt 0 ]]; then "$@"; fi
