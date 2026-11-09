// Readers for ELF, PE and Mach-O shared libraries, and the release checks of
// ADR 0008 ("Verification") built on them. Used by tool/native/check_binary.dart
// and tested by tool/native/test/tool_test.dart.
//
// The readers parse only what the checks need, with dart:io-free pure code,
// so every asset is checked the same way on every host: GNU objdump on
// Debian/Ubuntu cannot read ARM64 PE files, and otool exists only on macOS.
//
// Malformed input must be rejected, never hang: every loop is bounded by the
// file size or by a format limit, every offset is range-checked (ByteData
// throws RangeError), and every inconsistency throws FormatException.

import 'dart:convert';
import 'dart:typed_data';

/// Platform floors a release asset must meet (native/prebuilt_assets.json).
final class Floors {
  const Floors({required this.glibc, required this.macos, required this.ios});

  /// Newest GLIBC symbol version allowed, as (major, minor).
  final (int, int) glibc;

  /// Highest allowed minimum macOS major version.
  final int macos;

  /// Highest allowed minimum iOS major version (device and simulator). Kept
  /// apart from [macos]: the arm64 iOS simulator starts at iOS 14.
  final int ios;
}

/// One check outcome: `ok` false fails the asset.
typedef CheckLine = ({bool ok, String text, bool info});

/// What an asset name promises: `<lib>-<os>-<arch>[-simulator].<ext>`.
final class Expected {
  Expected._(this.os, this.arch, this.simulator, this.format);

  /// Parses an ADR 0008 asset name; throws [FormatException] otherwise.
  factory Expected.fromAssetName(String asset) {
    final match = RegExp(
      r'-(linux|windows|android|macos|ios)-(x64|arm64|arm)(-simulator)?\.(so|dll|dylib)$',
    ).firstMatch(asset);
    if (match == null) {
      throw FormatException('$asset is not a release asset name (ADR 0008)');
    }
    final format = switch (match[4]) {
      'so' => 'elf',
      'dll' => 'pe',
      _ => 'macho',
    };
    return Expected._(match[1]!, match[2]!, match[3] != null, format);
  }

  final String os;
  final String arch;
  final bool simulator;
  final String format;

  /// Mach-O LC_BUILD_VERSION platform: 1 macOS, 2 iOS, 7 iOS simulator.
  int get machOPlatform => os == 'macos' ? 1 : (simulator ? 7 : 2);

  /// System libraries only: libghostty-vt links libc (and libm/librt on
  /// glibc) and builds its C++ deps without libc++ (upstream
  /// GhosttyLibVt.zig), so nothing else may appear.
  bool allowsDependency(String name) => switch (os) {
    'linux' => RegExp(
      r'^(libc\.so\.6|libm\.so\.6|librt\.so\.1|libdl\.so\.2|libpthread\.so\.0|ld-linux[-\w.]*\.so\.\d)$',
    ).hasMatch(name),
    'android' => RegExp(r'^lib(c|m|dl|log)\.so$').hasMatch(name),
    'windows' => RegExp(
      r'^(kernel32|ntdll|api-ms-win-crt-[a-z]+-l1-1-0)\.dll$',
      caseSensitive: false,
    ).hasMatch(name),
    _ => name == '/usr/lib/libSystem.B.dylib',
  };
}

/// Function names declared with GHOSTTY_API in libghostty-vt headers, given
/// as (path, contents) pairs of `ghostty/vt.h` and `ghostty/vt/**/*.h`.
/// wasm.h is skipped (wasm-only API) and comments are stripped first: the
/// docs contain example declarations such as `ghostty_foo_new`.
Set<String> declaredApi(Iterable<(String, String)> headers) {
  final names = <String>{};
  final declaration = RegExp(r'GHOSTTY_API\b[^;{]*?\b(ghostty_\w+)\s*\(');
  for (final (path, contents) in headers) {
    if (path.endsWith('/wasm.h') || path.endsWith(r'\wasm.h')) continue;
    final text = contents
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
        .replaceAll(RegExp(r'//[^\n]*'), '');
    names.addAll(declaration.allMatches(text).map((m) => m[1]!));
  }
  return names;
}

