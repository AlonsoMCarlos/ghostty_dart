// Tests for the native release tools: the binary checker
// (src/binary_check.dart), the pin logic (src/pin.dart) and the consistency of
// native/prebuilt_assets.json. Run with `mise run test:tool` (part of `check`).
//
// A tiny harness instead of package:test: these tools live outside every
// package, and the workspace root (which owns tool/) depends on nothing but
// lints. Synthetic ELF, PE and Mach-O files are built in memory, so the tests
// need no native build; the real binaries are covered by `native:check` in
// CI (host build) and in the release pipeline (every asset).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../src/binary_check.dart';
import '../src/pin.dart';

var _passed = 0;
final _failed = <String>[];

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

void expectThrows<T extends Object>(void Function() body, String what) {
  try {
    body();
  } on T {
    return;
  }
  throw StateError('expected ${T.toString()}: $what');
}

const _api = {'ghostty_terminal_new', 'ghostty_terminal_free'};
const _floors = Floors(glibc: (2, 28), apple: 13);

List<CheckLine> _check(String asset, Uint8List bytes) =>
    checkBinary(asset: asset, bytes: bytes, api: _api, floors: _floors);

bool _allOk(List<CheckLine> lines) => lines.every((l) => l.ok);

/// The failed lines' text, for assertions and messages.
String _failures(List<CheckLine> lines) =>
    lines.where((l) => !l.ok).map((l) => l.text).join(' | ');

