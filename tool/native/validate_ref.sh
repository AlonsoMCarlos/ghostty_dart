#!/usr/bin/env bash
# Decides whether a native-release.yml run publishes, and validates the ref
# when it does. Prints `publish=<true|false>` and `tag=<tag or empty>`
# (appended to $GITHUB_OUTPUT when set).
#
# Publishing happens for a tag push, or a manual dispatch with `publish`
# ticked, never for a pull request. It then requires:
#   - a tag ref named native-v<version in native/upstream.json>-r<n>, n >= 1;
#   - the tagged commit (HEAD of the checkout) reachable from origin/main, so
#     only reviewed code is ever released (the checkout needs fetch-depth 0).
#
# Inputs (environment, as GitHub provides them): EVENT, REF_TYPE, REF_NAME,
# PUBLISH_INPUT ("true" when ticked).
# Usage: tool/native/validate_ref.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"
version="$(jq_raw .version "$root/native/upstream.json")"

publish=false
case "${EVENT:?}" in
  push) publish=true ;;
  workflow_dispatch) [[ "${PUBLISH_INPUT:-false}" == true ]] && publish=true ;;
esac

tag=
if [[ "$publish" == true ]]; then
  pattern="^native-v${version//./\\.}-r[1-9][0-9]*\$"
  if [[ "${REF_TYPE:-}" != tag ]] || ! [[ "${REF_NAME:-}" =~ $pattern ]]; then
    echo "error: publishing needs a tag native-v$version-r<n> (native/upstream.json); got ${REF_TYPE:-?} '${REF_NAME:-}'" >&2
    exit 1
  fi
  require_on_main "$root" HEAD "$REF_NAME"
  tag="$REF_NAME"
  echo "will publish $tag ($(git -C "$root" rev-parse HEAD), on main)" >&2
else
  echo "no publishing ($EVENT on ${REF_TYPE:-?} '${REF_NAME:-}'): build, check and smoke-test only" >&2
fi

write_outputs "publish=$publish" "tag=$tag"
