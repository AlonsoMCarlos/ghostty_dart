// Tests for tool/xterm_compat (the COMPATIBILITY.md generator): fail-closed
// pinning, signature comparison, status merging, staleness. Run with
// `dart tool/test/xterm_compat_test.dart` from the repository root
// (`mise run test:tool`).
//
// The analyzer runs on small fixture libraries written to a temp directory
// (dart:core only, no package config), never on xterm: the real snapshot is
// covered by `mise run compat:snapshot` and the real report by
// `mise run compat:check`.

import 'dart:async';
import 'dart:io';

import '../xterm_compat/compat.dart';
import '../xterm_compat/src/compare.dart';
import '../xterm_compat/src/extract.dart';
import '../xterm_compat/src/model.dart';
import '../xterm_compat/src/pin.dart';

var _passed = 0;
final _failed = <String>[];
final _temps = <Directory>[];

Future<void> test(String name, Future<void> Function() body) async {
  try {
    await body();
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

Future<void> expectThrows<T extends Object>(
  FutureOr<void> Function() body,
  String what, [
  bool Function(T)? check,
]) async {
  try {
    await body();
  } on T catch (e) {
    if (check != null && !check(e)) throw StateError('wrong $T ($e): $what');
    return;
  }
  throw StateError('expected $T: $what');
}

Directory _temp() {
  final dir = Directory.systemTemp.createTempSync('xterm_compat_');
  _temps.add(dir);
  return dir;
}

void _write(Directory dir, Map<String, String> files) {
  for (final MapEntry(key: path, value: text) in files.entries) {
    File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }
}

// The reference package ("xterm") and a matching adapter.
const _refCore = '''
export 'src/a.dart';
''';
const _refXterm = '''
export 'core.dart';
''';
const _refA = '''
class Foo {
  Foo({int x = 1, String? name});
  const Foo.fixed(this.v);
  int v = 0;
  final int ro = 1;
  static const k = 1;
  void bar(String s, [int n = 0]) {}
  int baz() => 0;
  bool operator ==(Object other) => false;
  int get hashCode => 0;
}
enum Color { red, green, blue }
typedef Callback = void Function(int code);
const defaultFoo = Foo.fixed(1);
int topLevel(int a) => a;
abstract class Base { void run(); }
class Impl extends Base { @override void run() {} }
''';

/// [_refA] with [edits] (from -> to) applied.
String _ours(Map<String, String> edits) {
  var text = _refA;
  for (final MapEntry(:key, :value) in edits.entries) {
    if (!text.contains(key)) throw StateError('fixture has no "$key"');
    text = text.replaceFirst(key, value);
  }
  return text;
}

/// Writes a package with `lib/core.dart`, `lib/xterm.dart` and
/// `lib/src/a.dart` = [a] and extracts it.
Future<(ApiModel, Directory)> _package(
  String a, {
  bool withXterm = true,
  String core = _refCore,
  bool reference = false,
}) async {
  final dir = _temp();
  _write(dir, {
    'lib/core.dart': core,
    if (withXterm) 'lib/xterm.dart': _refXterm,
    'lib/src/a.dart': a,
  });
  final model = await extractApi(
    analysisRoot: dir.path,
    libraries: _libs(dir),
    ownUriPrefix: Uri.directory('${dir.path}/lib').toString(),
    // The reference side (the snapshot) leaves out what Object declares.
    keepForeign: !reference,
  );
  return (model, dir);
}

Map<String, String> _libs(Directory dir) => {
  for (final lib in libraryOrder)
    lib: Uri.file('${dir.path}/lib/$lib').toString(),
};

Future<ApiModel> _ref() async => (await _package(_refA, reference: true)).$1;

Row _row(Comparison c, String key) => c.rows.firstWhere((r) => r.key == key);

const _lockStanza = '''
packages:
  xdg_directories:
    dependency: transitive
    description:
      name: xdg_directories
      sha256: "7a3f37b05d989967cdddcbb571f1ea834867ae2faa29725fd085180e0883aa15"
      url: "https://pub.dev"
    source: hosted
    version: "1.1.0"
  xterm:
    dependency: transitive
    description:
      name: xterm
      sha256: "168dfedca77cba33fdb6f52e2cd001e9fde216e398e89335c19b524bb22da3a2"
      url: "https://pub.dev"
    source: hosted
    version: "4.0.0"
sdks:
  dart: ">=3.11.0 <4.0.0"
''';

/// A fake workspace: pubspec.lock, a package config resolving xterm to
/// `<cache>/xterm-4.0.0` and one file in its lib/.
Directory _workspace({
  String lock = _lockStanza,
  String dirName = 'xterm-4.0.0',
}) {
  final root = _temp();
  final xterm = Directory('${root.path}/cache/$dirName')
    ..createSync(recursive: true);
  _write(xterm, {'lib/xterm.dart': "export 'core.dart';\n"});
  _write(root, {
    'pubspec.lock': lock,
    '.dart_tool/package_config.json':
        '{"configVersion": 2, "packages": [{"name": "xterm", '
        '"rootUri": "../cache/$dirName", "packageUri": "lib/"}]}',
  });
  return root;
}

Future<void> main() async {
  // --- pinning ---------------------------------------------------------------

  await test('lock check accepts the pinned xterm entry', () async {
    checkLock(_lockStanza);
  });

  await test(
    'lock check fails closed on sha256, version, source, absence',
    () async {
      for (final bad in [
        _lockStanza.replaceFirst('168dfedc', '000dfedc'),
        _lockStanza.replaceFirst('version: "4.0.0"', 'version: "4.0.1"'),
        _lockStanza.replaceFirst(
          'https://pub.dev"\n    source: hosted\n    version: "4',
          'https://evil.example"\n    source: hosted\n    version: "4',
        ),
        _lockStanza.replaceFirst('  xterm:', '  xterm2:'),
      ]) {
        await expectThrows<PinError>(() => checkLock(bad), 'a bad lock entry');
      }
    },
  );

  await test(
    'lib tree hash equals `find lib -type f | LC_ALL=C sort` + sha256sum',
    () async {
      final dir = _temp();
      _write(dir, {
        'lib/b.dart': 'b\n',
        'lib/a/z.dart': 'z\n',
        // Upper case sorts before lower case under LC_ALL=C. No two names
        // differ only by case: macOS and Windows file systems would merge them.
        'lib/C.dart': 'C\n',
      });
      // Computed with: cd <dir> && find lib -type f | LC_ALL=C sort | while
      // read f; do printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)"
      // "$f"; done | sha256sum
      const expected =
          'bfc95f3f4d3cf53e99dbc886893cb30467ea939eeb4ae151c407f1f0ff8dd68e';
      final actual = libTreeSha256(Directory('${dir.path}/lib'));
      expect(actual == expected, 'hash $actual');
    },
  );

  await test(
    'verifyXterm passes on matching pins and fails on a tampered tree',
    () async {
      final root = _workspace();
      final good = libTreeSha256(
        Directory('${root.path}/cache/xterm-4.0.0/lib'),
      );
      verifyXterm(root.path, libSha256: good);
      File(
        '${root.path}/cache/xterm-4.0.0/lib/extra.dart',
      ).writeAsStringSync('// planted\n');
      await expectThrows<PinError>(
        () => verifyXterm(root.path, libSha256: good),
        'an extra file in lib/',
      );
    },
  );

  await test(
    'verifyXterm fails when the package config points elsewhere',
    () async {
      final root = _workspace(dirName: 'xterm-4.0.1');
      await expectThrows<PinError>(
        () => verifyXterm(root.path, libSha256: 'x'),
        'a different xterm directory',
      );
    },
  );

  await test('the real pins are the archive sha256 in pubspec.lock', () async {
    final lock = File('pubspec.lock').readAsStringSync();
    checkLock(lock);
  });

  await test('a snapshot taken under other pins is refused', () async {
    final text = encodeSnapshot(ApiModel({}));
    decodeSnapshot(text);
    await expectThrows<PinError>(
      () => decodeSnapshot(text.replaceFirst(xtermLibSha256, '0' * 64)),
      'a snapshot with another lib hash',
    );
  });

  // --- extraction and comparison -------------------------------------------

  final ref = await _ref();

  await test('extraction finds symbols, libraries and members', () async {
    final foo = ref.symbols['Foo']!;
    expect(
      foo.libraries.join(',') == 'core.dart,xterm.dart',
      'libraries ${foo.libraries}',
    );
    expect(
      {
        'new',
        'fixed',
        'v',
        'ro',
        'k',
        'bar',
        'baz',
        '==',
        'hashCode',
      }.every(foo.members.containsKey),
      'members ${foo.members.keys}',
    );
    expect(!foo.members.containsKey('toString'), 'Object members left out');
    expect(foo.members['ro']!.sig['set'] == false, 'final field is read-only');
    expect(foo.members['v']!.sig['set'] == true, 'field is assignable');
    expect(
      ref.symbols['Color']!.members['blue']!.sig['index'] == 2,
      'enum index',
    );
    expect(ref.symbols['defaultFoo']!.sig['const'] == true, 'const variable');
    expect(ref.symbols['Impl']!.members.containsKey('run'), 'inherited member');
  });

  await test(
    'an identical adapter is all ✅ and the snapshot round-trips',
    () async {
      final roundTrip = decodeSnapshot(encodeSnapshot(ref));
      final (ours, _) = await _package(_refA);
      final c = compare(roundTrip, ours, {});
      expect(c.rows.every((r) => r.status == Status.same), 'all same');
      expect(
        ours.symbols['Foo']!.members['toString']!.foreign,
        'Object.toString kept as foreign on our side',
      );
      expect(c.additions.isEmpty, 'foreign members are no additions');
    },
  );

  await test('overrides of SDK or Flutter members are no additions', () async {
    // TerminalController.dispose (ChangeNotifier) and
    // TerminalViewState.didChangeDependencies (State) are declared in the
    // adapter but inherited in xterm: present either way, never "additions".
    final (ours, _) = await _package(
      _ours({
        'int baz() => 0;':
            'int baz() => 0;\n'
            '  @override\n'
            '  String toString() => "Foo";\n'
            '  @override\n'
            '  dynamic noSuchMethod(Invocation i) => null;\n'
            '  void extra() {}',
        'class Impl extends Base { @override void run() {} }':
            'class Impl extends Base implements Comparable<Impl> {\n'
            '  @override void run() {}\n'
            '  @override int compareTo(Impl other) => 0;\n'
            '}',
      }),
    );
    final foo = ours.symbols['Foo']!;
    expect(foo.members['toString']!.foreign, 'Object override is foreign');
    expect(foo.members['noSuchMethod']!.foreign, 'idem noSuchMethod');
    expect(
      ours.symbols['Impl']!.members['compareTo']!.foreign,
      'SDK interface member is foreign',
    );
    expect(!foo.members['extra']!.foreign, 'own member is not foreign');
    expect(!foo.members['baz']!.foreign, 'own member matching xterm');
    final c = compare(ref, ours, {});
    expect(
      c.additions.keys.join(',') == 'Foo.extra',
      'only the own member is an addition: ${c.additions.keys}',
    );
    expect(c.rows.every((r) => r.status == Status.same), 'all same');
  });

  await test('signature mismatches are ⚠️ automatically', () async {
    final (ours, _) = await _package(
      _ours({
        'Foo({int x = 1,': 'Foo({int x = 2,',
        'const Foo.fixed': 'Foo.fixed',
        'void bar(String s, [int n = 0])': 'void bar(String s)',
        'int baz()': 'num baz()',
        'final int ro = 1;': 'int get ro => 1;',
        'int v = 0;': 'int get v => 0;',
        'enum Color { red, green, blue }': 'enum Color { red, blue, green }',
      }),
    );
    final c = compare(ref, ours, {});
    for (final (key, fragment) in [
      ('Foo.new', '`x` defaults to `2`'),
      ('Foo.fixed', 'not const'),
      ('Foo.bar', 'parameter 2 (`n`) missing'),
      ('Foo.baz', 'returns `num`'),
      ('Foo.v', 'read-only'),
      ('Color.blue', 'index 1'),
    ]) {
      final row = _row(c, key);
      expect(row.status == Status.differs, '$key is ⚠️ (${row.status})');
      expect(
        row.note.contains(fragment),
        '$key note "${row.note}" has "$fragment"',
      );
    }
    expect(
      _row(c, 'Foo.ro').status == Status.same,
      'getter for final field is ✅',
    );
  });

  await test(
    'additive changes stay ✅ with a note and are listed as additions',
    () async {
      final (ours, _) = await _package(
        _ours({
          'String? name})': 'String? name, int? extra})',
          'int baz() => 0;': 'int baz() => 0;\n  void dispose() {}',
        }),
      );
      final c = compare(ref, ours, {});
      final ctor = _row(c, 'Foo.new');
      expect(
        ctor.status == Status.same && ctor.note.contains('adds `extra`'),
        'ctor ${ctor.note}',
      );
      expect(
        c.additions['Foo.dispose'] == 'method',
        'additions ${c.additions}',
      );
    },
  );

  await test('a required parameter the caller does not pass is ⚠️', () async {
    final (ours, _) = await _package(
      _ours({'String? name})': 'String? name, required int extra})'}),
    );
    final row = _row(compare(ref, ours, {}), 'Foo.new');
    expect(
      row.status == Status.differs,
      'required named addition breaks callers',
    );
  });

  await test(
    'missing members default to ❌ planned and cascade from entries',
    () async {
      final (ours, _) = await _package(
        _ours({
          'int baz() => 0;': '',
          'typedef Callback = void Function(int code);': '',
        }),
      );
      final c = compare(ref, ours, {
        'Foo.baz': StatusEntry(Status.wont, 'not needed'),
      });
      expect(_row(c, 'Foo.baz').status == Status.wont, 'explicit 🚫');
      expect(_row(c, 'Callback').status == Status.missing, 'default ❌');
      expect(_row(c, 'Callback').note == defaultMissingReason, 'default note');

      final (none, _) = await _package('');
      final c2 = compare(ref, none, {
        'core.dart': StatusEntry(Status.missing, 'later'),
        'Foo': StatusEntry(Status.wont, 'never'),
      });
      expect(_row(c2, 'Foo.bar').status == Status.wont, 'symbol cascade wins');
      expect(
        _row(c2, 'Color.red').status == Status.missing &&
            _row(c2, 'Color.red').note == 'later',
        'library cascade',
      );
    },
  );

  await test('a symbol not exported from xterm.dart is ⚠️', () async {
    final (ours, _) = await _package(_refA, withXterm: false);
    final row = _row(compare(ref, ours, {}), 'Foo');
    expect(
      row.status == Status.differs &&
          row.note.contains('not exported from xterm.dart'),
      row.note,
    );
  });

  await test(
    'a differs entry turns a matching member ⚠️ and annotates a missing one',
    () async {
      final (ours, _) = await _package(_ours({'int baz() => 0;': ''}));
      final c = compare(ref, ours, {
        'Foo.bar': StatusEntry(Status.differs, 'behaves differently'),
        'Foo.baz': StatusEntry(Status.differs, 'will differ'),
      });
      expect(_row(c, 'Foo.bar').status == Status.differs, 'behaviour ⚠️');
      expect(
        _row(c, 'Foo.baz').status == Status.missing &&
            _row(c, 'Foo.baz').note.contains('will differ'),
        'pre-recorded',
      );
    },
  );

  // --- status file errors --------------------------------------------------

  await test('an unknown status key is an error (typo guard)', () async {
    await expectThrows<StatusError>(
      () =>
          compare(ref, ref, {'Foo.barr': StatusEntry(Status.missing, 'typo')}),
      'unknown key',
      (e) => e.problems.single.startsWith('Foo.barr'),
    );
  });

  await test(
    'a missing/wont entry on a present member is an error (stale)',
    () async {
      await expectThrows<StatusError>(
        () => compare(ref, ref, {'Foo.bar': StatusEntry(Status.wont, 'old')}),
        'stale entry',
      );
    },
  );

  await test('malformed status files are errors', () async {
    for (final bad in [
      '[]',
      '{"entries": {"Foo": {"status": "same", "reason": "x"}}}',
      '{"entries": {"Foo": {"status": "wont", "reason": " "}}}',
      '{"entries": {"Foo": {"status": "wont", "reason": "x", "note": "y"}}}',
      '{"entries": {}, "extra": 1}',
    ]) {
      await expectThrows<StatusError>(() => parseStatus(bad), bad);
    }
    final ok = parseStatus(
      '{"comment": "c", "entries": {"Foo": {"status": "differs", "reason": "r"}}}',
    );
    expect(ok['Foo']!.status == Status.differs, 'parsed');
  });

  // --- report and staleness --------------------------------------------------

  await test('the report is stale once the adapter changes', () async {
    final (_, dir) = await _package(_refA);
    final out = File('${_temp().path}/COMPATIBILITY.md');
    Future<String> render() => renderFor(
      xterm: ref,
      analysisRoot: dir.path,
      ourLibraries: _libs(dir),
      ourUriPrefix: Uri.directory('${dir.path}/lib').toString(),
      statusText: '{"entries": {}}',
    );
    final first = await render();
    out.writeAsStringSync(first);
    expect(isCurrent(out, await render()), 'current after write');
    expect(
      first.contains(
        '| **All** | **${ref.size}** | **0** | **0** | **0** | **${ref.size}** |',
      ),
      'summary row',
    );
    _write(dir, {
      'lib/src/a.dart': _ours({'int baz() => 0;': ''}),
    });
    final second = await render();
    expect(!isCurrent(out, second), 'stale after the adapter changed');
    expect(
      second.contains('| `baz()` | method | ❌ | planned |'),
      'missing row',
    );
  });

  for (final dir in _temps) {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }
  stdout.writeln('\n$_passed passed, ${_failed.length} failed');
  if (_failed.isNotEmpty) exitCode = 1;
}
