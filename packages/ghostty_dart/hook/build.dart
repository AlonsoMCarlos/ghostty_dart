// Build hook that provides the libghostty-vt native library.
//
// Sources, selected with `hooks: user_defines: ghostty_dart: source:` in the
// root pubspec (see the "Build hook options" doc topic):
//
// - `prebuilt` (default): download the binary for the target from the
//   project's GitHub release and verify it against the sha256 pinned in this
//   package. Fails closed on mismatch.
// - `path`: use a local binary given by the `path` user-define. It may be the
//   library file, or a directory holding it under its bundled name
//   (`libghostty-vt.so`, `libghostty-vt.dylib` or `ghostty-vt.dll`, see
//   `bundledLibraryName`). The repo's root pubspec points at the directory
//   `.native-cache/host/`, filled by `mise run native:host` on any OS.
// - `system`: load an installed `libghostty-vt` 1.x from the system.
//
// The hook never runs downloaded code and never fetches anything unpinned.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:ghostty_dart/src/native/prebuilt.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final source = input.userDefines['source'] ?? 'prebuilt';

    final CodeAsset asset;
    switch (source) {
      case 'path':
        final define = input.userDefines.path('path');
        if (define == null) {
          throw const FormatException(
            'ghostty_dart: source "path" requires the "path" user-define.',
          );
        }
        final path = localLibraryUri(
          define,
          code.targetOS,
          isDirectory: FileSystemEntity.isDirectorySync(define.toFilePath()),
        );
        output.dependencies.add(path);
        final copy = await _copyInto(
          File.fromUri(path),
          input.outputDirectory,
          code.targetOS,
        );
        asset = _bundled(input.packageName, copy);
      case 'system':
        asset = CodeAsset(
          package: input.packageName,
          name: nativeAssetName,
          linkMode: DynamicLoadingSystem(
            Uri.file(systemLibraryName(code.targetOS)),
          ),
        );
      case 'prebuilt':
        final file = await _fetchPrebuilt(
          target: PrebuiltTarget(code.targetOS, code.targetArchitecture),
          urlPattern: input.userDefines['url_pattern'] as String?,
          cacheDir: input.outputDirectoryShared,
        );
        final copy = await _copyInto(
          file,
          input.outputDirectory,
          code.targetOS,
        );
        asset = _bundled(input.packageName, copy);
      default:
        throw FormatException(
          'ghostty_dart: unknown source "$source". '
          'Use one of: prebuilt, path, system.',
        );
    }
    output.assets.code.add(asset);
  });
}

CodeAsset _bundled(String package, File file) => CodeAsset(
  package: package,
  name: nativeAssetName,
  linkMode: DynamicLoadingBundled(),
  file: file.uri,
);

/// Copies [file] into [dir] under the canonical bundled file name, so every
/// target ships the same name (required on Apple platforms).
Future<File> _copyInto(File file, Uri dir, OS os) async {
  if (!file.existsSync()) {
    throw FileSystemException(
      'ghostty_dart: native library not found',
      file.path,
    );
  }
  final dest = File.fromUri(dir.resolve(bundledLibraryName(os)));
  await dest.parent.create(recursive: true);
  return file.copy(dest.path);
}

Future<File> _fetchPrebuilt({
  required PrebuiltTarget target,
  required String? urlPattern,
  required Uri cacheDir,
}) async {
  final pinned = prebuiltSha256[target.fileName];
  if (pinned == null) {
    throw UnsupportedError(
      'ghostty_dart: no prebuilt libghostty-vt $targetLibghosttyVtVersion for '
      '${target.fileName}. Set `source: path` or `source: system` in '
      '`hooks: user_defines: ghostty_dart:` of your root pubspec.yaml.',
    );
  }
  final cached = File.fromUri(cacheDir.resolve('$pinned/${target.fileName}'));
  if (cached.existsSync() && await _sha256(cached) == pinned) return cached;

  final url = Uri.parse(
    (urlPattern ?? defaultUrlPattern)
        .replaceAll(r'$VERSION', targetLibghosttyVtVersion)
        .replaceAll(r'$FILENAME', target.fileName),
  );
  if (url.scheme != 'https') {
    throw FormatException('ghostty_dart: refusing non-https url_pattern: $url');
  }
  await cached.parent.create(recursive: true);
  final partial = File('${cached.path}.part');
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    await response.pipe(partial.openWrite());
  } finally {
    client.close();
  }
  final actual = await _sha256(partial);
  if (actual != pinned) {
    await partial.delete();
    throw StateError(
      'ghostty_dart: sha256 mismatch for $url\n'
      '  expected $pinned\n  actual   $actual',
    );
  }
  return partial.rename(cached.path);
}

Future<String> _sha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