/// Runs every check for [asset] on [bytes]. Never throws for malformed
/// binaries: a parse failure is a failed check line.
List<CheckLine> checkBinary({
  required String asset,
  required Uint8List bytes,
  required Set<String> api,
  required Floors floors,
}) {
  final expected = Expected.fromAssetName(asset);
  final lines = <CheckLine>[];
  void check(bool ok, String text) =>
      lines.add((ok: ok, text: text, info: false));
  void info(String text) => lines.add((ok: true, text: text, info: true));

  final Binary binary;
  try {
    binary = switch (expected.format) {
      'elf' => parseElf(bytes),
      'pe' => parsePe(bytes),
      _ => parseMachO(bytes),
    };
  } on FormatException catch (e) {
    check(false, 'not a valid ${expected.format} file: ${e.message}');
    return lines;
  } on RangeError catch (e) {
    check(false, 'not a valid ${expected.format} file: ${e.message}');
    return lines;
  }

  info('format: ${binary.description}');
  check(binary.arch == expected.arch, 'architecture ${binary.arch}');
  check(binary.isSharedLibrary, 'shared library');

  final exported = binary.exports
      .where((s) => s.startsWith('ghostty_'))
      .toSet();
  final missing = api.difference(exported).toList()..sort();
  final extra = exported.difference(api).toList()..sort();
  check(
    api.isNotEmpty && missing.isEmpty && extra.isEmpty,
    '${exported.length} ghostty_* exports match the ${api.length} '
    'functions declared in the headers'
    '${missing.isEmpty ? '' : '; missing: ${missing.join(', ')}'}'
    '${extra.isEmpty ? '' : '; undeclared: ${extra.join(', ')}'}',
  );

  final unexpected = binary.dependencies
      .where((d) => !expected.allowsDependency(d))
      .toList();
  check(
    unexpected.isEmpty,
    'dependencies ${binary.dependencies.join(', ')}'
    '${unexpected.isEmpty ? '' : '; unexpected: ${unexpected.join(', ')}'}',
  );

  switch (binary) {
    case final Elf elf:
      _checkElf(elf, expected, floors, check, info);
    case final MachO macho:
      _checkMachO(macho, expected, floors, check, info);
    case Pe():
  }
  return lines;
}

void _checkElf(
  Elf elf,
  Expected expected,
  Floors floors,
  void Function(bool, String) check,
  void Function(String) info,
) {
  if (elf.soname != null) info('soname: ${elf.soname}');
  if (expected.os == 'linux') {
    // GLIBC_2.2.5, GLIBC_2.27, ...: compare (major, minor); patch is moot.
    final versions = [
      for (final v in elf.versionNeeds)
        if (RegExp(r'^GLIBC_(\d+)\.(\d+)').firstMatch(v) case final m?)
          (int.parse(m[1]!), int.parse(m[2]!)),
    ]..sort(_compareVersions);
    final max = versions.isEmpty ? null : versions.last;
    final (fMajor, fMinor) = floors.glibc;
    check(
      max != null && _compareVersions(max, floors.glibc) <= 0,
      'newest GLIBC symbol version '
      '${max == null ? 'none' : '${max.$1}.${max.$2}'} (floor $fMajor.$fMinor)',
    );
  }
  if (expected.os == 'android') {
    final aligns = elf.loadAligns;
    check(
      aligns.isNotEmpty && aligns.every((a) => a >= 0x4000),
      'PT_LOAD alignments '
      '${aligns.map((a) => '0x${a.toRadixString(16)}').join(', ')} '
      '(need >= 0x4000 for 16 KiB pages)',
    );
  }
  if (expected.arch == 'arm') {
    final a = elf.armAttributes;
    // Tag_CPU_arch 10 = ARMv7, Tag_FP_arch 3/4 = VFPv3 (/-D16) or later,
    // Tag_Advanced_SIMD_arch 1 = NEONv1 or later (ARM IHI 0045).
    check(
      (a[6] ?? 0) >= 10 && (a[10] ?? 0) >= 3 && (a[12] ?? 0) >= 1,
      'ARM attributes CPU_arch=${a[6]} FP_arch=${a[10]} '
      'Advanced_SIMD_arch=${a[12]} (need ARMv7, VFPv3, NEON)',
    );
    // armeabi-v7a passes floats in core registers (softfp). Tag_ABI_VFP_args
    // (28) = 1 would mean the hard-float convention, which callers such as
    // the Dart VM's FFI on Android do not use.
    check(
      (a[28] ?? 0) == 0,
      'softfp calling convention (Tag_ABI_VFP_args=${a[28] ?? 0})',
    );
  }
}

