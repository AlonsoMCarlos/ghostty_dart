// Build hook that provides the libghostty-vt native library.
//
// Sources, selected with `hooks: user_defines: ghostty_dart: source:` in the
// root pubspec (see the "Build hook options" doc topic):
//
// - `prebuilt` (default): download the binary for the target from the
//   project's GitHub release `prebuiltReleaseTag` (ADR 0008) and verify it
//   against the sha256 pinned in `lib/src/native/prebuilt.dart`. Fails
//   closed on mismatch. Options:
//   - `url_pattern`: an https mirror. `$TAG`, `$VERSION` and `$FILENAME`
//     are substituted (see `defaultUrlPattern`); the hash is still checked.
//   The app must target at least Android API 24, iOS 14 or macOS 13, the
//   floor of the prebuilt binaries; lower targets fail with a message.
//   Downloads have connect, idle and per-attempt timeouts, a 64 MiB cap,
//   https-only redirects (at most 5) and one retry on transient errors
//   (`lib/src/native/download.dart`). Proxies come from `HTTPS_PROXY` /
//   `NO_PROXY`; a TLS-intercepting proxy needs `url_pattern` pointing at a
//   reachable mirror, or `source: path`.
// - `path`: use a local binary given by the `path` user-define. It may be the
//   library file, or a directory holding it under its bundled name
//   (`libghostty-vt.so`, `libghostty-vt.dylib` or `ghostty-vt.dll`, see
//   `bundledLibraryName`). The repo's root pubspec points at the directory
//   `.native-cache/host/`, filled by `mise run native:host` on any OS.
// - `system`: load an installed `libghostty-vt` 1.x from the system.
//
// The hook never runs downloaded code and never fetches anything unpinned.
//
// Caching (verified 2026-11-09 in hooks_runner 1.5.0,
// `lib/src/build_runner/build_runner.dart`): the hook is recompiled and
// re-run when a Dart source in its kernel depfile changes (lines 481-491,
// 808-856), and `prebuilt.dart` is one of them. Pub-hosted sources are
// treated as immutable (`_isImmutable`, line 869), but `package_config.json`
// is hashed, so a package upgrade also re-runs it. A changed input (target,
// user-defines) re-runs it too (lines 501-507). So a new pin needs no extra
// `output.dependencies`. The shared download cache is keyed by the pinned
// hash, so a new pin never reuses an old file. Only `source: path` reads a
// file outside the hook's sources, and it is declared as a dependency.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:ghostty_dart/src/native/download.dart';
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
          // A trailing slash means a directory even before it exists, so a
          // missing `.native-cache/host/` names the library it lacks.
          isDirectory:
              define.path.endsWith('/') ||
              FileSystemEntity.isDirectorySync(define.toFilePath()),
        );
        output.dependencies.add(path);
        if (!File.fromUri(path).existsSync()) {
          throw FileSystemException(
            localLibraryMissingMessage(path, code.targetOS),
            path.toFilePath(),
          );
        }
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
        final urlPattern = input.userDefines['url_pattern'];
        if (urlPattern is! String?) {
          throw const FormatException(
            'ghostty_dart: the "url_pattern" user-define must be a string.',
          );
        }
        final file = await _fetchPrebuilt(
          code: code,
          urlPattern: urlPattern,
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
  required CodeConfig code,
  required String? urlPattern,
  required Uri cacheDir,
}) async {
  final versionError = prebuiltMinimumVersionError(
    code.targetOS,
    targetPlatformVersion(code),
  );
  if (versionError != null) throw UnsupportedError(versionError);

  final target = PrebuiltTarget.fromCodeConfig(code);
  final pinned = prebuiltSha256[target.fileName];
  if (pinned == null) {
    throw UnsupportedError(
      'ghostty_dart: no prebuilt libghostty-vt $targetLibghosttyVtVersion for '
      '${target.fileName} in release $prebuiltReleaseTag.\n'
      '${prebuiltAlternativesHint()}',
    );
  }
  return const PrebuiltFetcher().fetch(
    url: prebuiltUrl(urlPattern ?? defaultUrlPattern, target.fileName),
    fileName: target.fileName,
    pinnedSha256: pinned,
    cacheDir: cacheDir,
  );
}
