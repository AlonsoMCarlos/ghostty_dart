/// Deterministic, seeded VT byte streams that imitate real program output.
///
/// Every generator appends to a [BytesBuilder] until it holds at least the
/// requested number of bytes. The same seed and size always produce the same
/// bytes, so every engine and every run sees exactly the same input.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// The terminal size every engine uses.
const benchCols = 200;

/// The terminal height every engine uses.
const benchRows = 50;

/// Scrollback lines every engine keeps (above the visible screen).
const benchScrollback = 10000;

/// A named workload.
final class Workload {
  const Workload(this.name, this.description, this._generate);

  /// Short id used on the command line and in the results.
  final String name;

  /// One line describing what the stream imitates.
  final String description;

  final void Function(_Out out, Random random) _generate;

  /// Generates at least [bytes] bytes with the given [seed].
  Uint8List generate(int bytes, {int seed = 42}) {
    _tuiStarted = false;
    final out = _Out(bytes);
    final random = Random(seed);
    while (!out.full) {
      _generate(out, random);
    }
    return out.takeBytes();
  }
}

/// All workloads, in report order.
const workloads = <Workload>[
  Workload('ascii', 'Plain ASCII text lines (< 200 cols), CRLF', _ascii),
  Workload('sgr', '`ls --color`-like: 16/256/truecolor SGR per word', _sgr),
  Workload(
    'unicode',
    'CJK, emoji, ZWJ/skin-tone/flag graphemes, combining',
    _unicode,
  ),
  Workload(
    'tui',
    'Full-screen TUI redraws: alt screen, CUP, scroll regions, EL',
    _tui,
  ),
  Workload(
    'wrapped',
    '`cat` of long lines (500-5000 cols) that wrap',
    _wrapped,
  ),
];

/// Looks up a workload by [name].
Workload workloadNamed(String name) => workloads.firstWhere(
  (w) => w.name == name,
  orElse: () => throw ArgumentError.value(name, 'workload'),
);

final class _Out {
  _Out(this.target);
  final int target;
  final _builder = BytesBuilder(copy: false);
  bool get full => _builder.length >= target;
  void str(String s) => _builder.add(utf8.encode(s));
  Uint8List takeBytes() => _builder.takeBytes();
}

const _letters =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const _punct = '.,;:-_/()[]{}<>=+*&%\$#@!?\'"`~|^';

String _word(Random r, [int maxLen = 10]) {
  final len = 1 + r.nextInt(maxLen);
  final b = StringBuffer();
  for (var i = 0; i < len; i++) {
    b.writeCharCode(
      r.nextInt(12) == 0
          ? _punct.codeUnitAt(r.nextInt(_punct.length))
          : _letters.codeUnitAt(r.nextInt(_letters.length)),
    );
  }
  return b.toString();
}

/// A line of words no wider than [maxCols] columns.
String _line(Random r, int maxCols) {
  final target = r.nextInt(maxCols);
  final b = StringBuffer();
  while (true) {
    final w = _word(r);
    if (b.length + w.length + 1 > target) break;
    if (b.isNotEmpty) b.write(' ');
    b.write(w);
  }
  return b.toString();
}

void _ascii(_Out out, Random r) {
  // Batch lines to keep the generator cheap.
  final b = StringBuffer();
  for (var i = 0; i < 256; i++) {
    b
      ..write(_line(r, 120))
      ..write('\r\n');
  }
  out.str(b.toString());
}

String _sgrStart(Random r) {
  switch (r.nextInt(6)) {
    case 0:
      return '\x1b[0${r.nextBool() ? ';01' : ''};3${r.nextInt(8)}m';
    case 1:
      return '\x1b[01;34m'; // directory
    case 2:
      return '\x1b[38;5;${r.nextInt(256)}m';
    case 3:
      return '\x1b[38;2;${r.nextInt(256)};${r.nextInt(256)};${r.nextInt(256)}m';
    case 4:
      return '\x1b[${[1, 3, 4, 7][r.nextInt(4)]};48;5;${r.nextInt(256)};'
          '38;2;${r.nextInt(256)};${r.nextInt(256)};${r.nextInt(256)}m';
    default:
      return '\x1b[9${r.nextInt(8)};4${r.nextInt(8)}m';
  }
}

void _sgr(_Out out, Random r) {
  final b = StringBuffer();
  for (var i = 0; i < 128; i++) {
    var cols = 0;
    final entries = 1 + r.nextInt(8);
    for (var e = 0; e < entries; e++) {
      final name = '${_word(r, 14)}.${_word(r, 3)}';
      if (cols + name.length + 2 > 190) break;
      b
        ..write(_sgrStart(r))
        ..write(name)
        ..write('\x1b[0m  ');
      cols += name.length + 2;
    }
    b.write('\r\n');
  }
  out.str(b.toString());
}

