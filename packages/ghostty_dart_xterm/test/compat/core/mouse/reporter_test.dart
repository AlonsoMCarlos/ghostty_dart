// Ported from package:xterm 4.0.0 (src/core/mouse/reporter_test.dart).
// Copyright (c) 2020 xuty. MIT License, see test/compat/LICENSE.xterm.
// Changes: imports (package:test -> flutter_test, package:xterm -> package:ghostty_dart_xterm;
// the internal reporter import points at this package's src/: MouseReporter is not exported, as
// in xterm); the normal and utf tests are skipped as a documented difference (row off-by-one),
// each followed by a marked ghostty_dart_xterm test with the correct row.

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/src/core/mouse/reporter.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

void main() {
  group('MouseReporter', () {
    test(
      'report() supports normal mode',
      () {
        final output = MouseReporter.report(
          TerminalMouseButton.left,
          TerminalMouseButtonState.down,
          CellOffset(0, 0),
          MouseReportMode.normal,
        );

        expect(output, equals('\x1B[M !"'));
      },
      skip:
          'differs from xterm: normal and UTF-8 mouse reports encode the row as 32 + y; xterm sends 32 + y + 1 (an off-by-one; ClickMouseHandler.call), see COMPATIBILITY.md',
    );

    // ghostty_dart_xterm: the correct row (32 + 1). Not part of xterm's suite.
    test('report() supports normal mode (correct row)', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.normal,
      );

      expect(output, equals('\x1B[M !!'));
    });

    test(
      'report() supports utf mode',
      () {
        final output = MouseReporter.report(
          TerminalMouseButton.left,
          TerminalMouseButtonState.down,
          CellOffset(0, 0),
          MouseReportMode.utf,
        );

        expect(output, equals('\x1B[M !"'));
      },
      skip:
          'differs from xterm: normal and UTF-8 mouse reports encode the row as 32 + y; xterm sends 32 + y + 1 (an off-by-one; ClickMouseHandler.call), see COMPATIBILITY.md',
    );

    // ghostty_dart_xterm: the correct row (32 + 1). Not part of xterm's suite.
    test('report() supports utf mode (correct row)', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.utf,
      );

      expect(output, equals('\x1B[M !!'));
    });

    test('report() supports sgr mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.sgr,
      );

      expect(output, equals('\x1B[<0;1;1M'));
    });

    test('report() supports urxvt mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.urxvt,
      );

      expect(output, equals('\x1B[32;1;1M'));
    });
  });
}
