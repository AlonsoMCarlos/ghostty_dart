/// Deterministic per-frame VT byte streams for the frame benchmarks.
///
/// Every widget gets exactly the same bytes. Content is printable ASCII
/// with SGR styling (16, 256 and truecolor, bold, italic, underline,
/// backgrounds), so text shaping and Unicode width rules cannot make the
/// widgets do different work.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Grid width of every benchmark (ADR 0011: 200×60).
const benchCols = 200;

/// Grid height of every benchmark.
const benchRows = 60;

/// The three frame scenarios of ADR 0011's performance targets.
enum Scenario {
  /// No output: frames that only recomposite the unchanged screen.
  idle('idle'),

  /// Three rows rewritten per frame, the rest unchanged.
  dirtyRows('3 dirty rows'),

  /// Every row rewritten per frame with new text that never repeats.
  fullScreenFresh('full screen, fresh'),

  /// `cat` of a large text file: [scrollLinesPerFrame] new lines arrive at
  /// the bottom each frame and the screen scrolls.
  scroll('scroll (cat)'),

  /// A fixed layout (the setup screen) in which [htopFieldsPerRow] numeric
  /// fields of [htopFieldWidth] cells per row get new values every frame:
  /// 20 % of the cells, every row changed.
  htop('htop-like (20 % of cells)'),

  /// Every row rewritten per frame, from a repeating set of
  /// [fullScreenCycle] screens: after the warm-up every frame repeats one
  /// already drawn, so it measures replaying caches, not rendering new
  /// text (a view that caches whole rows by content draws no text at all).
  fullScreen('full screen, warm (cache replay)');

  const Scenario(this.label);

  /// The name used in reports.
  final String label;
}

/// How many different screens the full-screen scenario cycles through.
const fullScreenCycle = 8;

/// New lines per frame in the scroll scenario (a tenth of the screen).
const scrollLinesPerFrame = 6;

/// Numeric fields rewritten per row and frame in the htop-like scenario.
const htopFieldsPerRow = 5;

/// Cells per htop-like field: 5 × 8 = 40 of 200 cells per row, 20 %.
const htopFieldWidth = 8;

/// The first column (1-based) of each htop-like field, evenly spread.
List<int> get htopFieldColumns => [
  for (var i = 0; i < htopFieldsPerRow; i++)
    1 + i * benchCols ~/ htopFieldsPerRow + 12,
];

const _textWords = [
  'the',
  'of',
  'and',
  'to',
  'in',
  'a',
  'is',
  'that',
  'for',
  'it',
  'as',
  'with',
  'was',
  'on',
  'be',
  'by',
  'this',
  'are',
  'from',
  'or',
  'which',
  'return',
  'final',
  'const',
  'void',
  'class',
  'int',
  'String',
  '{',
  '}',
  '(',
  ');',
  '=',
  '==',
  '//',
  'if',
  'else',
  'null',
  'true',
  'false',
  'terminal',
  'buffer',
  'render',
  'value',
  'error:',
  'warning:',
  '0x1f',
  '2026-11-10T09:15:56Z',
  'INFO',
  'DEBUG',
  '[ok]',
  'path/to/file.dart',
];

/// One line of a plain text file (no escape sequences), 0 to 160 columns:
/// shorter than the screen, so nothing wraps.
String _textLine(Random random) {
  final target = random.nextInt(8) == 0 ? 0 : 10 + random.nextInt(150);
  final out = StringBuffer(' ' * (random.nextInt(4) * 2));
  while (out.length < target) {
    if (out.isNotEmpty) out.write(' ');
    out.write(_textWords[random.nextInt(_textWords.length)]);
  }
  final line = out.toString();
  return line.length > 160 ? line.substring(0, 160) : line;
}

const _htopSgrs = ['32', '31', '33', '36', '1;37', '34'];

const _sgrs = [
  '', // default colours
  '31', '32', '33', '34', '35', '36', '91', '94', // 16 colours
  '1', '3', '4', '1;33', // attributes
  '38;5;208', '38;5;45', '38;5;141', // 256 colours
  '38;2;255;121;198', '38;2;80;250;123', // truecolor
  '30;42', '97;44', '48;5;236', '48;2;40;42;54', // backgrounds
];

