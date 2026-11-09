// Checks that every Spanish translation (`X.es.md`) tracks the current
// English source (`X.md`), as AGENTS.md "Docs and language" requires.
//
// Run `mise run docs:translations`, or `dart tool/check_translations.dart`
// from anywhere in the repository (the root comes from git).
//
// Each `X.es.md` must start with
//
//     <!-- source: X.md@<blob sha> -->
//     [English](…X.md) | **Español**
//
// where `<blob sha>` is `git hash-object X.md` of the English text the
// translation matches, and one of the first lines of `X.md` (after a title
// and badges, if any) must be `**English** | [Español](…X.es.md)`.
//
// - Stale (the English file changed since): a `::warning::` and exit 0, so CI
//   shows it without blocking (AGENTS.md: "or the CI warning stays").
// - Structural problems (no or malformed header, wrong source name, missing
//   English file, missing language switcher): an `::error::` and exit 1.
//
// Why the blob sha of the working-tree file (`git hash-object --path`) and
// not a commit sha or `git rev-parse HEAD:<path>`
// (docs/internal/research/2026-11-09-user-docs.md §6):
// - A commit sha does not survive squash or rebase merges, and a PR cannot
//   name the commit it is creating. A blob sha is content-addressed, so it
//   survives both.
// - Hashing the working tree lets authors run the check before committing,
//   and in CI the checkout equals HEAD, so it gives the same answer as
//   `HEAD:<path>`. `--path` applies `.gitattributes` (`eol=lf`), so a CRLF
//   checkout on Windows hashes to the same blob.

import 'dart:io';

/// The first line of a translation: `<!-- source: X.md@<sha> -->`.
final sourceHeader = RegExp(
  r'^<!-- source: (\S+)@([0-9a-f]{40}|[0-9a-f]{64}) -->$',
);

/// How many lines at the top of an English file may hold its switcher.
const englishSwitcherWindow = 20;

/// Hashes a file as git would store it, applying `.gitattributes` filters.
typedef BlobHasher = String Function(String path);

/// How serious a [Finding] is.
enum Severity {
  /// The translation is behind its English source. Reported, not fatal.
  stale,

  /// The pair cannot be checked or breaks the header rules. Fatal.
  error,
}

/// One problem with one file.
final class Finding {
  /// Creates a finding for [file] (a path relative to the repository root).
  const Finding(this.severity, this.file, this.message);

  /// Whether this blocks (error) or only warns (stale).
  final Severity severity;

  /// Path relative to the repository root, with `/` separators.
  final String file;

  /// Human-readable explanation, including how to fix it.
  final String message;

  /// The line in GitHub Actions workflow-command syntax.
  String toWorkflowCommand() {
    final level = severity == Severity.stale ? 'warning' : 'error';
    return '::$level file=$file,line=1::$message';
  }
}

/// The English sibling of a translation: `docs/X.es.md` → `docs/X.md`.
String englishPathFor(String spanishPath) {
  if (!spanishPath.endsWith('.es.md')) {
    throw ArgumentError.value(spanishPath, 'spanishPath', 'not a .es.md file');
  }
  return '${spanishPath.substring(0, spanishPath.length - '.es.md'.length)}.md';
}

