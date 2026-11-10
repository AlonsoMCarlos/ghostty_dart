import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_widget_benchmarks/src/frame_streams.dart';

final _sgr = RegExp(r'\x1b\[[0-9;]*m');
final _cup = RegExp(r'\x1b\[(\d+);1H');

/// Row number -> visible text written there, for CUP-addressed output.
Map<int, String> _rows(String text) {
  final rows = <int, String>{};
  final matches = _cup.allMatches(text).toList();
  for (var i = 0; i < matches.length; i++) {
    final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
    rows[int.parse(matches[i].group(1)!)] = text
        .substring(matches[i].end, end)
        .replaceAll(_sgr, '');
  }
  return rows;
}

void main() {
  test('setup resets, hides the cursor and fills all 60 rows of 200', () {
    final text = utf8.decode(setupBytes());
    expect(text, startsWith('\x1bc\x1b[2J\x1b[?25l\x1b[H'));
    final rows = _rows(text);
    expect(rows.keys, List.generate(benchRows, (i) => i + 1));
    for (final row in rows.values) {
      expect(row.length, benchCols);
      expect(row.codeUnits.every((c) => c >= 0x20 && c < 0x7f), isTrue);
    }
  });

  test('streams are deterministic', () {
    for (final scenario in Scenario.values) {
      expect(
        frameWrites(scenario, 20),
        frameWrites(scenario, 20),
        reason: scenario.name,
      );
    }
    expect(setupBytes(), setupBytes());
  });

  test('idle writes nothing', () {
    expect(frameWrites(Scenario.idle, 10).every((b) => b.isEmpty), isTrue);
  });

  test('dirty rows rewrites exactly 3 distinct full rows per frame', () {
    final frames = frameWrites(Scenario.dirtyRows, 70);
    final seen = <int>{};
    for (final bytes in frames) {
      final rows = _rows(utf8.decode(bytes));
      expect(rows, hasLength(3));
      expect(rows.values.every((r) => r.length == benchCols), isTrue);
      seen.addAll(rows.keys);
    }
    // Over a screen's worth of frames every row gets dirty at some point.
    expect(seen, hasLength(benchRows));
  });

  test('full screen rewrites all rows and repeats every cycle', () {
    final frames = frameWrites(Scenario.fullScreen, fullScreenCycle * 2);
    for (final bytes in frames) {
      expect(_rows(utf8.decode(bytes)), hasLength(benchRows));
    }
    expect(frames[0], isNot(frames[1]));
    expect(frames[fullScreenCycle], frames[0]);
  });

  test('every measured full-screen frame was drawn in the warm-up', () {
    final (:warmUp, :measured) = warmUpAndMeasured(
      Scenario.fullScreen,
      warmUp: fullScreenCycle * 4,
      count: 50,
    );
    expect(warmUp, hasLength(fullScreenCycle * 4));
    expect(measured, hasLength(50));
    for (final frame in measured) {
      expect(warmUp, contains(frame));
    }
    // The dirty-rows stream continues where the warm-up stopped.
    final dirty = warmUpAndMeasured(Scenario.dirtyRows, warmUp: 5, count: 5);
    expect([
      ...dirty.warmUp,
      ...dirty.measured,
    ], frameWrites(Scenario.dirtyRows, 10));
  });

  test('full screen, fresh rewrites all rows and never repeats a row', () {
    final frames = frameWrites(Scenario.fullScreenFresh, 40);
    final seen = <String>{};
    for (final bytes in frames) {
      final rows = _rows(utf8.decode(bytes));
      expect(rows, hasLength(benchRows));
      for (final row in rows.values) {
        expect(row.length, benchCols);
        expect(seen.add(row), isTrue, reason: 'a row repeated: $row');
      }
    }
    // The measured frames are not in the warm-up either.
    final (:warmUp, :measured) = warmUpAndMeasured(
      Scenario.fullScreenFresh,
      warmUp: 32,
      count: 10,
    );
    for (final frame in measured) {
      expect(warmUp, isNot(contains(frame)));
    }
  });

  test('scroll appends plain lines at the bottom, none wider than 160', () {
    for (final bytes in frameWrites(Scenario.scroll, 50)) {
      final text = utf8.decode(bytes);
      expect(text, isNot(contains('\x1b')));
      final lines = text.split('\r\n');
      expect(lines.first, isEmpty); // starts with CR LF: scrolls first
      expect(lines.skip(1), hasLength(scrollLinesPerFrame));
      for (final line in lines.skip(1)) {
        expect(line.length, lessThanOrEqualTo(160));
        expect(line.codeUnits.every((c) => c >= 0x20 && c < 0x7f), isTrue);
      }
    }
  });

  test('htop-like rewrites 20 % of the cells, in every row', () {
    final fieldAt = RegExp(r'\x1b\[(\d+);(\d+)H\x1b\[[0-9;]*m([ 0-9]+)');
    final columns = htopFieldColumns;
    for (final bytes in frameWrites(Scenario.htop, 10)) {
      final fields = fieldAt.allMatches(utf8.decode(bytes)).toList();
      expect(fields, hasLength(benchRows * htopFieldsPerRow));
      final cells = fields.fold(0, (sum, m) => sum + m.group(3)!.length);
      expect(cells / (benchRows * benchCols), 0.2);
      expect({
        for (final m in fields) int.parse(m.group(1)!),
      }, hasLength(benchRows));
      for (final m in fields) {
        expect(columns, contains(int.parse(m.group(2)!)));
        expect(
          int.parse(m.group(2)!) + htopFieldWidth - 1,
          lessThan(benchCols),
        );
      }
    }
  });
}