int _compareVersions((int, int) a, (int, int) b) =>
    a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2;

void _checkMachO(
  MachO macho,
  Expected expected,
  Floors floors,
  void Function(bool, String) check,
  void Function(String) info,
) {
  if (macho.installName != null) info('install name: ${macho.installName}');
  final platform = macho.platform;
  check(
    platform == expected.machOPlatform,
    'platform ${_platformNames[platform] ?? platform} '
    '(expected ${_platformNames[expected.machOPlatform]})',
  );
  final minOs = macho.minOs;
  final floor = expected.machOPlatform == 1 ? floors.macos : floors.ios;
  check(
    minOs != null && minOs.$1 <= floor,
    'minimum OS ${minOs == null ? 'missing' : '${minOs.$1}.${minOs.$2}'} '
    '(floor $floor.0)',
  );
}

const _platformNames = {1: 'macos', 2: 'ios', 7: 'ios-simulator'};

// ---------------------------------------------------------------------------
// Readers.

/// The facts every format provides.
sealed class Binary {
  String get description;
  String get arch;
  bool get isSharedLibrary;
  List<String> get exports;
  List<String> get dependencies;
}

/// Little-endian reads; every target is LE, and fat (big-endian header)
/// Mach-O files are rejected up front. Out-of-range reads throw RangeError.
final class _Bytes {
  _Bytes(this.raw) : data = ByteData.sublistView(raw);

  final Uint8List raw;
  final ByteData data;

  int get length => raw.length;
  int u8(int o) => data.getUint8(o);
  int u16(int o) => data.getUint16(o, Endian.little);
  int u32(int o) => data.getUint32(o, Endian.little);
  int u64(int o) => data.getUint64(o, Endian.little);

  /// NUL-terminated string at [o]; it must end before [limit] (default: EOF).
  String cstr(int o, [int? limit]) {
    final end = limit ?? raw.length;
    if (o < 0 || o >= end) throw RangeError.range(o, 0, end - 1, 'string');
    var e = o;
    while (e < end && raw[e] != 0) {
      e++;
    }
    if (e == end) throw const FormatException('unterminated string');
    return latin1.decode(raw.sublist(o, e));
  }

  /// Unsigned LEB128 at [o]; returns the value and the offset after it.
  (int, int) uleb(int o) {
    var result = 0, shift = 0;
    while (true) {
      final byte = u8(o++);
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return (result, o);
      shift += 7;
      if (shift > 56) throw const FormatException('ULEB128 too long');
    }
  }

  /// Fails unless [offset, offset + size) lies inside the file.
  void span(int offset, int size, String what) {
    if (offset < 0 || size < 0 || offset + size > raw.length) {
      throw FormatException('$what is outside the file');
    }
  }
}

/// An ELF shared object.
final class Elf extends Binary {
  Elf._({
    required this.is64,
    required this.machine,
    required this.type,
    required this.exports,
    required this.dependencies,
    required this.soname,
    required this.loadAligns,
    required this.versionNeeds,
    required this.armAttributes,
  });

  final bool is64;
  final int machine;
  final int type;
  @override
  final List<String> exports;
  @override
  final List<String> dependencies;
  final String? soname;
  final List<int> loadAligns;
  final List<String> versionNeeds;
  final Map<int, int> armAttributes;

  @override
  String get description => 'ELF${is64 ? 64 : 32} machine $machine';

  @override
  String get arch => switch ((machine, is64)) {
    (62, true) => 'x64',
    (183, true) => 'arm64',
    (40, false) => 'arm',
    _ => 'machine-$machine',
  };

