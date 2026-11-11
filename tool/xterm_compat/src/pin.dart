// Fail-closed pinning of the xterm 4.0.0 sources the snapshot is read from.
//
// pub verifies an archive's sha256 only when it downloads it; the extracted
// copy in the pub cache is user-writable and never re-checked. So before the
// analyzer reads it, the snapshot step checks that (1) the workspace lock pins
// xterm 4.0.0 from pub.dev with the archive sha256 below, (2) the package
// config resolves `xterm` to that version's directory, and (3) the tree of
// `lib/` files hashes to the value below, computed once from a freshly
// downloaded archive whose sha256 matched (1).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The xterm version the adapter mirrors (ADR 0004, ADR 0013).
const xtermVersion = '4.0.0';

/// sha256 of `xterm-4.0.0.tar.gz` on pub.dev, as in the workspace's
/// pubspec.lock.
const xtermArchiveSha256 =
    '168dfedca77cba33fdb6f52e2cd001e9fde216e398e89335c19b524bb22da3a2';

/// [libTreeSha256] of xterm 4.0.0's `lib/`, computed on 2026-11-11 from
/// https://pub.dev/api/archives/xterm-4.0.0.tar.gz after checking the archive
/// against [xtermArchiveSha256] (77 files; identical to the pub cache copy).
const xtermLibSha256 =
    'c59d9d0d2146f6a4a10ef33f296fc3968fcf5d0546b3aea443df1451bd16c929';

/// A pin did not match: the snapshot must not be taken.
final class PinError implements Exception {
  PinError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Checks the `xterm` entry of a pubspec.lock: hosted on pub.dev at
/// [xtermVersion] with [xtermArchiveSha256]. Throws [PinError] otherwise.
void checkLock(String lock, {String sha256 = xtermArchiveSha256}) {
  final lines = const LineSplitter().convert(lock);
  final start = lines.indexOf('  xterm:');
  if (start < 0) throw PinError('pubspec.lock has no xterm entry');
  final stanza = <String, String>{};
  for (final line in lines.skip(start + 1)) {
    if (!line.startsWith('    ')) break;
    final match = RegExp(r'^\s+(\w+): "?([^"]*)"?$').firstMatch(line);
    if (match != null) stanza[match[1]!] = match[2]!;
  }
  void expectField(String key, String value) {
    if (stanza[key] != value) {
      throw PinError(
        'pubspec.lock: xterm $key is "${stanza[key]}", expected "$value"',
      );
    }
  }

  expectField('source', 'hosted');
  expectField('url', 'https://pub.dev');
  expectField('version', xtermVersion);
  expectField('sha256', sha256);
}

/// The directory the package config resolves `xterm` to. Throws [PinError]
/// unless it is a `xterm-<xtermVersion>` directory.
Directory xtermRoot(File packageConfig) {
  final json = jsonDecode(packageConfig.readAsStringSync());
  final packages = (json as Map<String, Object?>)['packages']! as List<Object?>;
  for (final p in packages.cast<Map<String, Object?>>()) {
    if (p['name'] != 'xterm') continue;
    final root = packageConfig.uri.resolve(p['rootUri']! as String);
    final path = root.toFilePath().replaceAll(RegExp(r'[/\\]+$'), '');
    if (!path.endsWith('xterm-$xtermVersion')) {
      throw PinError('package config resolves xterm to $path');
    }
    return Directory(path);
  }
  throw PinError('${packageConfig.path} has no xterm package (run deps)');
}

/// sha256 over the sorted listing `<sha256 of file>  lib/<path>\n` of every
/// file under [lib] (the same as `find lib -type f | LC_ALL=C sort` hashed
/// with sha256sum). Links are refused rather than followed.
String libTreeSha256(Directory lib) {
  final files = <String, File>{};
  for (final entity in lib.listSync(recursive: true, followLinks: false)) {
    if (entity is Link) throw PinError('unexpected link ${entity.path}');
    if (entity is! File) continue;
    final rel = entity.path
        .substring(lib.path.length)
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp('^/+'), '');
    files['lib/$rel'] = entity;
  }
  if (files.isEmpty) throw PinError('${lib.path} has no files');
  final names = files.keys.toList()..sort(_byteOrder);
  final listing = StringBuffer();
  for (final name in names) {
    listing.write('${sha256.convert(files[name]!.readAsBytesSync())}  $name\n');
  }
  return sha256.convert(utf8.encode(listing.toString())).toString();
}

/// `LC_ALL=C sort` order: by UTF-8 bytes.
int _byteOrder(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// Runs every check against the workspace at [root] and returns xterm's
/// directory. Throws [PinError] on the first mismatch.
Directory verifyXterm(
  String root, {
  String archiveSha256 = xtermArchiveSha256,
  String libSha256 = xtermLibSha256,
}) {
  checkLock(
    File('$root/pubspec.lock').readAsStringSync(),
    sha256: archiveSha256,
  );
  final dir = xtermRoot(File('$root/.dart_tool/package_config.json'));
  final actual = libTreeSha256(Directory('${dir.path}/lib'));
  if (actual != libSha256) {
    throw PinError(
      '${dir.path}/lib hashes to $actual, expected $libSha256: the pub cache '
      'copy of xterm differs from the published archive. Run '
      '`dart pub cache repair` (or delete that directory and `mise run deps`) '
      'and retry.',
    );
  }
  return dir;
}
