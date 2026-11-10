// Unit tests of the pixel-to-row accumulator (ADR 0011).

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
}
