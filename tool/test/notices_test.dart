// Keeps the third-party licence notices that ship with the packages complete.
//
// Flutter builds an app's NOTICES (what `LicensePage` shows) from each
// dependency's `NOTICES` file, or its `LICENSE` when there is no `NOTICES`
// (flutter_tools' `LicenseCollector`, Flutter 3.47.9). ghostty_dart's
// `NOTICES` carries the licences of the code inside the prebuilt
// libghostty-vt binaries, and ghostty_dart_xterm's carries xterm.dart's
// licence for the code ported from it. This test fails if a required notice
// disappears, if a file stops parsing the way Flutter parses it, or if a
// package's own block drifts from its `LICENSE` (pana and pub.dev read only
// `LICENSE`, which stays plain MIT).
// Run with `dart tool/test/notices_test.dart` from the repo root.

import 'dart:convert';
import 'dart:io';

/// Flutter's separator between licences (LicenseCollector.licenseSeparator).
final _separator = '\n${'-' * 80}\n';

/// One licence of a NOTICES file: the package names and the text.
typedef _Block = ({List<String> names, String text});

/// Required notices per package: package name -> substrings its text must
/// contain (a copyright line, or a phrase only that licence has).
const _required = <String, Map<String, List<String>>>{
  'packages/ghostty_dart': {
    'ghostty_dart': ['Carlos Alonso Martín and ghostty_dart contributors'],
    'libghostty-vt': ['Mitchell Hashimoto, Ghostty contributors'],
    'highway': ['The Highway Project Authors'],
    'simdutf': ['The simdutf authors'],
    'wuffs': ['The Wuffs Authors'],
    'uucode': ['Jacob Sandlund', 'UNICODE LICENSE V3'],
    'Unicode Character Database': ['Unicode, Inc.'],
    'translate_c': ['Zig contributors'],
    'zig': ['Zig contributors'],
    'mingw-w64': ['the mingw-w64 project', 'Zope Public License'],
    'bionic': ['The Android Open Source Project'],
  },
  'packages/ghostty_dart_xterm': {
    'ghostty_dart_xterm': [
      'Carlos Alonso Martín and ghostty_dart contributors',
    ],
    'xterm': ['Copyright (c) 2020 xuty'],
  },
};

/// Normalises a licence text for comparison: no trailing spaces, no
/// trailing blank lines.
String _normalise(String text) =>
    text.split('\n').map((line) => line.trimRight()).join('\n').trimRight();

/// Parses a NOTICES file exactly as flutter_tools' LicenseCollector does.
List<_Block> _parse(String content) {
  final blocks = <_Block>[];
  for (final raw in content.split(_separator)) {
    final split = raw.indexOf('\n\n');
    if (split < 0) {
      // Flutter would file this text under the package's own name.
      blocks.add((names: const [], text: raw));
    } else {
      blocks.add((
        names: raw.substring(0, split).split('\n'),
        text: raw.substring(split + 2),
      ));
    }
  }
  return blocks;
}

