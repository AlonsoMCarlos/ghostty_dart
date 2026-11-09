# shellcheck shell=bash
# Shared helpers for tool/native/*.sh. Source it; do not run it.
# Portable across Linux, macOS (no sha256sum) and Windows Git Bash (CRLF jq).

# The generic helpers (die, write_outputs, sha256_of, require_on_main) live in
# tool/lib.sh, shared with tool/release/*.
# shellcheck source=tool/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# jq_raw <filter> <file> [jq args...]: raw jq output without the CR that the
# native Windows jq adds to each line.
jq_raw() {
  local filter="$1" file="$2"; shift 2
  jq -r "$@" "$filter" "$file" | tr -d '\r'
}

# native_path <path>: the path in the form native (non-MSYS) programs such as
# zig expect. Identity outside Windows.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

# host_zig_target: the Zig target triple of this machine, matching what the
# hook resolves for the host (glibc on Linux, gnu ABI on Windows: upstream's
# tier-1 Windows target, loadable by the Dart VM like any DLL).
host_zig_target() {
  local os arch
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=aarch64 ;;
    *) echo "error: unsupported host architecture $(uname -m)" >&2; return 1 ;;
  esac
  case "$(uname -s)" in
    Linux) os=linux-gnu ;;
    Darwin) os=macos ;;
    MINGW* | MSYS* | CYGWIN*) os=windows-gnu ;;
    *) echo "error: unsupported host OS $(uname -s)" >&2; return 1 ;;
  esac
  printf '%s-%s\n' "$arch" "$os"
}

# Helpers below that are used inside $(...) end every step in `|| return 1`:
# bash 3.2 does not apply `set -e` in command substitutions.

# fetch_verified <url> <dest> <sha256>: makes <dest> a verified copy of <url>.
# An existing <dest> is reused only if it still has the pinned hash (it is
# re-hashed on every call, so a local cache is never trusted blindly); a
# download goes to <dest>.part and is promoted only after it verifies.
fetch_verified() {
  local url="$1" dest="$2" pinned="$3" actual
  if [[ -f "$dest" ]] && [[ "$(sha256_of "$dest")" == "$pinned" ]]; then return 0; fi
  echo "downloading $url" >&2
  curl -sSfL --proto '=https' "$url" -o "$dest.part" || return 1
  actual="$(sha256_of "$dest.part")" || return 1
  if [[ "$actual" != "$pinned" ]]; then
    rm -f "$dest.part"
    echo "error: ${dest##*/}: sha256 $actual differs from pinned $pinned" >&2
    return 1
  fi
  mv "$dest.part" "$dest"
}

# extract_upstream_src <root> <dest>: verifies the pinned upstream tarballs
# (minisign + pinned sha256, every call) and extracts them into the new,
# empty directory <dest>, printing the source directory. The deps directory
# sits next to it with a `-deps` suffix.
#
# Always a fresh extraction: an extracted tree is never reused, because
# nothing could prove it still matches the verified tarball (a restored cache
# or a stale checkout could have changed any file).
extract_upstream_src() {
  local root="$1" dest="$2" version cache
  version="$(jq_raw .version "$root/native/upstream.json")" || return 1
  cache="$root/.native-cache"
  "$root/tool/native/fetch_upstream.sh" >/dev/null || return 1
  mkdir -p "$dest" || return 1
  if [[ -n "$(ls -A "$dest")" ]]; then echo "error: $dest is not empty" >&2; return 1; fi
  # Git Bash's GNU tar reads `D:/...` as host `D` plus a remote path;
  # --force-local stops that. macOS bsdtar does not know the flag.
  local local_flag=()
  if command -v cygpath >/dev/null 2>&1; then local_flag=(--force-local); fi
  tar ${local_flag[@]+"${local_flag[@]}"} -xzf "$cache/libghostty-vt-$version.tar.gz" -C "$dest" || return 1
  tar ${local_flag[@]+"${local_flag[@]}"} -xzf "$cache/libghostty-vt-$version-deps.tar.gz" -C "$dest" || return 1
  printf '%s\n' "$dest/libghostty-vt-$version"
}

# build_work_dir <root>: a new empty directory for one build, printed as a
# physical path (symlinks resolved). Zig's build runner passes generator
# steps paths relative to their cwd, which breaks in two cases a system temp
# dir hits: on macOS `/var` is a symlink to `/private/var`, so `..` resolves
# differently than the logical path Zig computed; on Windows the temp dir is
# on C: while the checkout may be on D:, and no relative path crosses drives.
# A dir under the checkout avoids both.
build_work_dir() {
  local base="$1/.native-cache/tmp" dir
  mkdir -p "$base" || return 1
  dir="$(mktemp -d "$base/build.XXXXXX")" || return 1
  (cd "$dir" && pwd -P)
}

# asset_field <root> <asset> <field>: a field of a release asset in
# native/prebuilt_assets.json, or empty when unset. Fails on unknown assets.
asset_field() {
  local manifest="$1/native/prebuilt_assets.json"
  # shellcheck disable=SC2016 # $a is a jq variable, bound with --arg
  if [[ -z "$(jq_raw '.assets[$a] // empty | "x"' "$manifest" --arg a "$2")" ]]; then
    echo "error: unknown release asset '$2' (see native/prebuilt_assets.json)" >&2
    return 1
  fi
  # shellcheck disable=SC2016 # $a and $f are jq variables, bound with --arg
  jq_raw '.assets[$a][$f] // empty' "$manifest" --arg a "$2" --arg f "$3"
}

# built_lib <out> <zig-target>: the shared library a build.sh run for
# <zig-target> leaves under <out> (.so and .dylib are symlink chains).
built_lib() {
  case "$2" in
    *-windows-*) printf '%s\n' "$1/bin/ghostty-vt.dll" ;;
    *-macos | *-ios | *-ios-simulator) printf '%s\n' "$1/lib/libghostty-vt.dylib" ;;
    *) printf '%s\n' "$1/lib/libghostty-vt.so" ;;
  esac
}

# bundled_name <asset>: the file name the hook bundles and the root pubspec's
# `source: path` directory expects (`bundledLibraryName` in prebuilt.dart).
bundled_name() {
  case "$1" in
    *.dll) echo ghostty-vt.dll ;;
    *.dylib) echo libghostty-vt.dylib ;;
    *.so) echo libghostty-vt.so ;;
    *) echo "error: $1 is not a library name" >&2; return 1 ;;
  esac
}

# host_asset: the release asset name that corresponds to this machine.
host_asset() {
  local target
  target="$(host_zig_target)" || return 1
  case "$target" in
    x86_64-linux-gnu) echo libghostty-vt-linux-x64.so ;;
    aarch64-linux-gnu) echo libghostty-vt-linux-arm64.so ;;
    x86_64-macos) echo libghostty-vt-macos-x64.dylib ;;
    aarch64-macos) echo libghostty-vt-macos-arm64.dylib ;;
    x86_64-windows-gnu) echo ghostty-vt-windows-x64.dll ;;
    aarch64-windows-gnu) echo ghostty-vt-windows-arm64.dll ;;
    *) echo "error: no release asset for host $target" >&2; return 1 ;;
  esac
}