void main() {
  final root = File.fromUri(Platform.script).parent.parent.parent.parent.path;

  // --- ELF -----------------------------------------------------------------

  test('ELF64 Linux x64: a well-formed library passes', () {
    final lines = _check('libghostty-vt-linux-x64.so', elf());
    expect(_allOk(lines), 'all ok, got ${_failures(lines)}');
  });

  test('ELF: GLIBC symbol version above the floor fails', () {
    final lines = _check(
      'libghostty-vt-linux-x64.so',
      elf(verneeds: ['GLIBC_2.2.5', 'GLIBC_2.29']),
    );
    expect(_failures(lines).contains('GLIBC symbol version 2.29'), 'glibc');
  });

  test('ELF: wrong architecture for the name fails', () {
    final lines = _check('libghostty-vt-linux-arm64.so', elf());
    expect(_failures(lines).contains('architecture x64'), 'arch');
  });

  test('ELF: missing and undeclared exports fail', () {
    final lines = _check(
      'libghostty-vt-linux-x64.so',
      elf(exports: ['ghostty_terminal_new', 'ghostty_secret']),
    );
    final f = _failures(lines);
    expect(f.contains('missing: ghostty_terminal_free'), 'missing: $f');
    expect(f.contains('undeclared: ghostty_secret'), 'undeclared: $f');
  });

  test('ELF: an unexpected NEEDED library fails', () {
    final lines = _check(
      'libghostty-vt-linux-x64.so',
      elf(needed: ['libc.so.6', 'libstdc++.so.6']),
    );
    expect(_failures(lines).contains('unexpected: libstdc++.so.6'), 'deps');
  });

  test('ELF Android: 4 KiB LOAD alignment fails, 16 KiB passes', () {
    final android = ['libc.so', 'libm.so'];
    final bad = _check(
      'libghostty-vt-android-x64.so',
      elf(needed: android, verneeds: [], aligns: [0x4000, 0x1000]),
    );
    expect(_failures(bad).contains('PT_LOAD alignments'), 'align');
    final good = _check(
      'libghostty-vt-android-x64.so',
      elf(needed: android, verneeds: [], aligns: [0x4000]),
    );
    expect(_allOk(good), 'android ok, got ${_failures(good)}');
  });

  test(
    'ELF32 armv7: NEON + VFPv3 softfp passes; missing NEON or hard-float fails',
    () {
      Uint8List arm(Map<int, int> attrs) => elf(
        is64: false,
        machine: 40,
        needed: ['libc.so'],
        verneeds: [],
        aligns: [0x4000],
        armAttributes: armAttributes(attrs),
      );
      const good = {6: 10, 10: 3, 12: 1};
      final ok = _check('libghostty-vt-android-arm.so', arm(good));
      expect(_allOk(ok), 'arm ok, got ${_failures(ok)}');
      final noNeon = _check(
        'libghostty-vt-android-arm.so',
        arm({6: 10, 10: 3}),
      );
      expect(_failures(noNeon).contains('Advanced_SIMD_arch=null'), 'neon');
      final hard = _check(
        'libghostty-vt-android-arm.so',
        arm({...good, 28: 1}),
      );
      expect(_failures(hard).contains('softfp'), 'softfp');
    },
  );

  test(
    'ELF32 armv7: a zero-size attributes subsection is rejected, not looped on',
    () {
      // 'A', section length, "aeabi\0", Tag_File = 1, size 0.
      final attrs = Uint8List.fromList([
        0x41, 16, 0, 0, 0, ...ascii.encode('aeabi'), 0, 1, 0, 0, 0, 0, //
      ]);
      final bytes = elf(
        is64: false,
        machine: 40,
        needed: ['libc.so'],
        verneeds: [],
        aligns: [0x4000],
        armAttributes: attrs,
      );
      final lines = _check('libghostty-vt-android-arm.so', bytes);
      expect(
        _failures(lines).contains('not a valid elf file'),
        _failures(lines),
      );
    },
  );

  test('ELF: section and header tables outside the file are rejected', () {
    final bytes = elf();
    final b = ByteData.sublistView(bytes);
    b.setUint64(40, bytes.length + 100, Endian.little); // e_shoff
    expect(!_allOk(_check('libghostty-vt-linux-x64.so', bytes)), 'shoff');
    final b2 = elf();
    ByteData.sublistView(b2).setUint16(56, 0xffff, Endian.little); // e_phnum
    expect(!_allOk(_check('libghostty-vt-linux-x64.so', b2)), 'phnum');
  });

  // --- PE ------------------------------------------------------------------

  test('PE x64: a well-formed DLL passes', () {
    final lines = _check('ghostty-vt-windows-x64.dll', pe());
    expect(_allOk(lines), 'all ok, got ${_failures(lines)}');
  });

  test('PE: arm64 DLL named x64 fails; a non-system import fails', () {
    final arm = _check('ghostty-vt-windows-x64.dll', pe(machine: 0xaa64));
    expect(_failures(arm).contains('architecture arm64'), 'arch');
    final dep = _check(
      'ghostty-vt-windows-x64.dll',
      pe(imports: ['KERNEL32.dll', 'libwinpthread-1.dll']),
    );
    expect(_failures(dep).contains('unexpected: libwinpthread-1.dll'), 'dep');
  });

  test('PE: an export count beyond the file is rejected', () {
    final bytes = pe();
    // Export directory at raw 0x200; NumberOfNames at +24.
    ByteData.sublistView(
      bytes,
    ).setUint32(0x200 + 24, 0x7fffffff, Endian.little);
    final lines = _check('ghostty-vt-windows-x64.dll', bytes);
    expect(_failures(lines).contains('not a valid pe file'), _failures(lines));
  });

  // --- Mach-O --------------------------------------------------------------

  test('Mach-O macOS arm64: a well-formed dylib passes', () {
    final lines = _check('libghostty-vt-macos-arm64.dylib', macho());
    expect(_allOk(lines), 'all ok, got ${_failures(lines)}');
  });

  test('Mach-O: platform and minimum OS are checked', () {
    final ios = _check('libghostty-vt-ios-arm64.dylib', macho());
    expect(_failures(ios).contains('platform macos (expected ios)'), 'ios');
    final sim = _check(
      'libghostty-vt-ios-arm64-simulator.dylib',
      macho(platform: 7),
    );
    expect(_allOk(sim), 'simulator ok, got ${_failures(sim)}');
    final newer = _check(
      'libghostty-vt-macos-arm64.dylib',
      macho(minOs: 14 << 16),
    );
    expect(_failures(newer).contains('minimum OS 14.0'), 'minos');
  });

  test('Mach-O: cmdsize 0 with a huge ncmds is rejected at once', () {
    final bytes = macho();
    final b = ByteData.sublistView(bytes);
    b.setUint32(16, 0xffffffff, Endian.little); // ncmds
    expect(!_allOk(_check('libghostty-vt-macos-arm64.dylib', bytes)), 'ncmds');
    final b2 = macho();
    ByteData.sublistView(b2).setUint32(32 + 4, 0, Endian.little); // cmdsize
    final lines = _check('libghostty-vt-macos-arm64.dylib', b2);
    expect(_failures(lines).contains('bad size 0'), _failures(lines));
  });

  test('Mach-O: an export trie that loops is rejected', () {
    final lines = _check(
      'libghostty-vt-macos-arm64.dylib',
      macho(loopTrie: true),
    );
    expect(_failures(lines).contains('export trie loops'), _failures(lines));
  });

  // --- Robustness: truncations and mutations never throw or hang -----------

  final samples = {
    'libghostty-vt-linux-x64.so': elf(),
    'libghostty-vt-android-arm.so': elf(
      is64: false,
      machine: 40,
      needed: ['libc.so'],
      verneeds: [],
      aligns: [0x4000],
      armAttributes: armAttributes({6: 10, 10: 3, 12: 1}),
    ),
    'ghostty-vt-windows-x64.dll': pe(),
    'libghostty-vt-macos-arm64.dylib': macho(),
  };
  for (final MapEntry(key: asset, value: bytes) in samples.entries) {
    test('$asset: every truncation is reported, never thrown', () {
      for (var n = 0; n < bytes.length; n++) {
        final lines = _check(asset, Uint8List.sublistView(bytes, 0, n));
        expect(lines.isNotEmpty, 'a result for length $n');
      }
    });
    test('$asset: 3000 random mutations are reported, never thrown', () {
      final random = Random(42);
      for (var i = 0; i < 3000; i++) {
        final mutated = Uint8List.fromList(bytes);
        for (var k = 0; k < 1 + random.nextInt(4); k++) {
          mutated[random.nextInt(mutated.length)] = random.nextInt(256);
        }
        _check(asset, mutated);
      }
    });
  }

  test('random bytes are rejected for every format', () {
    final random = Random(7);
    final bytes = Uint8List.fromList(
      List.generate(4096, (_) => random.nextInt(256)),
    );
    for (final asset in samples.keys) {
      expect(!_allOk(_check(asset, bytes)), asset);
    }
  });

  // --- Names and headers ---------------------------------------------------

  test('asset names outside ADR 0008 are rejected', () {
    expectThrows<FormatException>(
      () => Expected.fromAssetName('libfoo.so'),
      'libfoo.so',
    );
  });

  test('declaredApi skips comments and wasm.h', () {
    final api = declaredApi([
      (
        'ghostty/vt/terminal.h',
        '/** GHOSTTY_API int ghostty_foo_new(void); */\n'
            '// GHOSTTY_API int ghostty_bar(void);\n'
            'GHOSTTY_API GhosttyResult ghostty_terminal_new(\n  int x);\n',
      ),
      ('ghostty/vt/wasm.h', 'GHOSTTY_API void* ghostty_wasm_alloc(int n);'),
    ]);
    expect(api.length == 1 && api.contains('ghostty_terminal_new'), '$api');
  });

  // --- Pin -----------------------------------------------------------------

  final hex = 'ab' * 32, hex2 = 'cd' * 32;

  test('parseSums reads text and binary mode, CRLF, blank lines', () {
    final sums = parseSums('$hex  a.so\r\n\n$hex2 *b.dll\n');
    expect(
      sums.length == 2 && sums['a.so'] == hex && sums['b.dll'] == hex2,
      '$sums',
    );
  });

  test('parseSums rejects malformed lines, uppercase hex and duplicates', () {
    expectThrows<FormatException>(() => parseSums('$hex a.so'), 'one space');
    expectThrows<FormatException>(
      () => parseSums('${hex.toUpperCase()}  a.so'),
      'uppercase',
    );
    expectThrows<FormatException>(() => parseSums('abc  a.so'), 'short');
    expectThrows<FormatException>(
      () => parseSums('$hex  a.so\n$hex2  a.so'),
      'duplicate',
    );
  });

  test('requireAssetSet needs the exact set', () {
    requireAssetSet({'a': hex, 'b': hex}, {'a', 'b'});
    expectThrows<FormatException>(
      () => requireAssetSet({'a': hex}, {'a', 'b'}),
      'missing',
    );
    expectThrows<FormatException>(
      () => requireAssetSet({'a': hex, 'c': hex}, {'a'}),
      'unknown',
    );
  });

  test('validateTag accepts native-v<version>-r<n>, n >= 1, only', () {
    validateTag('native-v1.0.0-r1', '1.0.0');
    validateTag('native-v1.0.0-r12', '1.0.0');
    for (final bad in [
      'native-v1.0.0-r0',
      'native-v1.0.1-r1',
      'native-v1.0.0',
      'native-v1x0x0-r1',
      'v1.0.0-r1',
    ]) {
      expectThrows<FormatException>(() => validateTag(bad, '1.0.0'), bad);
    }
  });

  const prebuilt =
      '''
// head
$beginMarker
const prebuiltReleaseTag = 'old';
const prebuiltSha256 = <String, String>{};
$endMarker
// tail
''';

  test('replaceBlock swaps exactly the marked block, sorted, idempotent', () {
    final block = renderBlock('native-v1.0.0-r1', {'b.so': hex2, 'a.so': hex});
    final once = replaceBlock(prebuilt, block);
    expect(once.startsWith('// head\n$beginMarker\n'), 'head kept');
    expect(once.endsWith('$endMarker\n// tail\n'), 'tail kept');
    expect(once.indexOf("'a.so'") < once.indexOf("'b.so'"), 'sorted');
    expect(replaceBlock(once, block) == once, 'idempotent');
  });

  test('replaceBlock keeps CRLF line endings', () {
    final crlf = prebuilt.replaceAll('\n', '\r\n');
    final out = replaceBlock(crlf, renderBlock('t', {'a.so': hex}));
    expect(!out.replaceAll('\r\n', '').contains('\n'), 'only CRLF');
  });

  test('replaceBlock rejects missing, duplicate and inverted markers', () {
    final block = renderBlock('t', {});
    expectThrows<FormatException>(() => replaceBlock('x\n', block), 'none');
    expectThrows<FormatException>(
      () => replaceBlock('$prebuilt$beginMarker\n', block),
      'two BEGIN',
    );
    expectThrows<FormatException>(
      () => replaceBlock('$endMarker\n$beginMarker\n', block),
      'inverted',
    );
  });

  test('renderBlock is dart format-stable (empty and full)', () {
    final dir = Directory.systemTemp.createTempSync('pin-format-');
    try {
      for (final (i, sums) in [
        <String, String>{},
        {'libghostty-vt-ios-arm64-simulator.dylib': hex, 'a.so': hex2},
      ].indexed) {
        final file = File('${dir.path}/f$i.dart')
          ..writeAsStringSync(
            '${renderBlock('native-v1.0.0-r1', sums)}\n'.replaceFirst(
              '[PrebuiltTarget.fileName]',
              '`fileName`',
            ),
          );
        final result = Process.runSync(Platform.resolvedExecutable, [
          'format',
          '--output=none',
          '--set-exit-if-changed',
          file.path,
        ]);
        expect(result.exitCode == 0, 'formatted already: ${result.stdout}');
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('repoFromPrebuilt reads the defaultUrlPattern repository', () {
    expect(
      repoFromPrebuilt(
            r"const x = r'https://github.com/AlonsoMCarlos/ghostty_dart/releases/download/$TAG/$FILENAME';",
          ) ==
          'AlonsoMCarlos/ghostty_dart',
      'repo',
    );
    expectThrows<FormatException>(() => repoFromPrebuilt('nothing'), 'none');
  });

  // --- Manifest ------------------------------------------------------------

  test('native/prebuilt_assets.json is consistent with its floors', () {
    final manifest =
        jsonDecode(File('$root/native/prebuilt_assets.json').readAsStringSync())
            as Map<String, Object?>;
    final floors = manifest['floors']! as Map<String, Object?>;
    final assets = manifest['assets']! as Map<String, Object?>;
    expect(assets.length == 12, '12 assets (ADR 0008), got ${assets.length}');
    for (final MapEntry(key: name, value: raw) in assets.entries) {
      final a = raw! as Map<String, Object?>;
      final target = a['zig_target']! as String;
      final e = Expected.fromAssetName(name);
      if (target.contains('-linux-gnu')) {
        expect(target.endsWith('.${floors['glibc']}'), '$name glibc floor');
      }
      if (e.os == 'android') {
        expect(target.endsWith('.${floors['android_api']}'), '$name API');
      }
      expect(
        (a['builder'] == 'macos') == (e.os == 'macos' || e.os == 'ios'),
        '$name builder',
      );
    }
    final smoke = [
      for (final a in assets.values)
        if ((a! as Map<String, Object?>)['smoke']
            case final Map<String, Object?> s)
          s['runner'],
    ];
    expect(smoke.length == 6 && smoke.toSet().length == 6, 'six smoke runners');
  });

  stdout.writeln('\n$_passed passed, ${_failed.length} failed');
  if (_failed.isNotEmpty) exit(1);
}

// ---------------------------------------------------------------------------
// Synthetic binaries. Minimal but structurally valid: just the parts the
// checker reads, laid out as a linker would.

final class _Out {
  final bytes = BytesBuilder();
  int get length => bytes.length;
  void u8(int v) => bytes.addByte(v & 0xff);
  void u16(int v) => bytes.add(_le(v, 2));
  void u32(int v) => bytes.add(_le(v, 4));
  void u64(int v) => bytes.add(_le(v, 8));
  void word(bool is64, int v) => is64 ? u64(v) : u32(v);
  void add(List<int> b) => bytes.add(b);
  void padTo(int n) {
    while (length < n) {
      u8(0);
    }
  }

  static List<int> _le(int v, int n) => [
    for (var i = 0; i < n; i++) (v >> (8 * i)) & 0xff,
  ];
}

/// String table: "\0name\0..." and the offset of each name.
(List<int>, Map<String, int>) _strtab(Iterable<String> names) {
  final out = <int>[0];
  final offsets = <String, int>{};
  for (final n in names) {
    offsets.putIfAbsent(n, () {
      final o = out.length;
      out.addAll([...ascii.encode(n), 0]);
      return o;
    });
  }
  return (out, offsets);
}

Uint8List elf({
  bool is64 = true,
  int machine = 62,
  List<String> exports = const [
    'ghostty_terminal_new',
    'ghostty_terminal_free',
  ],
  List<String> needed = const ['libm.so.6', 'libc.so.6'],
  List<String> verneeds = const ['GLIBC_2.2.5', 'GLIBC_2.27'],
  List<int> aligns = const [0x1000],
  Uint8List? armAttributes,
}) {
  final (strtab, off) = _strtab([...exports, ...needed, ...verneeds]);
  final symSize = is64 ? 24 : 16, dynSize = is64 ? 16 : 8;
  final ehSize = is64 ? 64 : 52,
      phSize = is64 ? 56 : 32,
      shSize = is64 ? 64 : 40;

  final o = _Out();
  // Sections' contents come after the header and program headers.
  final dataStart = ehSize + aligns.length * phSize;
  final blobs = <(int type, List<int> data, int link)>[];

  blobs.add((3, strtab, 0)); // index 1: .dynstr
  final dynsym = _Out()..add(List.filled(symSize, 0));
  for (final e in exports) {
    if (is64) {
      dynsym
        ..u32(off[e]!)
        ..u8(0x12) // GLOBAL FUNC
        ..u8(0)
        ..u16(1)
        ..u64(0)
        ..u64(0);
    } else {
      dynsym
        ..u32(off[e]!)
        ..u32(0)
        ..u32(0)
        ..u8(0x12)
        ..u8(0)
        ..u16(1);
    }
  }
  blobs.add((11, dynsym.bytes.takeBytes(), 1));
  final dynamic = _Out();
  for (final n in needed) {
    dynamic
      ..word(is64, 1)
      ..word(is64, off[n]!);
  }
  dynamic.add(List.filled(dynSize, 0));
  blobs.add((6, dynamic.bytes.takeBytes(), 1));
  if (verneeds.isNotEmpty) {
    final v = _Out()
      ..u16(1)
      ..u16(verneeds.length)
      ..u32(off[needed.first]!)
      ..u32(16)
      ..u32(0);
    for (final (i, n) in verneeds.indexed) {
      v
        ..u32(0)
        ..u16(0)
        ..u16(0)
        ..u32(off[n]!)
        ..u32(i == verneeds.length - 1 ? 0 : 16);
    }
    blobs.add((0x6ffffffe, v.bytes.takeBytes(), 1));
  }
  if (armAttributes != null) blobs.add((0x70000003, armAttributes, 0));

  final offsets = <int>[];
  var cursor = dataStart;
  for (final b in blobs) {
    offsets.add(cursor);
    cursor += b.$2.length;
  }
  final shoff = cursor;
  final shnum = blobs.length + 1;

  // ELF header.
  o
    ..add([0x7f, 0x45, 0x4c, 0x46, is64 ? 2 : 1, 1, 1, 0])
    ..add(List.filled(8, 0))
    ..u16(3) // ET_DYN
    ..u16(machine)
    ..u32(1)
    ..word(is64, 0) // entry
    ..word(is64, ehSize) // phoff
    ..word(is64, shoff)
    ..u32(0) // flags
    ..u16(ehSize)
    ..u16(phSize)
    ..u16(aligns.length)
    ..u16(shSize)
    ..u16(shnum)
    ..u16(0);
  for (final align in aligns) {
    if (is64) {
      o
        ..u32(1)
        ..u32(5)
        ..u64(0)
        ..u64(0)
        ..u64(0)
        ..u64(0)
        ..u64(0)
        ..u64(align);
    } else {
      o
        ..u32(1)
        ..u32(0)
        ..u32(0)
        ..u32(0)
        ..u32(0)
        ..u32(0)
        ..u32(5)
        ..u32(align);
    }
  }
  for (final b in blobs) {
    o.add(b.$2);
  }
  // Section headers: null, then one per blob.
  o.add(List.filled(shSize, 0));
  for (final (i, b) in blobs.indexed) {
    o
      ..u32(0)
      ..u32(b.$1)
      ..word(is64, 0)
      ..word(is64, 0)
      ..word(is64, offsets[i])
      ..word(is64, b.$2.length)
      ..u32(b.$3)
      ..u32(0)
      ..word(is64, 1)
      ..word(is64, 0);
  }
  return o.bytes.takeBytes();
}

/// An "aeabi" .ARM.attributes section holding integer [attrs].
Uint8List armAttributes(Map<int, int> attrs) {
  final pairs = <int>[];
  for (final MapEntry(key: tag, value: value) in attrs.entries) {
    pairs
      ..add(tag) // all tags used here are < 128: one-byte ULEB
      ..add(value);
  }
  final sub = [1, ..._Out._le(5 + pairs.length, 4), ...pairs];
  final vendor = [...ascii.encode('aeabi'), 0];
  return Uint8List.fromList([
    0x41,
    ..._Out._le(4 + vendor.length + sub.length, 4),
    ...vendor,
    ...sub,
  ]);
}

Uint8List pe({
  int machine = 0x8664,
  List<String> exports = const [
    'ghostty_terminal_new',
    'ghostty_terminal_free',
  ],
  List<String> imports = const [
    'KERNEL32.dll',
    'api-ms-win-crt-heap-l1-1-0.dll',
  ],
}) {
  const rawStart = 0x200, va = 0x1000;
  // Section data: export directory (40), name pointers, import descriptors
  // (+ terminator), then strings.
  final namePtrs = 40;
  final imp = namePtrs + exports.length * 4;
  final strings = imp + (imports.length + 1) * 20;
  final (strtab, off) = _strtab([...exports, ...imports]);
  int rva(int sectionOffset) => va + sectionOffset;

  final data = _Out()
    ..add(List.filled(24, 0))
    ..u32(exports.length) // NumberOfNames
    ..u32(0)
    ..u32(rva(namePtrs)) // AddressOfNames
    ..u32(0); // AddressOfNameOrdinals: 40 bytes in all
  for (final e in exports) {
    data.u32(rva(strings + off[e]!));
  }
  for (final i in imports) {
    data
      ..u32(0)
      ..u32(0)
      ..u32(0)
      ..u32(rva(strings + off[i]!))
      ..u32(0);
  }
  data
    ..add(List.filled(20, 0))
    ..add(strtab);
  final section = data.bytes.takeBytes();

  final o = _Out()
    ..u16(0x5a4d)
    ..padTo(0x3c)
    ..u32(64)
    ..padTo(64)
    ..u32(0x4550)
    ..u16(machine)
    ..u16(1) // sections
    ..u32(0)
    ..u32(0)
    ..u32(0)
    ..u16(240) // SizeOfOptionalHeader
    ..u16(0x2022); // DLL | EXECUTABLE | LARGE_ADDRESS_AWARE
  final optional = o.length;
  o
    ..u16(0x20b)
    ..padTo(optional + 108)
    ..u32(16)
    ..u32(rva(0)) // export directory
    ..u32(40)
    ..u32(rva(imp)) // import directory
    ..u32((imports.length + 1) * 20)
    ..padTo(optional + 240)
    ..add([...ascii.encode('.rdata'), 0, 0])
    ..u32(section.length)
    ..u32(va)
    ..u32(section.length)
    ..u32(rawStart)
    ..add(List.filled(16, 0))
    ..padTo(rawStart)
    ..add(section);
  return o.bytes.takeBytes();
}

Uint8List macho({
  int platform = 1,
  int minOs = 13 << 16,
  List<String> exports = const [
    'ghostty_terminal_new',
    'ghostty_terminal_free',
  ],
  bool loopTrie = false,
}) {
  final commands = _Out();
  void dylibCommand(int cmd, String name) {
    final str = [...ascii.encode(name), 0];
    final size = (24 + str.length + 7) & ~7;
    commands
      ..u32(cmd)
      ..u32(size)
      ..u32(24)
      ..u32(0)
      ..u32(0x10000)
      ..u32(0x10000)
      ..add(str)
      ..add(List.filled(size - 24 - str.length, 0));
  }

  dylibCommand(0xd, '@rpath/libghostty-vt.1.dylib');
  dylibCommand(0xc, '/usr/lib/libSystem.B.dylib');
  commands
    ..u32(0x32)
    ..u32(24)
    ..u32(platform)
    ..u32(minOs)
    ..u32(0)
    ..u32(0);

  // Export trie: root with one edge per symbol to a terminal leaf.
  final labels = [
    for (final e in exports) [...ascii.encode('_$e'), 0],
  ];
  final rootSize = 2 + labels.fold<int>(0, (s, l) => s + l.length + 1);
  final trie = <int>[0, labels.length];
  for (final (i, l) in labels.indexed) {
    trie
      ..addAll(l)
      ..add(loopTrie ? 0 : rootSize + i * 4); // one-byte ULEB offsets
  }
  for (var i = 0; i < labels.length; i++) {
    trie.addAll([2, 0, 0, 0]); // terminal size 2 (flags, address), 0 children
  }
  final commandsSize = commands.length + 16;
  final trieOffset = 32 + commandsSize;
  commands
    ..u32(0x80000033)
    ..u32(16)
    ..u32(trieOffset)
    ..u32(trie.length);

  final o = _Out()
    ..u32(0xfeedfacf)
    ..u32(0x0100000c)
    ..u32(0)
    ..u32(6) // MH_DYLIB
    ..u32(4) // ncmds
    ..u32(commandsSize)
    ..u32(0)
    ..u32(0)
    ..add(commands.bytes.takeBytes())
    ..add(trie);
  return o.bytes.takeBytes();
}
