# Shared helpers for tool/native/*.sh. Source it; do not run it.
# Portable across Linux, macOS (no sha256sum) and Windows Git Bash (CRLF jq).

# jq_raw <filter> <file> [jq args...]: raw jq output without the CR that the
# native Windows jq adds to each line.
jq_raw() {
  local filter="$1" file="$2"; shift 2
  jq -r "$@" "$filter" "$file" | tr -d '\r'
}

# sha256_of <file>: prints the lowercase hex sha256 of a file.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
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