  @override
  bool get isSharedLibrary => type == 3; // ET_DYN
}

/// Parses an ELF file; throws [FormatException] or [RangeError] if malformed.
Elf parseElf(Uint8List raw) {
  final b = _Bytes(raw);
  if (raw.length < 52 || b.u32(0) != 0x464c457f) {
    throw const FormatException('no ELF magic');
  }
  final is64 = switch (b.u8(4)) {
    1 => false,
    2 => true,
    _ => throw const FormatException('bad ELF class'),
  };
  if (b.u8(5) != 1) throw const FormatException('not little-endian');
  int word(int o) => is64 ? b.u64(o) : b.u32(o);

  final type = b.u16(16), machine = b.u16(18);
  final phoff = word(is64 ? 32 : 28), shoff = word(is64 ? 40 : 32);
  final phentsize = b.u16(is64 ? 54 : 42), phnum = b.u16(is64 ? 56 : 44);
  final shentsize = b.u16(is64 ? 58 : 46), shnum = b.u16(is64 ? 60 : 48);
  if (phnum > 0 && phentsize < (is64 ? 56 : 32)) {
    throw const FormatException('bad program header size');
  }
  if (shnum > 0 && shentsize < (is64 ? 64 : 40)) {
    throw const FormatException('bad section header size');
  }
  b.span(phoff, phnum * phentsize, 'program header table');
  b.span(shoff, shnum * shentsize, 'section header table');

  final loadAligns = <int>[];
  for (var i = 0; i < phnum; i++) {
    final p = phoff + i * phentsize;
    if (b.u32(p) == 1) loadAligns.add(word(p + (is64 ? 48 : 28))); // PT_LOAD
  }

  final sections = [
    for (var i = 0; i < shnum; i++)
      () {
        final s = shoff + i * shentsize;
        final section = (
          type: b.u32(s + 4),
          offset: word(s + (is64 ? 24 : 16)),
          size: word(s + (is64 ? 32 : 20)),
          link: b.u32(s + (is64 ? 40 : 24)),
        );
        // SHT_NOBITS (8) occupies no file bytes.
        if (section.type != 8) {
          b.span(section.offset, section.size, 'section $i');
        }
        return section;
      }(),
  ];
  String str(int section, int offset) {
    if (section >= sections.length) {
      throw const FormatException('bad string table index');
    }
    final s = sections[section];
    return b.cstr(s.offset + offset, s.offset + s.size);
  }

  final exports = <String>[];
  final dependencies = <String>[];
  final versionNeeds = <String>[];
  final armAttributes = <int, int>{};
  String? soname;
  for (final s in sections) {
    final end = s.offset + s.size;
    switch (s.type) {
      case 11: // SHT_DYNSYM
        final size = is64 ? 24 : 16;
        for (var o = s.offset + size; o + size <= end; o += size) {
          final info = b.u8(o + (is64 ? 4 : 12));
          final shndx = b.u16(o + (is64 ? 6 : 14));
          final bind = info >> 4;
          if (shndx != 0 && (bind == 1 || bind == 2)) {
            exports.add(str(s.link, b.u32(o)));
          }
        }
      case 6: // SHT_DYNAMIC
        final size = is64 ? 16 : 8;
        for (var o = s.offset; o + size <= end; o += size) {
          final tag = word(o), value = word(o + size ~/ 2);
          if (tag == 0) break;
          if (tag == 1) dependencies.add(str(s.link, value)); // DT_NEEDED
          if (tag == 14) soname = str(s.link, value); // DT_SONAME
        }
      case 0x6ffffffe: // SHT_GNU_verneed
        _readVerneed(b, s.offset, end, (o) => versionNeeds.add(str(s.link, o)));
      case 0x70000003: // SHT_ARM_ATTRIBUTES
        if (machine == 40) {
          armAttributes.addAll(_armAttributes(b, s.offset, end));
        }
    }
  }
  return Elf._(
    is64: is64,
    machine: machine,
    type: type,
    exports: exports,
    dependencies: dependencies,
    soname: soname,
    loadAligns: loadAligns,
    versionNeeds: versionNeeds,
    armAttributes: armAttributes,
  );
}