const _graphemes = <String>[
  '👍', '😀', '🎉', '🚀', '❤️', //
  '👍🏽', '👋🏿', // skin tones
  '👨‍👩‍👧', '🏳️‍🌈', '🧑‍💻', // ZWJ sequences
  '🇪🇸', '🇯🇵', // flags (regional indicator pairs)
  'é', 'ñ', 'å', // precomposed
  'é', 'ñ', 'å', // combining marks
];

void _unicode(_Out out, Random r) {
  final b = StringBuffer();
  for (var i = 0; i < 128; i++) {
    var cols = 0;
    while (cols < 140) {
      switch (r.nextInt(5)) {
        case 0 || 1:
          // CJK unified ideographs, double width.
          final n = 1 + r.nextInt(6);
          for (var k = 0; k < n; k++) {
            b.writeCharCode(0x4E00 + r.nextInt(0x5000));
          }
          cols += 2 * n;
        case 2:
          // Hiragana, double width.
          final n = 1 + r.nextInt(4);
          for (var k = 0; k < n; k++) {
            b.writeCharCode(0x3041 + r.nextInt(0x50));
          }
          cols += 2 * n;
        case 3:
          b.write(_graphemes[r.nextInt(_graphemes.length)]);
          cols += 2;
        default:
          final w = _word(r, 8);
          b.write(w);
          cols += w.length;
      }
      b.write(' ');
      cols += 1;
    }
    b.write('\r\n');
  }
  out.str(b.toString());
}

// Whether the TUI stream has entered the alternate screen yet; reset by
// [Workload.generate] so generation is reproducible within one process.
bool _tuiStarted = false;

void _tui(_Out out, Random r) {
  final b = StringBuffer();
  if (!_tuiStarted || r.nextInt(64) == 0) {
    // Enter the alternate screen (like vim/htop do on start).
    b.write('\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J');
    _tuiStarted = true;
  }
  // htop-like header: meters with coloured bars.
  b.write('\x1b[H');
  for (var row = 1; row <= 6; row++) {
    final fill = r.nextInt(60);
    b
      ..write('\x1b[$row;1H\x1b[0;1m CPU${row - 1}\x1b[0m [')
      ..write('\x1b[32m${'|' * (fill ~/ 2)}')
      ..write('\x1b[31m${'|' * (fill - fill ~/ 2)}')
      ..write('\x1b[0m${' ' * (60 - fill)}] ${fill * 100 ~/ 60}%\x1b[K');
  }
  // Process table inside a scroll region; scroll it a few lines and redraw
  // the new rows, like a pager or log view.
  b.write('\x1b[8;48r');
  // 1-4, never 0: engines disagree on `CSI 0 T` (xterm2_core scrolls one
  // line like the real xterm; ghostty and xterm.dart 4.0.0 do nothing), and
  // real programs do not send it.
  final scroll = 1 + r.nextInt(4);
  if (r.nextBool()) {
    b.write('\x1b[48;1H${'\n' * scroll}');
  } else {
    b.write('\x1b[${scroll}T');
  }
  for (var row = 8; row <= 48; row++) {
    if (r.nextInt(3) != 0) continue;
    final pid = 1000 + r.nextInt(90000);
    final cpu = r.nextInt(1000) / 10;
    final selected = r.nextInt(30) == 0;
    b
      ..write('\x1b[$row;1H')
      ..write(selected ? '\x1b[30;46m' : '\x1b[0m')
      ..write('${pid.toString().padLeft(7)} ')
      ..write(
        '\x1b[${cpu > 50 ? '1;31' : '36'}m${cpu.toStringAsFixed(1).padLeft(5)}',
      )
      ..write(selected ? '\x1b[30;46m' : '\x1b[0m')
      ..write(' ${_line(r, 150)}\x1b[K\x1b[0m');
  }
  b.write('\x1b[r');
  // Status line with save/restore cursor, like vim.
  b
    ..write('\x1b7\x1b[50;1H\x1b[7m')
    ..write(' NORMAL \x1b[0m ${_word(r, 20)}.dart')
    ..write('\x1b[50;180H${r.nextInt(999)},${r.nextInt(80)}\x1b[K\x1b8');
  // Some single-cell edits: insert/delete chars and lines.
  for (var i = 0; i < 4; i++) {
    b.write(
      '\x1b[${8 + r.nextInt(40)};${1 + r.nextInt(190)}H'
      '${['\x1b[2@', '\x1b[3P', '\x1b[L', '\x1b[M', '\x1b[X'][r.nextInt(5)]}'
      '${_word(r, 6)}',
    );
  }
  out.str(b.toString());
}

void _wrapped(_Out out, Random r) {
  final b = StringBuffer();
  for (var i = 0; i < 16; i++) {
    final len = 500 + r.nextInt(4500);
    while (b.length < len) {
      b
        ..write(_word(r))
        ..write(' ');
    }
    b.write('\r\n');
    out.str(b.toString());
    b.clear();
  }
}
