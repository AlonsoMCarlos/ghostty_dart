/// The terminal widgets the frame benchmarks compare, behind one
/// interface: ghostty_dart_flutter on both text paths (ADR 0012), xterm
/// 4.0.0 and xterm2 5.4.0.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:xterm/xterm.dart' as xterm;
import 'package:xterm2/xterm.dart' as xterm2;

import 'frame_streams.dart';

/// A terminal widget under test, fixed at [benchCols] × [benchRows].
abstract interface class BenchSubject {
  /// The name used in reports and report keys.
  String get name;

  /// The widget, sized to hold the whole grid.
  Widget build(TextStyle style, double devicePixelRatio);

  /// Feeds program output. The xterm engines take text, so their bytes are
  /// UTF-8 decoded here; this runs between frames, not inside one, so it
  /// is not part of the frame times.
  void write(Uint8List bytes);

  /// The text of visible [row] (0-based), trailing blanks removed: the
  /// harness checks that every widget shows the same screen.
  String rowText(int row);

  /// Releases the terminal.
  void dispose();
}

/// Every subject, in report order.
List<BenchSubject Function()> get allSubjects => [
  GhosttySubject.new,
  () => GhosttySubject(textRendering: VtTextRendering.paragraphs),
  XtermSubject.new,
  Xterm2Subject.new,
];

/// The grid's size in logical pixels for [style] by the measurement
/// ghostty_dart_flutter uses (device-pixel-aligned cells).
Size ghosttyGridSize(TextStyle style, double devicePixelRatio) {
  final metrics = VtCellMetrics.measure(
    style,
    devicePixelRatio: devicePixelRatio,
  );
  return Size(
    metrics.widthPx * benchCols / devicePixelRatio,
    metrics.heightPx * benchRows / devicePixelRatio,
  );
}

/// The grid's size for the xterm painters: they measure a monospace cell
/// from the font's advance and line height without pixel alignment. A
/// little slack keeps the last row and column inside the viewport, so they
/// are painted.
Size _xtermGridSize(TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: 'M' * 100, style: style.copyWith(height: 1)),
    textDirection: TextDirection.ltr,
  )..layout();
  final size = Size(
    painter.width / 100 * benchCols * 1.02 + 2,
    painter.height * benchRows * 1.02 + 2,
  );
  painter.dispose();
  return size;
}

/// ghostty_dart_flutter's `VtTerminalView`, drawing text with
/// [textRendering].
final class GhosttySubject implements BenchSubject {
  /// Creates the 200×60 controller.
  GhosttySubject({this.textRendering = VtTextRendering.atlas});

  /// The text path (the view's default is the atlas).
  final VtTextRendering textRendering;

  final _controller = VtTerminalController(cols: benchCols, rows: benchRows);

  @override
  String get name => switch (textRendering) {
    VtTextRendering.atlas => 'ghostty_dart_flutter',
    VtTextRendering.paragraphs => 'ghostty_dart_flutter (paragraphs)',
  };

  @override
  Widget build(TextStyle style, double devicePixelRatio) {
    final size = ghosttyGridSize(style, devicePixelRatio);
    return SizedBox.fromSize(
      size: size,
      child: VtTerminalView(
        controller: _controller,
        textStyle: style,
        textRendering: textRendering,
      ),
    );
  }

  @override
  void write(Uint8List bytes) => _controller.writeBytes(bytes);

  @override
  String rowText(int row) {
    final formatter = TerminalFormatter(_controller.terminal);
    try {
      final lines = formatter.formatText().split('\n');
      return row < lines.length ? lines[row].trimRight() : '';
    } finally {
      formatter.dispose();
    }
  }

  @override
  void dispose() => _controller.dispose();
}

/// xterm 4.0.0's `TerminalView`.
final class XtermSubject implements BenchSubject {
  /// Creates the 200×60 terminal.
  XtermSubject() {
    _terminal.resize(benchCols, benchRows);
  }

  final _terminal = xterm.Terminal(maxLines: 1000);

  @override
  String get name => 'xterm 4.0.0';

  @override
  Widget build(TextStyle style, double devicePixelRatio) => SizedBox.fromSize(
    size: _xtermGridSize(style),
    child: xterm.TerminalView(
      _terminal,
      textStyle: xterm.TerminalStyle.fromTextStyle(style.copyWith(height: 1)),
      autoResize: false,
      hardwareKeyboardOnly: true,
    ),
  );

  @override
  void write(Uint8List bytes) =>
      _terminal.write(utf8.decode(bytes, allowMalformed: true));

  @override
  String rowText(int row) => _terminal.buffer.lines[row].getText().trimRight();

  @override
  void dispose() {}
}

/// xterm2 5.4.0's `TerminalView`.
final class Xterm2Subject implements BenchSubject {
  /// Creates the 200×60 terminal.
  Xterm2Subject() {
    _terminal.resize(benchCols, benchRows);
  }

  final _terminal = xterm2.Terminal(maxLines: 1000);

  @override
  String get name => 'xterm2 5.4.0';

  @override
  Widget build(TextStyle style, double devicePixelRatio) => SizedBox.fromSize(
    size: _xtermGridSize(style),
    child: xterm2.TerminalView(
      _terminal,
      textStyle: xterm2.TerminalStyle.fromTextStyle(style.copyWith(height: 1)),
      autoResize: false,
      hardwareKeyboardOnly: true,
      cursorBlink: false,
    ),
  );

  @override
  void write(Uint8List bytes) =>
      _terminal.write(utf8.decode(bytes, allowMalformed: true));

  @override
  String rowText(int row) => _terminal.buffer.lines[row].getText().trimRight();

  @override
  void dispose() => _terminal.dispose();
}