/// Walks Elf_Verneed (16 bytes) and its Elf_Vernaux (16 bytes) entries. Every
/// `next` offset must move forward inside the section, so the walk ends.
void _readVerneed(_Bytes b, int start, int end, void Function(int) name) {
  var need = start;
  while (true) {
    if (need + 16 > end) throw const FormatException('verneed out of section');
    var aux = need + b.u32(need + 8);
    for (var i = 0; i < b.u16(need + 2); i++) {
      if (aux < need || aux + 16 > end) {
        throw const FormatException('vernaux out of section');
      }
      name(b.u32(aux + 8));
      final next = b.u32(aux + 12);
      if (next == 0) break;
      aux += next;
    }
    final next = b.u32(need + 12);
    if (next == 0) return;
    need += next;
  }
}

/// Integer attributes of the "aeabi" file scope (ARM IHI 0045, "Build
/// attributes"): format 'A', then `<u32 length><vendor NUL>` and
/// sub-subsections `<uleb tag><u32 size><tag/value pairs>`. Sizes must cover
/// at least their own header and stay inside their parent, so loops advance.
Map<int, int> _armAttributes(_Bytes b, int start, int end) {
  final result = <int, int>{};
  if (start >= end || b.u8(start) != 0x41) return result;
  final section = start + 1;
  if (section + 4 > end) {
    throw const FormatException('ARM attributes truncated');
  }
  final sectionEnd = section + b.u32(section);
  if (sectionEnd > end || sectionEnd < section + 5) {
    throw const FormatException('bad ARM attributes section length');
  }
  final vendor = b.cstr(section + 4, sectionEnd);
  if (vendor != 'aeabi') return result;
  var o = section + 4 + vendor.length + 1;
  while (o < sectionEnd) {
    final (tag, afterTag) = b.uleb(o);
    if (afterTag + 4 > sectionEnd) {
      throw const FormatException('ARM attributes truncated');
    }
    final subEnd = o + b.u32(afterTag);
    if (subEnd < afterTag + 4 || subEnd > sectionEnd) {
      throw const FormatException('bad ARM attributes subsection size');
    }
    if (tag == 1) {
      var p = afterTag + 4;
      while (p < subEnd) {
        final (attr, afterAttr) = b.uleb(p);
        p = afterAttr;
        final isString =
            attr == 4 || attr == 5 || attr == 67 || (attr > 32 && attr.isOdd);
        if (attr == 32) {
          // Tag_compatibility: ULEB flag, then a string.
          p = b.uleb(p).$2;
          p += b.cstr(p, subEnd).length + 1;
        } else if (isString) {
          p += b.cstr(p, subEnd).length + 1;
        } else {
          final (value, after) = b.uleb(p);
          result[attr] = value;
          p = after;
        }
      }
    }
    o = subEnd;
  }
  return result;
}

/// A PE32+ DLL.
final class Pe extends Binary {
  Pe._(this.machine, this.characteristics, this.exports, this.dependencies);

  final int machine;
  final int characteristics;
  @override
  final List<String> exports;
  @override
  final List<String> dependencies;

  @override
  String get description => 'PE32+ machine 0x${machine.toRadixString(16)}';

  @override
  String get arch => switch (machine) {
    0x8664 => 'x64',
    0xaa64 => 'arm64',
    _ => 'machine-0x${machine.toRadixString(16)}',
  };

  @override
  bool get isSharedLibrary => characteristics & 0x2000 != 0; // FILE_DLL
}