void main() {
  var failures = 0;
  var passes = 0;
  void check(String name, List<String> problems) {
    if (problems.isEmpty) {
      passes++;
      print('ok   $name');
    } else {
      failures++;
      print('FAIL $name');
      for (final problem in problems) {
        print('       $problem');
      }
    }
  }

  for (final MapEntry(key: dir, value: required) in _required.entries) {
    final file = File('$dir/NOTICES');
    if (!file.existsSync()) {
      check('$dir/NOTICES exists', ['missing']);
      continue;
    }
    final content = file.readAsStringSync();
    final blocks = _parse(content);
    final ownName = dir.split('/').last;

    check('$dir/NOTICES parses as Flutter parses it', [
      if (content.contains('\r')) 'contains CR characters',
      if (blocks.length < 2) 'only ${blocks.length} licence(s) found',
      for (final (i, block) in blocks.indexed) ...[
        if (block.names.isEmpty) 'licence ${i + 1} has no package names',
        for (final name in block.names)
          if (name.trim().isEmpty || name != name.trim())
            'licence ${i + 1} has a malformed package name "$name"',
        if (block.text.trim().isEmpty) 'licence ${i + 1} is empty',
      ],
    ]);

    check('$dir/NOTICES has every required notice', [
      for (final MapEntry(key: name, value: needles) in required.entries)
        if (blocks.where((b) => b.names.contains(name)).toList()
            case final matching)
          if (matching.isEmpty)
            'no licence for "$name"'
          else
            for (final needle in needles)
              if (!matching.any((b) => b.text.contains(needle)))
                '"$name" licence lacks "$needle"',
    ]);

    // Flutter reads NOTICES *instead of* LICENSE, so the package's own
    // licence must be in it, word for word.
    final license = _normalise(File('$dir/LICENSE').readAsStringSync());
    final own = blocks.where((b) => b.names.contains(ownName));
    check('$dir/NOTICES repeats LICENSE verbatim', [
      if (!own.any((b) => _normalise(b.text) == license))
        'no "$ownName" block equals LICENSE',
    ]);

    final pubignore = File('$dir/.pubignore');
    check('$dir/NOTICES is published', [
      if (pubignore.existsSync())
        for (final line in pubignore.readAsLinesSync())
          if (!line.trimLeft().startsWith('#') && line.contains('NOTICE'))
            '.pubignore excludes it ("$line")',
    ]);
  }

  // The xterm block is xterm 4.0.0's LICENSE, the same text LICENSE.xterm
  // (referenced by every ported file's header) ends with.
  final xtermNotices = _parse(
    File('packages/ghostty_dart_xterm/NOTICES').readAsStringSync(),
  );
  final xtermLicense = _normalise(
    File(
      'packages/ghostty_dart_xterm/test/compat/LICENSE.xterm',
    ).readAsStringSync(),
  );
  final licenseXterm = _normalise(
    File('packages/ghostty_dart_xterm/LICENSE.xterm').readAsStringSync(),
  );
  check('ghostty_dart_xterm: NOTICES carries xterm\'s licence verbatim', [
    if (!xtermNotices.any(
      (b) => b.names.contains('xterm') && _normalise(b.text) == xtermLicense,
    ))
      'the "xterm" block differs from test/compat/LICENSE.xterm',
    if (!licenseXterm.endsWith(xtermLicense))
      'LICENSE.xterm no longer ends with xterm\'s licence',
  ]);

  // Upstream lists what is compiled into libghostty-vt in
  // deps/libghostty-vt-third-party.json ("use": "linked"). When the pinned
  // source is unpacked (after `mise run native:host`), every linked project
  // must have a notice, and libghostty-vt's must be upstream's LICENSE.
  final upstream =
      jsonDecode(File('native/upstream.json').readAsStringSync())
          as Map<String, Object?>;
  final src = Directory(
    '.native-cache/src/${upstream['name']}-${upstream['version']}',
  );
  final thirdParty = File('${src.path}/deps/libghostty-vt-third-party.json');
  if (!thirdParty.existsSync()) {
    print(
      'skip upstream cross-check: ${thirdParty.path} not unpacked '
      '(run `mise run native:host`)',
    );
  } else {
    final notices = _parse(
      File('packages/ghostty_dart/NOTICES').readAsStringSync(),
    );
    final names = {for (final b in notices) ...b.names};
    final linked = [
      for (final entry
          in (jsonDecode(thirdParty.readAsStringSync())
                  as Map<String, Object?>)['third_party']
              as List<Object?>)
        if ((entry as Map<String, Object?>)['use'] == 'linked')
          entry['name'] as String,
    ];
    final ghosttyLicense = _normalise(
      File('${src.path}/LICENSE').readAsStringSync(),
    );
    check(
      'ghostty_dart: a notice for every project linked into libghostty-vt',
      [
        if (linked.isEmpty) 'no linked project parsed (format changed?)',
        for (final name in linked)
          if (!names.contains(name)) 'no notice for "$name"',
        if (!notices.any(
          (b) =>
              b.names.contains('libghostty-vt') &&
              _normalise(b.text) == ghosttyLicense,
        ))
          'the "libghostty-vt" block differs from upstream\'s LICENSE',
      ],
    );
  }

  print('$passes passed, $failures failed');
  if (failures > 0) exit(1);
}
