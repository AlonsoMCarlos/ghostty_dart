// Keeps every published package's analysis_options.yaml in sync with the
// root analysis_options.yaml. A package file is self-contained on purpose (it
// ships in the publish archive, where the root file does not exist), so it
// repeats the root rules by hand; this test fails as soon as they drift.
// Run with `dart tool/test/analysis_options_test.dart` from the repo root.

import 'dart:io';

/// Package-only additions on top of the root rules, per package file.
const _packages = {
  'packages/ghostty_dart/analysis_options.yaml': {'- public_member_api_docs'},
  'packages/ghostty_dart_flutter/analysis_options.yaml': {
    '- public_member_api_docs',
    // `flutter pub get` adds it to every Flutter package and re-adds it if
    // removed (flutter_tools' AnalysisOptionsMigration).
    '- build/**',
  },
};

/// The significant lines of an analysis_options.yaml: no comments, no blank
/// lines, trailing spaces removed.
List<String> _rules(String path) => File(path)
    .readAsLinesSync()
    .map((line) => line.replaceFirst(RegExp(r'\s*#.*$'), '').trimRight())
    .where((line) => line.isNotEmpty)
    .toList();

void main() {
  final root = _rules('analysis_options.yaml');
  for (final MapEntry(key: path, value: packageOnly) in _packages.entries) {
    final package = _rules(
      path,
    ).where((line) => !packageOnly.contains(line.trim())).toList();
    if (root.join('\n') == package.join('\n')) {
      stdout.writeln('ok   $path mirrors the root rules');
      continue;
    }
    stdout.writeln(
      'FAIL $path differs from the root analysis_options.yaml (besides '
      '${packageOnly.join(', ')}):\n'
      '  root:    $root\n  package: $package',
    );
    exitCode = 1;
  }
}
