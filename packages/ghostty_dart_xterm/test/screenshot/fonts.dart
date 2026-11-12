// JetBrains Mono for the pub.dev screenshot, read from ghostty_dart_flutter's
// bundled and pinned copy (test/fonts/ there, JetBrains Mono 2.304, OFL-1.1)
// so the repository keeps one copy of the files. Every file is checked
// against the sha256 pinned in that package's test/support/fonts.dart and a
// mismatch throws (fail closed).
//
// This directory reaches outside the package, so .pubignore keeps it out of
// the publish archive; it runs only in this repository.

import 'dart:io';

import 'package:flutter/services.dart';

import '../../../ghostty_dart_flutter/test/support/fonts.dart'
    show
        jetBrainsMonoFamily,
        jetBrainsMonoFiles,
        jetBrainsMonoSha256,
        sha256Hex;

export '../../../ghostty_dart_flutter/test/support/fonts.dart'
    show jetBrainsMonoFamily;

/// Where ghostty_dart_flutter's package root is, seen from this package's
/// root (`flutter test` runs there).
const _widgetRoot = '../ghostty_dart_flutter';

/// Whether every pinned font file is present in the checkout.
bool get jetBrainsMonoBundled => jetBrainsMonoSha256.keys.every(
  (path) => File('$_widgetRoot/$path').existsSync(),
);

/// Skips the screenshot only outside CI when the files are absent; in CI a
/// missing file fails the test instead (`CI` is set by GitHub Actions).
bool get skipWithoutBundledFonts =>
    !jetBrainsMonoBundled && !Platform.environment.containsKey('CI');

/// Loads the verified faces under [jetBrainsMonoFamily]; throws when a file
/// is missing or does not match its pinned sha256.
Future<void> requireJetBrainsMono() async {
  final verified = <String, Uint8List>{};
  for (final MapEntry(key: path, value: expected)
      in jetBrainsMonoSha256.entries) {
    final file = File('$_widgetRoot/$path');
    if (!file.existsSync()) {
      throw StateError('${file.path} is missing; restore the checkout');
    }
    final bytes = file.readAsBytesSync();
    final actual = sha256Hex(bytes);
    if (actual != expected) {
      throw StateError(
        '${file.path} does not match its pinned sha256 (expected $expected, '
        'got $actual)',
      );
    }
    verified[path] = bytes;
  }
  final loader = FontLoader(jetBrainsMonoFamily);
  for (final path in jetBrainsMonoFiles) {
    loader.addFont(Future.value(ByteData.sublistView(verified[path]!)));
  }
  await loader.load();
}
