#!/usr/bin/env bash
# Uploads a checked publish archive to pub.dev with GitHub's OIDC token
# (ADR 0010, publish.yml `publish` job). Runs only inside GitHub Actions: the
# first, manual publish is a plain `dart pub publish`
# (docs/internal/release-checklist.md), and a local run must never publish by
# accident.
#
# Credentials, the steps of dart-lang/setup-dart's OIDC setup
# (6afc89df92d6eb3834022f73cd65adc8cdfcb92d = v1.8.1, lib/main.dart,
# createPubOIDCToken, with @actions/core getIDToken), done here so that only
# the pinned, sha256-verified Dart ($DART) ever sees the token:
#   1. GET $ACTIONS_ID_TOKEN_REQUEST_URL&audience=https%3A%2F%2Fpub.dev with
#      `Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN` (the job needs
#      id-token: write); the token is the JSON `value`.
#   2. Mask it (`::add-mask::`, what core.setSecret does).
#   3. PUB_TOKEN=<token> and `dart pub token add https://pub.dev --env-var
#      PUB_TOKEN`: pub-tokens.json records only the variable's name.
# Unlike setup-dart, the token is never exported to $GITHUB_ENV: it exists
# only in this process, for the token registration and the upload.
#
# The upload: `dart pub publish --from-archive=<file> --force` (hidden flags;
# dart-lang/pub ec276d10a7fa0f6c6ec005340fb9ad29f3b012d0, the pub of Dart
# 3.13.7, lib/src/command/lish.dart) sends the archive as is, without reading
# any package from disk, which is why it runs from an empty directory.
#
# Needs curl and jq. Usage: tool/release/upload.sh <archive.tar.gz>
set -euo pipefail

archive="${1:-}"
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tool/release/lib.sh
source "$here/lib.sh"

[[ -n "$archive" ]] || die "usage: upload.sh <archive.tar.gz>"
[[ "${GITHUB_ACTIONS:-}" == true ]] || die "upload.sh publishes to pub.dev and runs only in publish.yml; publish by hand with 'dart pub publish'"
[[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] ||
  die "no OIDC token request variables: the job needs permissions: id-token: write"
[[ -s "$archive" ]] || die "$archive is missing or empty"
archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
dart="${DART:-}"
[[ -n "$dart" && -x "$dart" ]] || die "DART must point at the pinned, verified Dart (mise run native:dart-sdk)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The request token goes through a header file, not curl's argv.
(umask 077 && printf 'Authorization: Bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" >"$work/auth")
response="$(curl -sSf --proto '=https' --retry 3 -H @"$work/auth" -H 'Accept: application/json' \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https%3A%2F%2Fpub.dev")" || die "the OIDC token request failed"
rm -f "$work/auth"
token="$(jq -r '.value // empty' <<<"$response")"
[[ -n "$token" ]] || die "the OIDC token response has no value"
echo "::add-mask::$token"
export PUB_TOKEN="$token"
unset token response

cd "$work"
"$dart" --version >&2
"$dart" pub token add https://pub.dev --env-var PUB_TOKEN
"$dart" pub publish --from-archive="$archive" --force
