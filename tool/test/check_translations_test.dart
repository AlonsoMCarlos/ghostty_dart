// Tests for tool/check_translations.dart. Run with
// `dart tool/test/check_translations_test.dart` from the repository root.
//
// A tiny harness instead of package:test, like tool/native/test/tool_test.dart:
// the workspace root (which owns tool/) depends on nothing but lints. Each
// test builds a throwaway git repository in a temp directory, so the real
// `git hash-object` and `git ls-files` are exercised.

import 'dart:io';

import '../check_translations.dart';

var _passed = 0;
final _failed = <String>[];
final _temps = <Directory>[];

void test(String name, void Function() body) {
  try {
    body();
    _passed++;
    stdout.writeln('ok   $name');
  } catch (e, s) {
    _failed.add(name);
    stdout.writeln(
      'FAIL $name\n  $e\n${s.toString().split('\n').take(4).join('\n')}',
    );
  }
}

void expect(bool condition, String what) {
  if (!condition) throw StateError('expected: $what');
}

/// A fresh git repository with [files] (path → content) written into it.
String _repo(Map<String, String> files) {
  final dir = Directory.systemTemp.createTempSync('check_translations_');
  _temps.add(dir);
  _run(dir.path, ['init', '-q']);
  files.forEach((path, content) => _write(dir.path, path, content));
  return dir.path;
}

