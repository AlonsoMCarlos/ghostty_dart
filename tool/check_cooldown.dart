// Fails if any lockfile in the repo contains a hosted package version
// published less than the cooldown period ago (default 3 days).
// Supply-chain policy: AGENTS.md.
//
// The lockfiles are discovered with `git ls-files` (tracked plus untracked,
// not ignored), so a new one is checked as soon as it exists. Parsing fails
// closed: a lockfile whose hosted entries cannot all be read is an error,
// never "0 packages ok".
//
// Usage: dart run tool/check_cooldown.dart [--days N]
// Tests: tool/test/check_cooldown_test.dart (`mise run test:tool`).

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final daysIndex = args.indexOf('--days');
  final days = daysIndex >= 0 ? int.parse(args[daysIndex + 1]) : 3;
  final root = Directory.fromUri(Platform.script.resolve('..')).path;

  final List<String> lockfiles;
  // `name -> version`, deduplicated across lockfiles; a package locked at
  // different versions in two files is checked once per version.
  final packages = <(String, String)>{};
  try {
    lockfiles = findLockfiles(root);
    for (final path in lockfiles) {
      final lock = File('$root/$path').readAsStringSync();
      for (final MapEntry(key: name, value: version) in parseLock(
        lock,
        path,
      ).entries) {
        packages.add((name, version));
      }
    }
  } on Object catch (e) {
    stderr.writeln('cooldown: $e');
    exitCode = 1;
    return;
  }

  final client = HttpClient();
  final tooNew = <String>[];
  final now = DateTime.now().toUtc();
  try {
    for (final (name, version) in packages) {
      final url = Uri.https('pub.dev', '/api/packages/$name/versions/$version');
      final response = await (await client.getUrl(url)).close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        tooNew.add('$name $version (lookup failed: ${response.statusCode})');
        continue;
      }
      final json = jsonDecode(body) as Map<String, Object?>;
      final published = DateTime.parse(json['published']! as String);
      final age = now.difference(published);
      if (age < Duration(days: days)) {
        tooNew.add('$name $version (published $published)');
      }
    }
  } finally {
    client.close();
  }

  if (tooNew.isEmpty) {
    stdout.writeln(
      'cooldown ok: ${packages.length} package versions in '
      '${lockfiles.length} lockfiles (${lockfiles.join(', ')}) '
      '>= $days days old',
    );
    return;
  }
  stderr.writeln(
    'Packages newer than $days days (hold them back with a '
    '`dependency_overrides` entry in the pubspec next to the lockfile):',
  );
  for (final line in tooNew) {
    stderr.writeln('  $line');
  }
  exitCode = 1;
}

/// Every `pubspec.lock` under [root] that git tracks or would track
/// (untracked but not ignored), relative to [root] and sorted.
///
/// Throws [StateError] if git fails or the root `pubspec.lock` is missing:
/// finding nothing must never pass.
List<String> findLockfiles(String root) {
  final result = Process.runSync('git', [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '--',
    'pubspec.lock',
    '*/pubspec.lock',
  ], workingDirectory: root);
  if (result.exitCode != 0) {
    throw StateError('git ls-files failed in $root: ${result.stderr}');
  }
  final files =
      (result.stdout as String)
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  if (!files.contains('pubspec.lock')) {
    throw StateError('no pubspec.lock at the repo root $root');
  }
  return files;
}

/// Extracts `name -> version` for the hosted packages of a pubspec.lock.
///
/// Throws [FormatException] if it finds no hosted entry, or if the number of
/// parsed entries differs from the number of `source: hosted` lines, so a
/// format change cannot silently skip packages. [path] only labels the error.
Map<String, String> parseLock(String lock, String path) {
  final text = lock.replaceAll('\r\n', '\n');
  final result = <String, String>{};
  final entry = RegExp(
    r'^  (\S+):\n(?:    .*\n)*?    source: hosted\n    version: "([^"]+)"',
    multiLine: true,
  );
  var matches = 0;
  for (final match in entry.allMatches(text)) {
    matches++;
    result[match[1]!] = match[2]!;
  }
  final hosted = RegExp(r'^    source: hosted$', multiLine: true);
  final expected = hosted.allMatches(text).length;
  if (expected == 0 || matches != expected || result.length != matches) {
    throw FormatException(
      '$path: parsed $matches hosted entries (${result.length} unique) '
      'but found $expected `source: hosted` lines; the lockfile format '
      'is not understood',
    );
  }
  return result;
}
