#!/usr/bin/env bash
# Builds libghostty-vt for this machine and stages it in a host-independent
# place, so the root pubspec's `source: path` works on every OS:
#
#   .native-cache/host/<bundled name>   libghostty-vt.so | libghostty-vt.dylib | ghostty-vt.dll
#   .native-cache/host/include/         C headers (input of tool/ffigen.dart)
#
# The bundled names match `bundledLibraryName` in
# packages/ghostty_dart/lib/src/native/prebuilt.dart.
#
# Usage: tool/native/build_host.sh [extra zig build args...]
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tool/native/lib.sh
source "$root/tool/native/lib.sh"

target="$(host_zig_target)"
"$root/tool/native/build.sh" "$target" "$@"

out="$root/.native-cache/out/$target"
case "$target" in
  *-windows-*) lib="$out/bin/ghostty-vt.dll" name=ghostty-vt.dll ;;
  *-macos) lib="$out/lib/libghostty-vt.dylib" name=libghostty-vt.dylib ;;
  *) lib="$out/lib/libghostty-vt.so" name=libghostty-vt.so ;;
esac

host="$root/.native-cache/host"
rm -rf "$host" && mkdir -p "$host"
# -L: the .so and .dylib are symlink chains to the versioned file.
cp -L "$lib" "$host/$name"
cp -R "$out/include" "$host/include"
echo "staged $target -> $host/$name"
