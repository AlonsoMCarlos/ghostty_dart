// Micro benchmark of the render state on a full 200x50 screen.
//
// Run from packages/ghostty_dart (JIT):
//   mise exec -- dart run test/render/render_benchmark.dart
// For numbers closer to a release app, compile it (AOT):
//   mise exec -- dart build cli -t test/render/render_benchmark.dart
//
// It prints rows/s for the read loops a renderer runs every frame. Numbers
// are a baseline for this machine, not a comparison with other packages.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';

const _cols = 200;
const _rows = 50;

/// One benchmark result.
typedef RenderBenchmarkResult = ({
  String name,
  int frames,
  double rowsPerSecond,
});

/// Runs every scenario for about [duration] each and reports each result to
/// [report] (defaults to printing it).
List<RenderBenchmarkResult> runRenderBenchmark({
  Duration duration = const Duration(seconds: 2),
  void Function(RenderBenchmarkResult result)? report,
}) {
  final terminal = VtTerminal(cols: _cols, rows: _rows);
  final state = RenderState();
  try {
    terminal.write(_screen(0));
    state.update(terminal);
    final results = [
      _measure(
        'per-cell accessors (codepoint, width, style, bg)',
        duration,
        () {
          state.dirty = RenderDirtyState.full;
          _readCells(state);
        },
      ),
      _measure('style runs (styleRunEnd + writeTextTo)', duration, () {
        state.dirty = RenderDirtyState.full;
        _readRuns(state);
      }),
      _measure('update + style runs, no change', duration, () {
        state.update(terminal);
        state.dirty = RenderDirtyState.full;
        _readRuns(state);
      }),
      _measure('write full screen + update + style runs', duration, () {
        terminal.write(_screens[_frame++ & 1]);
        state.update(terminal);
        _readRuns(state);
        state.markClean();
      }),
    ];
    for (final result in results) {
      (report ?? _print)(result);
    }
    return results;
  } finally {
    state.dispose();
    terminal.dispose();
  }
}

void main() {
  print('RenderState benchmark, ${_cols}x$_rows cells');
  runRenderBenchmark();
}

int _frame = 0;
int _sink = 0;
final _screens = [_screen(1), _screen(2)];

void _print(RenderBenchmarkResult r) => print(
  '${r.name.padRight(52)} ${r.rowsPerSecond.round().toString().padLeft(9)} '
  'rows/s  (${(r.rowsPerSecond / _rows).toStringAsFixed(0)} frames/s)',
);

RenderBenchmarkResult _measure(
  String name,
  Duration duration,
  void Function() frame,
) {
  for (var i = 0; i < 20; i++) {
    frame();
  }
  final watch = Stopwatch()..start();
  var frames = 0;
  while (watch.elapsed < duration) {
    frame();
    frames++;
  }
  watch.stop();
  final seconds = watch.elapsedMicroseconds / 1e6;
  return (name: name, frames: frames, rowsPerSecond: frames * _rows / seconds);
}

void _readCells(RenderState state) {
  var sum = 0;
  for (final row in state.dirtyRows) {
    for (var x = 0; x < row.length; x++) {
      sum += row.codepointAt(x);
      sum += row.widthAt(x).index;
      if (row.styleAt(x).bold) sum++;
      if (row.backgroundAt(x) is RgbColor) sum++;
    }
  }
  _sink ^= sum;
}

void _readRuns(RenderState state) {
  var sum = 0;
  final text = StringBuffer();
  for (final row in state.dirtyRows) {
    final length = row.length;
    for (var x = 0; x < length;) {
      final end = row.styleRunEnd(x);
      final style = row.styleAt(x);
      text.clear();
      for (var i = x; i < end; i++) {
        row.writeTextTo(i, text);
      }
      sum += text.length + (style.bold ? 1 : 0);
      x = end;
    }
  }
  _sink ^= sum;
}

/// A full screen of text with ten styled runs per row (palette, RGB, bold,
/// underline), the kind of content `ls --color` or an editor produces.
Uint8List _screen(int seed) {
  final out = StringBuffer('\x1b[H');
  for (var y = 0; y < _rows; y++) {
    for (var run = 0; run < 10; run++) {
      final n = (y * 10 + run + seed) % 7;
      out
        ..write(switch (n) {
          0 => '\x1b[0m',
          1 => '\x1b[1;31m',
          2 => '\x1b[32;4m',
          3 => '\x1b[38;2;${y * 5};100;200m',
          4 => '\x1b[44m',
          5 => '\x1b[3;35m',
          _ => '\x1b[0;1m',
        })
        ..write(
          String.fromCharCodes(
            List.generate(20, (i) => 0x41 + (y + run + i + seed) % 58),
          ),
        );
    }
    out.write('\x1b[0m');
    if (y < _rows - 1) out.write('\r\n');
  }
  return utf8.encode(out.toString());
}

/// Keeps results observable so the loops are not optimised away.
int get benchmarkSink => _sink;
