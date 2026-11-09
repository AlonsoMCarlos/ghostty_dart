// Checks prebuilt release assets against what their names promise, before
// they are published (ADR 0008, "Verification"). Run it through
// tool/native/check_binary.sh, which supplies the verified upstream headers
// and the floors from native/prebuilt_assets.json. The checks themselves are
// in src/binary_check.dart.
//
// Usage:
//   dart tool/native/check_binary.dart --headers <include dir>
//       --glibc-floor <major.minor> --macos-floor <major> --ios-floor <major> <asset> <file> [<asset> <file>...]
// Exit codes: 0 all passed, 1 a check failed, 64 usage error (EX_USAGE),
// 66 headers missing (EX_NOINPUT).

import 'dart:io';

import 'src/binary_check.dart';

void main(List<String> args) {
  String? headers, glibc, macos, ios;
  final pairs = <String>[];
  for (var i = 0; i < args.length; i++) {
    String value() => i + 1 < args.length ? args[++i] : _usage();
    switch (args[i]) {
      case '--headers':
        headers = value();
      case '--glibc-floor':
        glibc = value();
      case '--macos-floor':
        macos = value();
      case '--ios-floor':
        ios = value();
      case final a:
        pairs.add(a);
    }
  }
  final glibcMatch = RegExp(r'^(\d+)\.(\d+)$').firstMatch(glibc ?? '');
  final macosFloor = int.tryParse(macos ?? '');
  final iosFloor = int.tryParse(ios ?? '');
  if (headers == null ||
      glibcMatch == null ||
      macosFloor == null ||
      iosFloor == null ||
      pairs.isEmpty ||
      pairs.length.isOdd) {
    _usage();
  }
  final floors = Floors(
    glibc: (int.parse(glibcMatch[1]!), int.parse(glibcMatch[2]!)),
    macos: macosFloor,
    ios: iosFloor,
  );

  final include = Directory(headers);
  final vt = Directory('${include.path}/ghostty/vt');
  if (!vt.existsSync()) {
    stderr.writeln('error: no libghostty-vt headers under ${include.path}');
    exit(66);
  }
  final api = declaredApi([
    for (final f in [
      File('${include.path}/ghostty/vt.h'),
      ...vt.listSync(recursive: true).whereType<File>(),
    ])
      if (f.path.endsWith('.h')) (f.path, f.readAsStringSync()),
  ]);
  if (api.isEmpty) {
    stderr.writeln('error: no GHOSTTY_API declarations under ${include.path}');
    exit(66);
  }

  final failed = <String>[];
  for (var i = 0; i < pairs.length; i += 2) {
    final (asset, path) = (pairs[i], pairs[i + 1]);
    stdout.writeln('checking $asset ($path)');
    final List<CheckLine> lines;
    try {
      lines = checkBinary(
        asset: asset,
        bytes: File(path).readAsBytesSync(),
        api: api,
        floors: floors,
      );
    } on FormatException catch (e) {
      stderr.writeln('error: ${e.message}');
      exit(64);
    }
    for (final l in lines) {
      stdout.writeln('  ${l.info ? '' : (l.ok ? 'ok   ' : 'FAIL ')}${l.text}');
    }
    final ok = lines.every((l) => l.ok);
    stdout.writeln(ok ? 'ok $asset' : 'FAILED $asset');
    if (!ok) failed.add(asset);
  }
  if (failed.isNotEmpty) {
    stderr.writeln('error: failed checks: ${failed.join(', ')}');
    exit(1);
  }
}

Never _usage() {
  stderr.writeln(
    'usage: check_binary.dart --headers <dir> --glibc-floor <x.y> '
    '--macos-floor <n> --ios-floor <n> <asset> <file> [<asset> <file>...]',
  );
  exit(64);
}
