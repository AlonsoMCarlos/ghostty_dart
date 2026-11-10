// VtCellMetrics.measure (ADR 0011): the cell comes from the font alone.

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

void main() {
  const style = TextStyle(fontFamily: 'FlutterTest', fontSize: 10);

  test('the style height, letter and word spacing are ignored', () {
    final plain = VtCellMetrics.measure(style, devicePixelRatio: 2);
    final styled = VtCellMetrics.measure(
      style.copyWith(height: 3, letterSpacing: 4, wordSpacing: 5),
      devicePixelRatio: 2,
    );
    expect(styled, plain);
    // The test font: one em wide, 0.75 + 0.25 em tall.
    expect((plain.width, plain.height, plain.baseline), (10, 10, 7.5));
  });

  test('lineHeight and textScaler change the cell', () {
    final tall = VtCellMetrics.measure(
      style,
      devicePixelRatio: 1,
      lineHeight: 1.5,
    );
    expect((tall.width, tall.height, tall.baseline), (10, 15, 10));
    final scaled = VtCellMetrics.measure(
      style,
      devicePixelRatio: 1,
      textScaler: const TextScaler.linear(2),
    );
    expect((scaled.width, scaled.height), (20, 20));
  });
}
