// Unit tests of the pixel-to-row accumulator (ADR 0011).

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/src/scroll/row_accumulator.dart';

void main() {
  test('whole rows come out, the remainder stays pending', () {
    final rows = RowAccumulator();
    expect(rows.add(15, 20), 0);
    expect(rows.pending, 15);
    expect(rows.add(15, 20), 1);
    expect(rows.pending, 10);
    expect(rows.add(-50, 20), -2);
    expect(rows.pending, closeTo(0, 1e-9));
  });

  test('rows round towards zero in both directions', () {
    final rows = RowAccumulator();
    expect(rows.add(-59, 20), -2);
    expect(rows.pending, -19);
    expect(rows.add(59, 20), 2);
    expect(rows.pending, 0);
  });

  test('slow scrolling loses no distance', () {
    final rows = RowAccumulator();
    var total = 0;
    for (var i = 0; i < 1000; i++) {
      total += rows.add(0.3, 17);
    }
    expect(total, (300 / 17).floor());
  });

  test('reset drops the pending distance; bad input adds nothing', () {
    final rows = RowAccumulator()..add(12, 20);
    rows.reset();
    expect(rows.pending, 0);
    expect(rows.add(double.nan, 20), 0);
    expect(rows.add(double.infinity, 20), 0);
    expect(rows.add(40, 0), 0);
    expect(rows.add(40, -1), 0);
    expect(rows.pending, 0);
  });

  group('wheelScrollExtent', () {
    double extent(
      double delta, {
      TargetPlatform platform = TargetPlatform.macOS,
      PointerDeviceKind kind = PointerDeviceKind.mouse,
      bool isolated = true,
    }) => wheelScrollExtent(
      delta,
      17,
      platform: platform,
      kind: kind,
      isolated: isolated,
    );

    test('a slow macOS notch is at least one line of three rows', () {
      // 0.1 line (4 px) and 0.5 line: three 17 px rows either way.
      expect(extent(4), 51);
      expect(extent(-20), -51);
      final rows = RowAccumulator();
      expect(rows.add(extent(-4), 17), -3);
    });

    test('faster macOS wheels keep their lines, three rows each', () {
      expect(extent(100), 2.5 * 3 * 17);
    });

    test('other platforms, devices and zero pass through', () {
      expect(extent(4, platform: TargetPlatform.linux), 4);
      expect(extent(4, platform: TargetPlatform.windows), 4);
      expect(extent(4, kind: PointerDeviceKind.trackpad), 4);
      expect(extent(0), 0);
      expect(extent(double.nan).isNaN, isTrue);
    });

    test('events inside a stream keep their pixels (precise deltas)', () {
      expect(extent(4, isolated: false), 4);
      expect(extent(-1, isolated: false), -1);
    });

    test('WheelStream: a pause of wheelStreamGap starts a stream', () {
      final stream = WheelStream();
      expect(stream.isolated(const Duration(seconds: 1)), isTrue);
      expect(stream.isolated(const Duration(milliseconds: 1016)), isFalse);
      expect(stream.isolated(const Duration(milliseconds: 1100)), isFalse);
      expect(
        stream.isolated(const Duration(milliseconds: 1100) + wheelStreamGap),
        isTrue,
      );
    });
  });
}
