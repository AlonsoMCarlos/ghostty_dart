// Test font loading for goldens and metric tests.
//
// Goldens must render with a bundled, pinned font: JetBrains Mono (OFL-1.1),
// expected in test/fonts/ (from a pinned release, with their sha256 and
// OFL.txt). Until they are added [loadJetBrainsMono] returns false and
// golden tests must skip.
//
// Metric spikes may also use monospace fonts already installed on the host
// ([loadSystemMonospace]); they are read from disk, never downloaded, and
// tests skip when a font is missing.

import 'dart:io';

import 'package:flutter/services.dart';

/// The family name goldens use for the bundled test font.
const jetBrainsMonoFamily = 'JetBrains Mono';

/// The JetBrains Mono faces expected in `test/fonts/`, relative to the
/// package root (`flutter test` runs there).
const jetBrainsMonoFiles = [
  'test/fonts/JetBrainsMono-Regular.ttf',
  'test/fonts/JetBrainsMono-Bold.ttf',
  'test/fonts/JetBrainsMono-Italic.ttf',
  'test/fonts/JetBrainsMono-BoldItalic.ttf',
];

bool? _jetBrainsMonoLoaded;

/// Loads JetBrains Mono from `test/fonts/` under [jetBrainsMonoFamily].
///
/// Returns false, without loading anything, if any face is missing. Safe to
/// call from every test: the fonts are registered once per test process.
Future<bool> loadJetBrainsMono() async {
  if (_jetBrainsMonoLoaded case final loaded?) return loaded;
  final files = jetBrainsMonoFiles.map(File.new).toList();
  if (!files.every((file) => file.existsSync())) {
    return _jetBrainsMonoLoaded = false;
  }
  final loader = FontLoader(jetBrainsMonoFamily);
  for (final file in files) {
    final bytes = file.readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
  return _jetBrainsMonoLoaded = true;
}

/// A monospace font installed on the host, for metric spikes only.
typedef SystemMonospace = ({String family, String path});

/// Monospace fonts commonly installed on Debian/Ubuntu (the Linux CI image
/// and the dev box). Not used by goldens: their versions are not pinned.
const systemMonospaceCandidates = <SystemMonospace>[
  (
    family: 'Spike DejaVu Sans Mono',
    path: '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
  ),
  (
    family: 'Spike Liberation Mono',
    path: '/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf',
  ),
  (
    family: 'Spike Noto Sans Mono',
    path: '/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf',
  ),
];

final _systemLoaded = <String>{};

/// Loads the installed fonts of [systemMonospaceCandidates] that exist and
/// returns their family names (empty when none is installed).
Future<List<String>> loadSystemMonospace() async {
  final families = <String>[];
  for (final font in systemMonospaceCandidates) {
    final file = File(font.path);
    if (!file.existsSync()) continue;
    if (_systemLoaded.add(font.family)) {
      final loader = FontLoader(font.family)
        ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      await loader.load();
    }
    families.add(font.family);
  }
  return families;
}
