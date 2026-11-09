#!/usr/bin/env bash
# Resolves the workspace with a plain Dart SDK (no Flutter), for the arm64
# smoke tests, without trusting the resolver to pick versions.
#
# `mise run deps` uses `flutter pub get` because the benchmarks member
# depends on xterm, which needs the Flutter SDK. Where there is no Flutter
# SDK, this script drops that member from the root pubspec, runs
# `dart pub get`, and then fails unless every resolved package version is
# exactly the one in the committed pubspec.lock. Dropping a member only
# removes constraints, so the locked versions still satisfy everything; the
# check proves nothing new or different came in (AGENTS.md cooldown policy):
# every package's whole lock entry (version, source, sha256, hosted url) must
# be unchanged, which is what --enforce-lockfile would prove if it allowed
# removals.
#
# Then it runs the given command, if any, while the trimmed pubspec is still
# in place: restoring pubspec.yaml makes it newer than the resolution, and
# `dart test` would then re-resolve with the Flutter-only member and fail.
# pubspec.yaml and pubspec.lock are restored on exit either way.
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

grep -qE '^  - benchmarks$' "$root/pubspec.yaml" || { echo "error: root pubspec has no '  - benchmarks' workspace entry" >&2; exit 1; }
sed '/^  - benchmarks$/d' "$backup/pubspec.yaml" >"$root/pubspec.yaml"

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
