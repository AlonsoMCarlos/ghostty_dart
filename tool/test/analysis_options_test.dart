// Keeps packages/ghostty_dart/analysis_options.yaml in sync with the root
// analysis_options.yaml. The package file is self-contained on purpose (it
// ships in the publish archive, where the root file does not exist), so it
// repeats the root rules by hand; this test fails as soon as they drift.
// Run with `dart tool/test/analysis_options_test.dart` from the repo root.

import 'dart:io';

/// Package-only additions on top of the root rules.
const _packageOnly = {'- public_member_api_docs'};

/// The significant lines of an analysis_options.yaml: no comments, no blank
/// lines, trailing spaces removed.
List<String> _rules(String path) => File(path)
    .readAsLinesSync()
    .map((line) => line.replaceFirst(RegExp(r'\s*#.*$'), '').trimRight())
    .where((line) => line.isNotEmpty)
    .toList();

void main() {
  final root = _rules('analysis_options.yaml');
  final package = _rules(
    'packages/ghostty_dart/analysis_options.yaml',
  ).where((line) => !_packageOnly.contains(line.trim())).toList();
  if (root.join('\n') == package.join('\n')) {
    stdout.writeln('ok   package analysis_options.yaml mirrors the root rules');
    return;
  }
  stdout.writeln(
    'FAIL packages/ghostty_dart/analysis_options.yaml differs from the root '
    'analysis_options.yaml (besides ${_packageOnly.join(', ')}):\n'
    '  root:    $root\n  package: $package',
  );
  exitCode = 1;
}
