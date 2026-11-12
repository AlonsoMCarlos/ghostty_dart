// Ported from package:xterm 4.0.0 (src/core/buffer/segment_test.dart).
// Copyright (c) 2020 xuty. MIT License, see test/compat/LICENSE.xterm.
// Changes: imports (package:test -> flutter_test, package:xterm -> package:ghostty_dart_xterm).

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

void main() {
  group('BufferSegment', () {
    test('isWithin() works', () {
      final segments = BufferRangeLine(
        CellOffset(10, 10),
        CellOffset(10, 12),
      ).toSegments().toList();

      expect(segments[0].start, equals(10));
      expect(segments[0].end, null);
      expect(segments[0].isWithin(CellOffset(10, 10)), isTrue);
      expect(segments[0].isWithin(CellOffset(11, 10)), isTrue);
      expect(segments[0].isWithin(CellOffset(100, 10)), isTrue);
      expect(segments[0].isWithin(CellOffset(9, 10)), isFalse);

      expect(segments[1].start, null);
      expect(segments[1].end, null);
      expect(segments[1].isWithin(CellOffset(10, 11)), isTrue);
      expect(segments[1].isWithin(CellOffset(11, 11)), isTrue);
      expect(segments[1].isWithin(CellOffset(100, 11)), isTrue);
      expect(segments[1].isWithin(CellOffset(0, 11)), isTrue);

      expect(segments[2].start, null);
      expect(segments[2].end, 10);
      expect(segments[2].isWithin(CellOffset(0, 12)), isTrue);
      expect(segments[2].isWithin(CellOffset(10, 12)), isTrue);
      expect(segments[2].isWithin(CellOffset(11, 12)), isFalse);
    });
  });
}
