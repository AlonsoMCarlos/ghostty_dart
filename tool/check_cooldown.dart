// Fails if pubspec.lock contains a hosted package version published less than
// the cooldown period ago (default 3 days). Supply-chain policy: AGENTS.md.
//
// Usage: dart run tool/check_cooldown.dart [--days N]

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final daysIndex = args.indexOf('--days');
  final days = daysIndex >= 0 ? int.parse(args[daysIndex + 1]) : 3;
  final root = File.fromUri(Platform.script.resolve('../pubspec.lock'));
  final packages = _parseLock(root.readAsStringSync());

  final client = HttpClient();
  final tooNew = <String>[];
  final now = DateTime.now().toUtc();
  try {
    for (final MapEntry(key: name, value: version) in packages.entries) {
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
      'cooldown ok: ${packages.length} packages >= $days days old',
    );
    return;
  }
  stderr.writeln(
    'Packages newer than $days days (hold them back with a '
    'root dependency_override):',
  );
  for (final line in tooNew) {
    stderr.writeln('  $line');
  }
  exitCode = 1;
}

/// Extracts `name -> version` for hosted packages from a pubspec.lock.
Map<String, String> _parseLock(String lock) {
  final result = <String, String>{};
  final entry = RegExp(
    r'^  (\S+):\n(?:    .*\n)*?    source: hosted\n    version: "([^"]+)"',
    multiLine: true,
  );
  for (final match in entry.allMatches(lock)) {
    result[match[1]!] = match[2]!;
  }
  return result;
}