void _write(String root, String path, String content) {
  final file = File('$root/$path');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

String _run(String root, List<String> args) {
  final r = Process.runSync('git', args, workingDirectory: root);
  if (r.exitCode != 0) throw StateError('git $args: ${r.stderr}');
  return '${r.stdout}'.trim();
}

String _hash(String root, String path) =>
    _run(root, ['hash-object', '--path=$path', '--', path]);

const _english = '**English** | [Español](README.es.md)\n\n# Title\n';

String _spanish(String sha, {String name = 'README.md'}) =>
    '<!-- source: $name@$sha -->\n'
    '[English](README.md) | **Español**\n\n# Título\n';

/// A repo with an English README and a Spanish one in sync with it.
String _inSync([String dir = '']) {
  final root = _repo({'${dir}README.md': _english});
  _write(root, '${dir}README.es.md', _spanish(_hash(root, '${dir}README.md')));
  return root;
}

List<Finding> _check(String root) => checkAll(root);

bool _only(List<Finding> f, Severity s, String file, String text) =>
    f.length == 1 &&
    f.single.severity == s &&
    f.single.file == file &&
    f.single.message.contains(text);

void main() {
  test('in-sync pair has no findings', () {
    expect(_check(_inSync()).isEmpty, 'no findings');
  });

  test('nested pair is found and checked', () {
    final root = _inSync('packages/pkg/');
    expect(_check(root).isEmpty, 'no findings for nested pair');
    _write(root, 'packages/pkg/README.md', '$_english\nMore.\n');
    expect(
      _only(
        _check(root),
        Severity.stale,
        'packages/pkg/README.es.md',
        'behind',
      ),
      'stale warning for the nested pair',
    );
  });

  test('changed English is stale, with the new sha in the hint', () {
    final root = _inSync();
    _write(root, 'README.md', '$_english\nNew paragraph.\n');
    final f = _check(root);
    expect(
      _only(f, Severity.stale, 'README.es.md', _hash(root, 'README.md')),
      'one stale finding with the new sha: ${f.map((e) => e.message)}',
    );
    expect(
      f.single.toWorkflowCommand().startsWith(
        '::warning file=README.es.md,line=1::',
      ),
      'GitHub warning syntax',
    );
  });

  test('committed and uncommitted content hash the same', () {
    final root = _inSync();
    _run(root, ['add', '.']);
    _run(root, [
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@example.com',
      'commit',
      '-qm',
      'init',
    ]);
    expect(
      _run(root, ['rev-parse', 'HEAD:README.md']) == _hash(root, 'README.md'),
      'hash-object equals the committed blob',
    );
    expect(_check(root).isEmpty, 'still in sync after committing');
  });

  test('CRLF working copy hashes like LF with eol=lf attributes', () {
    final root = _inSync();
    _write(root, '.gitattributes', '* text=auto eol=lf\n');
    final lfSha = _hash(root, 'README.md');
    _write(root, 'README.md', _english.replaceAll('\n', '\r\n'));
    expect(_hash(root, 'README.md') == lfSha, 'same blob for CRLF');
    expect(_check(root).isEmpty, 'CRLF copy is not stale');
  });

  test('missing header is an error', () {
    final root = _repo({
      'README.md': _english,
      'README.es.md': '[English](README.md) | **Español**\n\n# Título\n',
    });
    expect(
      _check(root).any(
        (f) =>
            f.severity == Severity.error &&
            f.message.contains('Line 1 must be') &&
            f.message.contains(_hash(root, 'README.md')),
      ),
      'error naming the expected header',
    );
  });

  test('malformed header (short sha) is an error', () {
    final root = _repo({
      'README.md': _english,
      'README.es.md': _spanish('abc1234'),
    });
    expect(
      _only(_check(root), Severity.error, 'README.es.md', 'Line 1 must be'),
      'malformed header error',
    );
  });

  test('header naming another file is an error', () {
    final root = _repo({'README.md': _english});
    _write(
      root,
      'README.es.md',
      _spanish(_hash(root, 'README.md'), name: 'OTHER.md'),
    );
    expect(
      _only(_check(root), Severity.error, 'README.es.md', '"OTHER.md"'),
      'wrong source name error',
    );
  });

  test('translation without English source is an error', () {
    final root = _repo({'GONE.es.md': _spanish('a' * 40, name: 'GONE.md')});
    expect(
      _only(_check(root), Severity.error, 'GONE.es.md', 'does not exist'),
      'missing English error',
    );
  });

  test('missing switchers are errors in both files', () {
    final root = _repo({'README.md': '# Title\n'});
    _write(
      root,
      'README.es.md',
      '<!-- source: README.md@${_hash(root, 'README.md')} -->\n# Título\n',
    );
    final f = _check(root);
    expect(
      f.length == 2 &&
          f.every((e) => e.severity == Severity.error) &&
          f.any((e) => e.file == 'README.es.md') &&
          f.any((e) => e.file == 'README.md'),
      'two switcher errors: ${f.map((e) => '${e.file}: ${e.message}')}',
    );
  });

  test('English switcher may follow a title and badges', () {
    final root = _repo({
      'README.md': '# T\n\n[![b](https://x/b.svg)](https://x)\n\n$_english',
    });
    _write(root, 'README.es.md', _spanish(_hash(root, 'README.md')));
    expect(_check(root).isEmpty, 'switcher after the badges accepted');
  });

  test('English switcher too far down is an error', () {
    final root = _repo({'README.md': '${'line\n' * 25}$_english'});
    _write(root, 'README.es.md', _spanish(_hash(root, 'README.md')));
    expect(
      _only(_check(root), Severity.error, 'README.md', 'first 20 lines'),
      'switcher outside the window',
    );
  });

  test('absolute switcher URLs are accepted', () {
    const base = 'https://github.com/o/r/blob/main/packages/p';
    final root = _repo({
      'README.md': '**English** | [Español]($base/README.es.md)\n\n# T\n',
    });
    _write(
      root,
      'README.es.md',
      '<!-- source: README.md@${_hash(root, 'README.md')} -->\n'
          '[English]($base/README.md) | **Español**\n',
    );
    expect(_check(root).isEmpty, 'absolute links accepted');
  });

  test('gitignored translations are skipped', () {
    final root = _inSync();
    _write(root, '.gitignore', 'ignored/\n');
    _write(root, 'ignored/X.es.md', 'no header\n');
    expect(_check(root).isEmpty, 'ignored file skipped');
  });

  test('englishPathFor strips only the .es suffix', () {
    expect(englishPathFor('a/b/X.es.md') == 'a/b/X.md', 'path mapping');
    expect(englishPathFor('X.es.es.md') == 'X.es.md', 'only the last .es');
  });

  for (final dir in _temps) {
    dir.deleteSync(recursive: true);
  }
  stdout.writeln('\n$_passed passed, ${_failed.length} failed');
  if (_failed.isNotEmpty) {
    stdout.writeln('failed: ${_failed.join(', ')}');
    exitCode = 1;
  }
}
