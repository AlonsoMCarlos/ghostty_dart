/// Native-library facts for `hook/build.dart`: asset name, library file
/// names and the pinned prebuilt hashes. Lives under `lib/` so the hook can
/// import it; must not import `dart:ffi`, so it stays usable from the hook
/// and from web builds.
library;

import 'package:code_assets/code_assets.dart';

/// The libghostty-vt version these bindings target and the hook fetches.
///
/// Not the loaded library's version: that is the public
/// `libghosttyVtVersion` getter.
const targetLibghosttyVtVersion = '1.0.0';

/// Asset name of the native library. The `@Native` bindings resolve symbols
/// through `package:ghostty_dart/<nativeAssetName>`, which is the default asset
/// id of the generated bindings library.
const nativeAssetName = 'src/ffi/bindings.g.dart';

/// Default download location of prebuilt binaries. `$VERSION` and `$FILENAME`
/// are substituted. Override with the `url_pattern` user-define (mirrors).
const defaultUrlPattern =
    r'https://github.com/AlonsoMCarlos/ghostty_dart/releases/download/native-v$VERSION/$FILENAME';

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

/// Resolves the `path` user-define of `source: path` to the library file.
///
/// [path] may name the library file itself, or a directory that holds it
/// under [bundledLibraryName] for [os]. The directory form lets one root
/// pubspec serve every host: `tool/native/build_host.sh` stages each host's
/// build into `.native-cache/host/`. Pass whether [path] is an existing
/// directory as [isDirectory]; this function does no I/O.
Uri localLibraryUri(Uri path, OS os, {required bool isDirectory}) {
  if (!isDirectory) return path;
  final dir = path.path.endsWith('/')
      ? path
      : path.replace(path: '${path.path}/');
  return dir.resolve(bundledLibraryName(os));
}

/// Name the system dynamic loader resolves for an installed libghostty-vt 1.x.
String systemLibraryName(OS os) => switch (os) {
  OS.windows => 'ghostty-vt.dll',
  OS.macOS || OS.iOS => 'libghostty-vt.1.dylib',
  _ => 'libghostty-vt.so.1',
};
