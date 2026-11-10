// Test font loading for goldens and metric tests.
//
// Goldens render with a bundled, pinned font: JetBrains Mono 2.304
// (OFL-1.1, test/fonts/OFL.txt), the four static TTFs of the GitHub release
// v2.304 (2023-01-14),
// https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip
// (zip sha256 6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf;
// each file also matches the git blob of fonts/ttf/ at tag v2.304).
// [loadJetBrainsMono] checks every file against the sha256 pinned below and
// throws on a mismatch (fail closed). It returns false only when the files
// are absent, and golden tests then skip.
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

/// The sha256 of every bundled test font file (JetBrains Mono 2.304).
const jetBrainsMonoSha256 = {
  'test/fonts/JetBrainsMono-Regular.ttf':
      'a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f',
  'test/fonts/JetBrainsMono-Bold.ttf':
      '5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb',
  'test/fonts/JetBrainsMono-Italic.ttf':
      '9d0a1f7a708e6af183f1193b7e81d40da294f5c67682c085d8401c60aac8ded4',
  'test/fonts/JetBrainsMono-BoldItalic.ttf':
      '4039d5ce0ed225bf9c8b2c8c6436290ae2f356b7e90d70fa666227238324aa3b',
  'test/fonts/OFL.txt':
      '30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad',
};

bool? _jetBrainsMonoLoaded;

/// Whether the JetBrains Mono files are in `test/fonts/` (checked
/// synchronously, so tests can use it in `skip:`); [loadJetBrainsMono]
/// still verifies their hashes.
bool get jetBrainsMonoBundled =>
    jetBrainsMonoSha256.keys.every((path) => File(path).existsSync());

/// Whether the tests run on CI (the `CI` environment variable is set, as
/// GitHub Actions does).
bool get onCi => Platform.environment.containsKey('CI');

/// Whether tests that need the bundled fonts should skip: only locally,
/// when the files are missing. On CI a missing font is a broken checkout,
/// so those tests run and [requireJetBrainsMono] fails them.
bool get skipWithoutBundledFonts => !jetBrainsMonoBundled && !onCi;

/// Loads JetBrains Mono ([loadJetBrainsMono]) and throws [StateError] if
/// the files are missing. For `setUpAll` of tests that skip with
/// [skipWithoutBundledFonts].
Future<void> requireJetBrainsMono() async {
  if (!await loadJetBrainsMono()) {
    throw StateError(
      'JetBrains Mono is missing from test/fonts/ '
      '(${jetBrainsMonoFiles.join(', ')}, OFL.txt); restore the checkout',
    );
  }
}

/// Loads JetBrains Mono from `test/fonts/` under [jetBrainsMonoFamily].
///
/// Returns false, without loading anything, if any face is missing. Throws
/// [StateError] if a file (or `OFL.txt`) does not match its pinned sha256.
/// Safe to call from every test: the fonts are registered once per test
/// process.
Future<bool> loadJetBrainsMono() async {
  if (_jetBrainsMonoLoaded case final loaded?) return loaded;
  if (!jetBrainsMonoBundled) return _jetBrainsMonoLoaded = false;
  final verified = <String, Uint8List>{};
  for (final MapEntry(key: path, value: expected)
      in jetBrainsMonoSha256.entries) {
    final bytes = File(path).readAsBytesSync();
    final actual = sha256Hex(bytes);
    if (actual != expected) {
      throw StateError(
        '$path does not match its pinned sha256 (expected $expected, got '
        '$actual); restore it from the pinned JetBrains Mono 2.304 release',
      );
    }
    verified[path] = bytes;
  }
  final loader = FontLoader(jetBrainsMonoFamily);
  for (final path in jetBrainsMonoFiles) {
    loader.addFont(Future.value(ByteData.sublistView(verified[path]!)));
  }
  await loader.load();
  return _jetBrainsMonoLoaded = true;
}

/// The SHA-256 of [data] as lowercase hex (FIPS 180-4).
///
/// Written here because the package has no `crypto` dependency and must
/// not gain one for a test check.
String sha256Hex(Uint8List data) {
  const k = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  final h = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  // Padding: 0x80, zeros, then the bit length as a 64-bit big-endian int.
  final padded = Uint8List(((data.length + 9 + 63) ~/ 64) * 64)
    ..setRange(0, data.length, data);
  padded[data.length] = 0x80;
  final bits = data.length * 8;
  final view = ByteData.sublistView(padded)
    ..setUint32(padded.length - 8, bits ~/ 0x100000000)
    ..setUint32(padded.length - 4, bits & 0xFFFFFFFF);
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;
  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(chunk + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var [a, b, c, d, e, f, g, hh] = h;
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ (~e & 0xFFFFFFFF & g);
      final t1 = (hh + s1 + ch + k[i] + w[i]) & 0xFFFFFFFF;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    final next = [a, b, c, d, e, f, g, hh];
    for (var i = 0; i < 8; i++) {
      h[i] = (h[i] + next[i]) & 0xFFFFFFFF;
    }
  }
  return h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
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