/// One styled row of exactly [benchCols] printable columns.
String _row(Random random) {
  final out = StringBuffer();
  var columns = 0;
  while (columns < benchCols) {
    var len = min(1 + random.nextInt(14), benchCols - columns);
    // Never end a row on the separator space (trimmed when compared).
    if (benchCols - columns - len == 1) len++;
    final word = String.fromCharCodes([
      for (var i = 0; i < len; i++) 0x21 + random.nextInt(94),
    ]);
    final sgr = _sgrs[random.nextInt(_sgrs.length)];
    out.write(sgr.isEmpty ? '\x1b[0m$word' : '\x1b[0;${sgr}m$word');
    columns += len;
    if (columns < benchCols) {
      out.write('\x1b[0m ');
      columns++;
    }
  }
  out.write('\x1b[0m');
  return out.toString();
}

/// A whole screen: every row drawn at its own position (CUP), so nothing
/// scrolls.
String _screen(Random random) {
  final out = StringBuffer('\x1b[H');
  for (var row = 1; row <= benchRows; row++) {
    out.write('\x1b[$row;1H${_row(random)}');
  }
  return out.toString();
}

/// The bytes written once before a scenario: reset, clear, hide the cursor
/// (no blink differences between widgets), fill every row.
Uint8List setupBytes({int seed = 42}) =>
    utf8.encode('\x1bc\x1b[2J\x1b[?25l${_screen(Random(seed))}');

/// [count] per-frame writes for [scenario]; an empty list element means
/// "write nothing this frame". The same arguments always give the same
/// bytes.
List<Uint8List> frameWrites(Scenario scenario, int count, {int seed = 42}) {
  final random = Random(seed + scenario.index);
  switch (scenario) {
    case Scenario.idle:
      return List.filled(count, Uint8List(0));
    case Scenario.dirtyRows:
      return [
        for (var i = 0; i < count; i++)
          utf8.encode(
            [
              // Three distinct rows, spread over the screen, moving each frame.
              for (final offset in const [0, 20, 40])
                '\x1b[${(i + offset) % benchRows + 1};1H${_row(random)}',
            ].join(),
          ),
      ];
    case Scenario.fullScreenFresh:
      return [for (var i = 0; i < count; i++) utf8.encode(_screen(random))];
    case Scenario.scroll:
      return [
        for (var i = 0; i < count; i++)
          utf8.encode(
            [
              for (var l = 0; l < scrollLinesPerFrame; l++)
                '\r\n${_textLine(random)}',
            ].join(),
          ),
      ];
    case Scenario.htop:
      final columns = htopFieldColumns;
      return [
        for (var i = 0; i < count; i++)
          utf8.encode(
            [
              for (var row = 1; row <= benchRows; row++)
                for (final column in columns)
                  '\x1b[$row;${column}H'
                      '\x1b[0;${_htopSgrs[random.nextInt(_htopSgrs.length)]}m'
                      '${random.nextInt(100000000).toString().padLeft(htopFieldWidth)}',
            ].join(),
          ),
      ];
    case Scenario.fullScreen:
      final screens = [
        for (var i = 0; i < fullScreenCycle; i++) utf8.encode(_screen(random)),
      ];
      return [for (var i = 0; i < count; i++) screens[i % fullScreenCycle]];
  }
}

/// One stream of `warmUp + count` frames for [scenario], split into the
/// untraced warm-up and the measured continuation. Both come from the same
/// seed, so in the full-screen scenario every measured screen was already
/// drawn during the warm-up (when [warmUp] ≥ [fullScreenCycle]).
({List<Uint8List> warmUp, List<Uint8List> measured}) warmUpAndMeasured(
  Scenario scenario, {
  required int warmUp,
  required int count,
  int seed = 42,
}) {
  final all = frameWrites(scenario, warmUp + count, seed: seed);
  return (warmUp: all.sublist(0, warmUp), measured: all.sublist(warmUp));
}