/// Parses a PE32+ file; throws [FormatException] or [RangeError] if
/// malformed.
Pe parsePe(Uint8List raw) {
  final b = _Bytes(raw);
  if (raw.length < 64 || b.u16(0) != 0x5a4d) {
    throw const FormatException('no MZ header');
  }
  final pe = b.u32(0x3c);
  if (b.u32(pe) != 0x4550) throw const FormatException('no PE signature');
  final machine = b.u16(pe + 4);
  final sectionCount = b.u16(pe + 6);
  final optionalSize = b.u16(pe + 20);
  final characteristics = b.u16(pe + 22);
  final optional = pe + 24;
  if (b.u16(optional) != 0x20b) throw const FormatException('not PE32+');
  // The PE format allows at most 96 sections and 16 data directories.
  if (sectionCount > 96) throw const FormatException('too many sections');
  final directoryCount = b.u32(optional + 108);
  if (directoryCount > 16 || 112 + directoryCount * 8 > optionalSize) {
    throw const FormatException('bad data directory count');
  }
  (int, int) directory(int i) => i < directoryCount
      ? (b.u32(optional + 112 + i * 8), b.u32(optional + 116 + i * 8))
      : (0, 0);

  final sectionTable = optional + optionalSize;
  b.span(sectionTable, sectionCount * 40, 'section table');
  int offsetOf(int rva) {
    for (var i = 0; i < sectionCount; i++) {
      final s = sectionTable + i * 40;
      final va = b.u32(s + 12), raw = b.u32(s + 16);
      if (rva >= va && rva < va + raw) {
        final offset = rva - va + b.u32(s + 20);
        b.span(offset, 1, 'RVA 0x${rva.toRadixString(16)}');
        return offset;
      }
    }
    throw FormatException('RVA 0x${rva.toRadixString(16)} is in no section');
  }

  final exports = <String>[];
  final (exportRva, _) = directory(0);
  if (exportRva != 0) {
    final e = offsetOf(exportRva);
    final count = b.u32(e + 24);
    final names = offsetOf(b.u32(e + 32));
    b.span(names, count * 4, 'export name table');
    for (var i = 0; i < count; i++) {
      exports.add(b.cstr(offsetOf(b.u32(names + i * 4))));
    }
  }

  // Descriptor arrays end with an all-zero entry; the file size bounds them.
  final dependencies = <String>[];
  final (importRva, _) = directory(1);
  if (importRva != 0) {
    for (var d = offsetOf(importRva); b.u32(d + 12) != 0; d += 20) {
      b.span(d, 20, 'import descriptor');
      dependencies.add(b.cstr(offsetOf(b.u32(d + 12))));
    }
  }
  final (delayRva, _) = directory(13);
  if (delayRva != 0) {
    for (var d = offsetOf(delayRva); b.u32(d + 4) != 0; d += 32) {
      b.span(d, 32, 'delay import descriptor');
      dependencies.add(b.cstr(offsetOf(b.u32(d + 4))));
    }
  }
  return Pe._(machine, characteristics, exports, dependencies);
}

/// A thin 64-bit Mach-O dylib.
final class MachO extends Binary {
  MachO._({
    required this.cpuType,
    required this.fileType,
    required this.exports,
    required this.dependencies,
    required this.installName,
    required this.platform,
    required this.minOs,
  });

  final int cpuType;
  final int fileType;
  @override
  final List<String> exports;
  @override
  final List<String> dependencies;
  final String? installName;
  final int? platform;
  final (int, int)? minOs;

  @override
  String get description => 'Mach-O 64 cputype 0x${cpuType.toRadixString(16)}';

  @override
  String get arch => switch (cpuType) {
    0x01000007 => 'x64',
    0x0100000c => 'arm64',
    _ => 'cputype-0x${cpuType.toRadixString(16)}',
  };

  @override
  bool get isSharedLibrary => fileType == 6; // MH_DYLIB
}

