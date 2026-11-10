// Keeps unwanted files out of git: nothing tracked may match .gitignore, no
// secret, signing or local-override file may be tracked whatever .gitignore
// says, and no tracked file may be larger than 1 MiB (generated bindings and
// test fonts are well below it; anything bigger is likely a build artefact).
// Run with `dart tool/test/repo_hygiene_test.dart` from the repo root.

import 'dart:io';

/// Tracked files whose names must never be committed.
final _forbidden = <RegExp>[
  RegExp(r'(^|/)pubspec_overrides\.yaml$'),
  RegExp(r'(^|/)\.env(\..*)?$'),
  RegExp(r'\.(pem|key|p12|pfx|jks|keystore|mobileprovision|provisionprofile)$'),
  RegExp(r'(^|/)key\.properties$'),
  RegExp(r'(^|/)local\.properties$'),
  RegExp(r'(^|/)google-services\.json$'),
  RegExp(r'(^|/)GoogleService-Info\.plist$'),
  RegExp(r'(^|/)\.dart_tool/'),
  RegExp(r'(^|/)build/'),
  RegExp(r'(^|/)ephemeral/'),
  RegExp(r'\.(dill|so|dylib|dll|a|o|log)$'),
];

const _maxBytes = 1024 * 1024;

List<String> _git(List<String> args) {
  final result = Process.runSync('git', args);
  if (result.exitCode != 0) {
    stderr.writeln('git ${args.join(' ')} failed: ${result.stderr}');
    exit(2);
  }
  return (result.stdout as String)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toList();
}

void main() {
  var failures = 0;
  void check(String name, List<String> offenders) {
    if (offenders.isEmpty) {
      print('ok   $name');
    } else {
      failures++;
      print('FAIL $name');
      for (final path in offenders) {
        print('       $path');
      }
    }
  }

  final tracked = _git(['ls-files']);
  if (tracked.length < 100) {
    // Fail closed: an empty or truncated listing would make every check pass.
    print('FAIL git ls-files listed only ${tracked.length} files');
    exit(1);
  }

  check(
    'no tracked file matches .gitignore',
    _git(['ls-files', '-ci', '--exclude-standard']),
  );
  check('no secret, signing, local-override or build file is tracked', [
    for (final path in tracked)
      if (_forbidden.any((pattern) => pattern.hasMatch(path))) path,
  ]);
  check('no tracked file is larger than 1 MiB', [
    for (final path in tracked)
      if (File(path).existsSync() && File(path).lengthSync() > _maxBytes)
        '$path (${File(path).lengthSync()} bytes)',
  ]);

  print('${3 - failures} passed, $failures failed');
  if (failures > 0) exit(1);
}