/// Checks one translation pair. [root] is the repository root; [spanish] is
/// relative to it, with `/` separators. Returns no findings when the pair is
/// up to date.
List<Finding> checkPair(String root, String spanish, BlobHasher hashBlob) {
  final english = englishPathFor(spanish);
  final englishName = english.split('/').last;
  final spanishName = spanish.split('/').last;
  final englishFile = File('$root/$english');
  if (!englishFile.existsSync()) {
    return [
      Finding(
        Severity.error,
        spanish,
        'English source $english does not exist (renamed or deleted?). '
        'Rename or remove the translation too.',
      ),
    ];
  }

  final findings = <Finding>[];
  final spanishLines = _lines(File('$root/$spanish'));
  final header = spanishLines.isEmpty ? null : spanishLines.first;
  final match = header == null ? null : sourceHeader.firstMatch(header);
  final expected = hashBlob(english);
  if (match == null) {
    findings.add(
      Finding(
        Severity.error,
        spanish,
        'Line 1 must be "<!-- source: $englishName@<blob sha> -->". '
        'Once the translation matches $english, use: '
        '<!-- source: $englishName@$expected -->',
      ),
    );
  } else if (match.group(1) != englishName) {
    findings.add(
      Finding(
        Severity.error,
        spanish,
        'The header names "${match.group(1)}" but the English source is '
        '"$englishName".',
      ),
    );
  } else if (match.group(2) != expected) {
    findings.add(
      Finding(
        Severity.stale,
        spanish,
        'Translation is behind $english (header ${_short(match.group(2)!)}, '
        'English is now ${_short(expected)}). Update it, then set line 1 to '
        '<!-- source: $englishName@$expected -->',
      ),
    );
  }

  // The switcher is the second line, right after the invisible comment.
  final switcher = spanishLines.length > 1 ? spanishLines[1] : '';
  if (!switcher.contains('**Español**') ||
      !_linksTo(switcher, 'English', englishName)) {
    findings.add(
      Finding(
        Severity.error,
        spanish,
        'Line 2 must be the language switcher: '
        '[English]($englishName) | **Español** (an absolute URL ending in '
        '/$englishName also works).',
      ),
    );
  }

  // The English switcher may follow a title and badges (AGENTS.md README
  // order), so any line near the top counts.
  final hasEnglishSwitcher = _lines(englishFile)
      .take(englishSwitcherWindow)
      .any(
        (l) => l.contains('**English**') && _linksTo(l, 'Español', spanishName),
      );
  if (!hasEnglishSwitcher) {
    findings.add(
      Finding(
        Severity.error,
        english,
        'One of the first $englishSwitcherWindow lines must be the language '
        'switcher: **English** | [Español]($spanishName) (an absolute URL '
        'ending in /$spanishName also works).',
      ),
    );
  }
  return findings;
}

/// Checks every `*.es.md` that git tracks or would track (untracked files
/// count, ignored ones do not), under [root].
List<Finding> checkAll(String root, {BlobHasher? hashBlob}) {
  final hasher = hashBlob ?? gitBlobHasher(root);
  final spanish = _git(root, [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '--',
    '*.es.md',
  ]).split('\n').where((l) => l.isNotEmpty).toSet().toList()..sort();
  return [
    for (final file in spanish)
      // A tracked file deleted in the working tree is not a translation.
      if (File('$root/$file').existsSync()) ...checkPair(root, file, hasher),
  ];
}

/// A [BlobHasher] that asks git, honouring `.gitattributes` via `--path`.
BlobHasher gitBlobHasher(String root) =>
    (path) => _git(root, ['hash-object', '--path=$path', '--', path]).trim();

String _git(String root, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: root);
  if (result.exitCode != 0) {
    throw ProcessException('git', args, '${result.stderr}', result.exitCode);
  }
  return '${result.stdout}';
}

List<String> _lines(File file) => file
    .readAsStringSync()
    .replaceAll('\r\n', '\n')
    .split('\n')
    .map((l) => l.trimRight())
    .toList();

/// Whether [line] has a Markdown link labelled [label] whose target is
/// [fileName] or ends in `/fileName`.
bool _linksTo(String line, String label, String fileName) {
  final link = RegExp('\\[${RegExp.escape(label)}\\]\\(([^)\\s]+)\\)');
  return link.allMatches(line).any((m) {
    final target = m.group(1)!;
    return target == fileName || target.endsWith('/$fileName');
  });
}

String _short(String sha) => sha.substring(0, 12);

void main(List<String> args) {
  if (args.isNotEmpty) {
    stderr.writeln('usage: dart tool/check_translations.dart');
    exit(64);
  }
  final root = _git(Directory.current.path, [
    'rev-parse',
    '--show-toplevel',
  ]).trim();
  final findings = checkAll(root);
  for (final finding in findings) {
    stdout.writeln(finding.toWorkflowCommand());
  }
  final errors = findings.where((f) => f.severity == Severity.error).length;
  final stale = findings.length - errors;
  stdout.writeln(
    findings.isEmpty
        ? 'translations: all in sync'
        : 'translations: $errors error(s), $stale stale',
  );
  if (errors > 0) exit(1);
}
