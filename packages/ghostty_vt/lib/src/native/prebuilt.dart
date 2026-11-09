// Shared between hook/build.dart and the library. Must not import dart:ffi,
// so it stays usable from the hook and from web builds.

import 'package:code_assets/code_assets.dart';

/// The libghostty-vt version these bindings target.
const libghosttyVtVersion = '1.0.0';

/// Asset name of the native library. The `@Native` bindings resolve symbols
/// through `package:ghostty_vt/<nativeAssetName>`, which is the default asset
/// id of the generated bindings library.
const nativeAssetName = 'src/ffi/bindings.g.dart';

/// Default download location of prebuilt binaries. `$VERSION` and `$FILENAME`
/// are substituted. Override with the `url_pattern` user-define (mirrors).
const defaultUrlPattern =
    r'https://github.com/OWNER/REPO/releases/download/native-v$VERSION/$FILENAME';

/// sha256 of each prebuilt binary, keyed by [PrebuiltTarget.fileName].
///
/// Filled by the release pipeline. A target missing here has no prebuilt
/// binary and the hook fails with instructions instead of downloading.
const prebuiltSha256 = <String, String>{};

/// A target OS and architecture with a prebuilt binary.
final class PrebuiltTarget {
  /// Creates a target.
  const PrebuiltTarget(this.os, this.architecture);

  /// Target operating system.
  final OS os;

  /// Target CPU architecture.
  final Architecture architecture;

  /// File name of the release asset, e.g. `libghostty-vt-linux-x64.so`.
  String get fileName {
    final ext = switch (os) {
      OS.windows => 'dll',
      OS.macOS || OS.iOS => 'dylib',
      _ => 'so',
    };
    final prefix = os == OS.windows ? '' : 'lib';
    return '${prefix}ghostty-vt-${os.name}-${architecture.name}.$ext';
  }
}

/// File name the library is bundled under. Identical across architectures,
/// as Apple platforms require.
String bundledLibraryName(OS os) => switch (os) {
  OS.windows => 'ghostty-vt.dll',
  OS.macOS || OS.iOS => 'libghostty-vt.dylib',
  _ => 'libghostty-vt.so',
};

/// Name the system dynamic loader resolves for an installed libghostty-vt 1.x.
String systemLibraryName(OS os) => switch (os) {
  OS.windows => 'ghostty-vt.dll',
  OS.macOS || OS.iOS => 'libghostty-vt.1.dylib',
  _ => 'libghostty-vt.so.1',
};
