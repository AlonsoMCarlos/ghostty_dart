#!/usr/bin/env bash
# Prints the Markdown release notes of a native release. Every fact comes from
# its source of truth rather than being restated: upstream version and commit
# (native/upstream.json), release zig args, platform floors and targets
# (native/prebuilt_assets.json), pinned NDK and Xcode (native/toolchain.json),
# hashes (<dist>/SHA256SUMS), and the runner image and toolchain each asset
# was really built with (<buildinfo>, written by release_asset.sh).
#
# Usage: tool/native/release_notes.sh <tag> <dist> <buildinfo> <windows-arm64 smoke outcome> <run url>
set -euo pipefail

tag="${1:?usage: release_notes.sh <tag> <dist> <buildinfo> <outcome> <run url>}"
dist="${2:?}"
buildinfo="${3:?}"
win_arm64="${4:-unknown}"
run_url="${5:?}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"
upstream="$root/native/upstream.json"
assets="$root/native/prebuilt_assets.json"
toolchain="$root/native/toolchain.json"
repo="${GITHUB_REPOSITORY:-AlonsoMCarlos/ghostty_dart}"

cat <<EOF
Prebuilt libghostty-vt $(jq_raw .version "$upstream") binaries for the \`ghostty_dart\` build hook.

- Upstream: libghostty-vt $(jq_raw .version "$upstream") (tag \`$(jq_raw .tag "$upstream")\`, commit \`$(jq_raw .commit "$upstream")\`), built from the minisign-verified source tarball, offline.
- Zig $(jq_raw .zig_version "$upstream"), \`-Doptimize=ReleaseFast $(jq_raw '.release_zig_args | join(" ")' "$assets")\`.
- Floors: glibc $(jq_raw .floors.glibc "$assets"), Android API $(jq_raw .floors.android_api "$assets") (NDK $(jq_raw '.android_ndk | "\(.release), \(.revision)"' "$toolchain") sysroot), macOS $(jq_raw .floors.macos "$assets"), iOS $(jq_raw .floors.ios "$assets"). Apple dylibs are linked by Xcode $(jq_raw '.xcode | "\(.version) (\(.build))"' "$toolchain").
- Every non-Apple asset was built twice in independent jobs; both builds are bit-identical.
- Smoke tests (the full Dart suite against these files): Linux x64/arm64, macOS arm64/x64, Windows x64. Windows arm64 (best effort): **$win_arm64**.
- Workflow run: $run_url

| Asset | Zig target | sha256 | Built on |
|---|---|---|---|
EOF
while read -r hash asset; do
  target="$(asset_field "$root" "$asset" zig_target)"
  # The runner image and toolchain of the first (published) build.
  built_on="$(awk -F'\t' -v a="$asset" '$1 == a { print $3 "; " $4; exit }' "$buildinfo")"
  echo "| \`$asset\` | \`$target\` | \`$hash\` | ${built_on:-unknown} |"
done <"$dist/SHA256SUMS"

cat <<EOF

## Verify

\`\`\`sh
gh attestation verify <file> --repo $repo \\
  --signer-workflow $repo/.github/workflows/native-build.yml \\
  --source-ref refs/tags/$tag --deny-self-hosted-runners
sha256sum -c SHA256SUMS
\`\`\`
EOF
