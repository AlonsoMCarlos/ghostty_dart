/// One thin adapter per terminal engine, so the benchmark loop is identical
/// for all of them.
library;

import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart' as g;
import 'package:xterm/core.dart' as x;
import 'package:xterm2_core/xterm2_core.dart' as x2;

import 'workloads.dart';

/// A terminal engine under test.
abstract interface class Engine {
  /// Engine id: `ghostty_dart`, `xterm` or `xterm2_core`.
  String get name;

  /// Whether the engine's native input is bytes (`true`) or decoded text.
  bool get takesBytes;

  /// Feeds pty bytes (only when [takesBytes]).
  void writeBytes(Uint8List bytes);

  /// Feeds decoded text (only when not [takesBytes]).
  void writeString(String text);

  /// The visible screen, one string per row with trailing blanks trimmed.
  ///
  /// Normalised the same way for every engine: an empty cell is a space and
  /// the trailing half of a wide character is skipped. A non-empty row ends
  /// with ` ⟦n⟧`, the number of columns up to its last character, so two
  /// rows with the same text but a different cell layout (e.g. a grapheme
  /// taking one cell per code point) do not compare equal.
  List<String> screen();

  /// Frees the engine's resources.
  void dispose();
}

/// Engine ids, in report order.
const engineNames = ['ghostty_dart', 'xterm', 'xterm2_core'];

/// Creates a fresh [benchCols] × [benchRows] engine with [benchScrollback]
/// lines of scrollback.
Engine createEngine(String name) => switch (name) {
  'ghostty_dart' => _Ghostty(),
  'xterm' => _Xterm(),
  'xterm2_core' => _Xterm2(),
  _ => throw ArgumentError.value(name, 'engine'),
};

/// Version string of libghostty-vt and its build options.
String ghosttyBuildDescription() {
  final info = g.libghosttyVtBuildInfo;
  return 'libghostty-vt ${info.version}, optimize=${info.optimizeMode.name}, '
      'simd=${info.simd}';
}

final class _Ghostty implements Engine {
  _Ghostty() {
    _terminal
      // The default byte limit (~one 400 KB page) would make ghostty keep far
      // less history than the others; use the same line limit instead.
      ..scrollbackMaxBytes = null
      ..scrollbackMaxLines = benchScrollback;
  }

  final _terminal = g.VtTerminal(cols: benchCols, rows: benchRows);

  @override
  String get name => 'ghostty_dart';

  @override
  bool get takesBytes => true;

  @override
  void writeBytes(Uint8List bytes) => _terminal.write(bytes);

  @override
  void writeString(String text) => throw UnsupportedError('bytes only');

  @override
  List<String> screen() {
    final state = g.RenderState();
    try {
      state.update(_terminal);
      final rows = <String>[];
      for (final row in state.allRows) {
        final b = StringBuffer();
        var used = 0;
        for (var i = 0; i < row.length; i++) {
          final width = row.widthAt(i);
          if (width.isSpacer) continue;
          if (row.hasTextAt(i)) {
            row.writeTextTo(i, b);
            used = i + (width == g.CellWidth.wide ? 2 : 1);
          } else {
            b.write(' ');
          }
        }
        rows.add(_row(b, used));
      }
      return rows;
    } finally {
      state.dispose();
    }
  }

  @override
  void dispose() => _terminal.dispose();
}

final class _Xterm implements Engine {
  _Xterm() {
    _terminal.resize(benchCols, benchRows);
  }

  // xterm's maxLines counts the visible rows too.
  final _terminal = x.Terminal(maxLines: benchScrollback + benchRows);

  @override
  String get name => 'xterm';

  @override
  bool get takesBytes => false;

  @override
  void writeBytes(Uint8List bytes) => throw UnsupportedError('text only');

  @override
  void writeString(String text) => _terminal.write(text);

  @override
  List<String> screen() {
    final buffer = _terminal.buffer;
    final rows = <String>[];
    for (var y = 0; y < buffer.viewHeight; y++) {
      final line = buffer.lines[buffer.scrollBack + y];
      rows.add(
        _xtermRow(line.length, line.getCodePoint, line.getWidth, (_) => null),
      );
    }
    return rows;
  }

  @override
  void dispose() {}
}

final class _Xterm2 implements Engine {
  _Xterm2() {
    _terminal.resize(benchCols, benchRows);
  }

  // Same convention as xterm: maxLines includes the visible rows.
  final _terminal = x2.Terminal(maxLines: benchScrollback + benchRows);

  @override
  String get name => 'xterm2_core';

  @override
  bool get takesBytes => false;

  @override
  void writeBytes(Uint8List bytes) => throw UnsupportedError('text only');

  @override
  void writeString(String text) => _terminal.write(text);

  @override
  List<String> screen() {
    final buffer = _terminal.buffer;
    final rows = <String>[];
    for (var y = 0; y < buffer.viewHeight; y++) {
      final line = buffer.lines[buffer.scrollBack + y];
      rows.add(
        _xtermRow(
          line.length,
          line.getCodePoint,
          line.getWidth,
          line.getCombiningCharacters,
        ),
      );
    }
    return rows;
  }

  @override
  void dispose() => _terminal.dispose();
}

String _row(StringBuffer text, int usedColumns) {
  final t = text.toString().trimRight();
  return usedColumns == 0 ? t : '$t ⟦$usedColumns⟧';
}

/// A row of xterm or xterm2_core, which share the same cell layout: a cell
/// holds one code point (0 when empty), and a wide character's second cell
/// is empty.
String _xtermRow(
  int length,
  int Function(int) codePoint,
  int Function(int) width,
  String? Function(int) combining,
) {
  final b = StringBuffer();
  var used = 0;
  for (var i = 0; i < length; i++) {
    final cp = codePoint(i);
    if (cp == 0) {
      if (i > 0 && width(i - 1) == 2 && codePoint(i - 1) != 0) continue;
      b.write(' ');
    } else {
      b.writeCharCode(cp);
      final extra = combining(i);
      if (extra != null) b.write(extra);
      final w = width(i);
      used = i + (w < 1 ? 1 : w);
    }
  }
  return _row(b, used);
}