/// Parses a thin 64-bit little-endian Mach-O file; throws [FormatException]
/// or [RangeError] if malformed.
MachO parseMachO(Uint8List raw) {
  final b = _Bytes(raw);
  if (raw.length < 32 || b.u32(0) != 0xfeedfacf) {
    throw const FormatException('not a thin 64-bit little-endian Mach-O');
  }
  final cpuType = b.u32(4), fileType = b.u32(12);
  final commandCount = b.u32(16), commandsSize = b.u32(20);
  b.span(32, commandsSize, 'load commands');
  // Each load command is at least 8 bytes, which bounds the count.
  if (commandCount * 8 > commandsSize) {
    throw const FormatException('more load commands than fit');
  }
  final commandsEnd = 32 + commandsSize;

  final dependencies = <String>[];
  String? installName;
  int? platform;
  (int, int)? minOs;
  (int, int)? exportTrie;
  (int, int, int)? symtab;
  (int, int) version(int v) => (v >> 16, (v >> 8) & 0xff);

  var c = 32;
  for (var i = 0; i < commandCount; i++) {
    final cmd = b.u32(c), size = b.u32(c + 4);
    if (size < 8 || c + size > commandsEnd) {
      throw FormatException('bad size $size of load command $i');
    }
    final end = c + size;
    String lcStr() => b.cstr(c + b.u32(c + 8), end);
    switch (cmd) {
      case 0xd: // LC_ID_DYLIB
        installName = lcStr();
      // LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
      // LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB.
      case 0xc || 0x80000018 || 0x8000001f || 0x20 || 0x80000023:
        dependencies.add(lcStr());
      case 0x32: // LC_BUILD_VERSION
        platform = b.u32(c + 8);
        minOs = version(b.u32(c + 12));
      case 0x24: // LC_VERSION_MIN_MACOSX
        platform ??= 1;
        minOs ??= version(b.u32(c + 8));
      case 0x25: // LC_VERSION_MIN_IPHONEOS
        platform ??= 2;
        minOs ??= version(b.u32(c + 8));
      case 0x22 || 0x80000022: // LC_DYLD_INFO(_ONLY)
        if (b.u32(c + 44) != 0) exportTrie = (b.u32(c + 40), b.u32(c + 44));
      case 0x80000033: // LC_DYLD_EXPORTS_TRIE
        exportTrie = (b.u32(c + 8), b.u32(c + 12));
      case 0x2: // LC_SYMTAB
        symtab = (b.u32(c + 8), b.u32(c + 12), b.u32(c + 16));
    }
    c = end;
  }

  final exports = <String>[];
  if (exportTrie != null) {
    final (offset, size) = exportTrie;
    b.span(offset, size, 'export trie');
    exports.addAll(_exportTrie(b, offset, offset + size));
  } else if (symtab != null) {
    final (symoff, nsyms, stroff) = symtab;
    b.span(symoff, nsyms * 16, 'symbol table');
    for (var i = 0; i < nsyms; i++) {
      final n = symoff + i * 16;
      final type = b.u8(n + 4);
      if (type & 0x01 != 0 && type & 0x0e == 0x0e) {
        exports.add(b.cstr(stroff + b.u32(n)));
      }
    }
  }
  return MachO._(
    cpuType: cpuType,
    fileType: fileType,
    // C symbols carry a leading underscore in Mach-O.
    exports: [for (final e in exports) e.startsWith('_') ? e.substring(1) : e],
    dependencies: dependencies,
    installName: installName,
    platform: platform,
    minOs: minOs,
  );
}

/// Every terminal of the dyld export trie (mach-o/loader.h, "export trie"):
/// a node is `<uleb terminal size><terminal info><u8 child count>` then
/// `<edge label NUL><uleb child offset>` per child. Iterative, and each node
/// is visited once, so a crafted cycle or a deep chain cannot hang or
/// overflow the stack.
List<String> _exportTrie(_Bytes b, int start, int end) {
  final out = <String>[];
  final seen = <int>{};
  final pending = <(int, String)>[(start, '')];
  while (pending.isNotEmpty) {
    final (node, prefix) = pending.removeLast();
    if (node < start || node >= end) {
      throw const FormatException('export trie node outside the trie');
    }
    if (!seen.add(node)) throw const FormatException('export trie loops');
    final (terminalSize, afterSize) = b.uleb(node);
    if (terminalSize > 0) out.add(prefix);
    var o = afterSize + terminalSize;
    if (o >= end) throw const FormatException('export trie node truncated');
    final children = b.u8(o++);
    for (var i = 0; i < children; i++) {
      final label = b.cstr(o, end);
      o += label.length + 1;
      final (childOffset, after) = b.uleb(o);
      o = after;
      pending.add((start + childOffset, prefix + label));
    }
  }
  return out;
}
