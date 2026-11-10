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

  /// Every row rewritten per frame, from a repeating set of screens so
  /// glyph and paragraph caches are warm after the warm-up.
  fullScreen('full screen, warm');

  const Scenario(this.label);

  /// The name used in reports.
  final String label;
}

/// How many different screens the full-screen scenario cycles through.
const fullScreenCycle = 8;

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
