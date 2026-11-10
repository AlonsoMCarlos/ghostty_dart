// Shared set-up for the pointer and scrollbar widget tests: a real
// controller and its seams under a TerminalPointerScope and a
// TerminalScrollbar. Cells are 10 x 20 logical px; the device pixel ratio
// and the padding are options, so the local -> surface conversion is
// tested where a mix-up would show.

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/input/pointer/terminal_pointer_scope.dart';
import 'package:ghostty_dart_flutter/src/scroll/terminal_scrollbar.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_geometry.dart';

/// A pumped pointer scope over a real controller.
final class PointerHarness {
  PointerHarness._(this.controller, this.seams, this.geometry);

  /// The controller; disposed in tear-down.
  final VtTerminalController controller;

  /// The seams every part of the scope uses.
  final ControllerSeams seams;

  /// 10 x 20 logical px cells, with the requested DPR and padding.
  final TerminalGeometry geometry;

  final _output = <int>[];

  /// Everything sent to `onOutput` since the last [takeOutput].
  String takeOutput() {
    final text = latin1.decode(_output);
    _output.clear();
    return text;
  }

  /// A point in the viewport cell [col], [row] in local coordinates
  /// ([dx] across the cell, half-way down). The view is at the top-left
  /// of the test window, so local and global coordinates are the same.
  Offset cell(int col, int row, {double dx = 0.5}) =>
      geometry.cellOrigin(col, row) +
      Offset(dx * geometry.metrics.width, geometry.metrics.height / 2);

  /// The viewport's position.
  ViewportScrollbar get bar => controller.scrollbar;
}

/// Cell metrics of 10 x 20 logical px at [devicePixelRatio].
VtCellMetrics testMetrics({double devicePixelRatio = 1}) =>
    VtCellMetrics.aligned(
      advance: 10,
      ascent: 15,
      descent: 5,
      devicePixelRatio: devicePixelRatio,
    );

/// The widget tree of every test: [TerminalPointerScope] and, above it in
/// a `Stack`, a [TerminalScrollbar], both over [seams], sized to
/// [geometry].
Widget pointerScopeUnderTest(
  ControllerSeams seams,
  TerminalGeometry geometry, {
  bool rawAlternateScroll = true,
  TerminalTapUpCallback? onTapUp,
  TerminalTapDownCallback? onSecondaryTapDown,
  TerminalTapUpCallback? onSecondaryTapUp,
  ValueChanged<PointerDownEvent>? onPointerDown,
  MouseCursor? mouseCursor,
  Duration fadeDelay = kTerminalScrollbarTimeToFade,
}) => SizedBox.fromSize(
  size: geometry.viewSize,
  child: Stack(
    children: [
      TerminalPointerScope(
        pointer: seams,
        viewport: seams,
        keys: seams,
        text: rawAlternateScroll ? seams : null,
        geometry: geometry,
        onTapUp: onTapUp,
        onSecondaryTapDown: onSecondaryTapDown,
        onSecondaryTapUp: onSecondaryTapUp,
        onPointerDown: onPointerDown,
        mouseCursor: mouseCursor,
        child: const SizedBox.expand(),
      ),
      TerminalScrollbar(
        viewport: seams,
        pointer: seams,
        keys: seams,
        text: seams,
        geometry: geometry,
        fadeDelay: fadeDelay,
      ),
    ],
  ),
);

/// Wraps [child] in the text direction and a top-left alignment.
Widget testApp(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(alignment: Alignment.topLeft, child: child),
);

/// A controller of [cols] x [rows] whose output the returned harness
/// collects, with seams and a geometry; nothing is pumped.
PointerHarness createHarness({
  int cols = 20,
  int rows = 5,
  double devicePixelRatio = 1,
  EdgeInsets padding = EdgeInsets.zero,
}) {
  late PointerHarness harness;
  final controller = VtTerminalController(
    cols: cols,
    rows: rows,
    onOutput: (bytes) => harness._output.addAll(bytes),
  );
  addTearDown(controller.dispose);
  final geometry = TerminalGeometry(
    metrics: testMetrics(devicePixelRatio: devicePixelRatio),
    cols: cols,
    rows: rows,
    padding: padding,
  );
  return harness = PointerHarness._(
    controller,
    ControllerSeams(controller),
    geometry,
  );
}

/// Pumps [pointerScopeUnderTest] for a new [cols] x [rows] controller.
/// [wrap] puts the view inside another widget (a `ListView`, a
/// `PageView`).
Future<PointerHarness> pumpPointerScope(
  WidgetTester tester, {
  int cols = 20,
  int rows = 5,
  double devicePixelRatio = 1,
  EdgeInsets padding = EdgeInsets.zero,
  bool rawAlternateScroll = true,
  TerminalTapUpCallback? onTapUp,
  TerminalTapDownCallback? onSecondaryTapDown,
  TerminalTapUpCallback? onSecondaryTapUp,
  ValueChanged<PointerDownEvent>? onPointerDown,
  MouseCursor? mouseCursor,
  Duration fadeDelay = kTerminalScrollbarTimeToFade,
  Widget Function(Widget view)? wrap,
}) async {
  final harness = createHarness(
    cols: cols,
    rows: rows,
    devicePixelRatio: devicePixelRatio,
    padding: padding,
  );
  final view = pointerScopeUnderTest(
    harness.seams,
    harness.geometry,
    rawAlternateScroll: rawAlternateScroll,
    onTapUp: onTapUp,
    onSecondaryTapDown: onSecondaryTapDown,
    onSecondaryTapUp: onSecondaryTapUp,
    onPointerDown: onPointerDown,
    mouseCursor: mouseCursor,
    fadeDelay: fadeDelay,
  );
  await tester.pumpWidget(testApp(wrap == null ? view : wrap(view)));
  return harness;
}

/// Writes [count] numbered lines (`line 0` ...), leaving the cursor on an
/// empty last line.
void writeLines(VtTerminalController controller, int count, {int from = 0}) {
  final text = StringBuffer();
  for (var i = from; i < from + count; i++) {
    text.write('line $i\r\n');
  }
  controller.write(text.toString());
}

/// Sends a mouse wheel event of [delta] at [at].
Future<void> sendWheel(WidgetTester tester, Offset at, Offset delta) async {
  final pointer = TestPointer(77, PointerDeviceKind.mouse)..hover(at);
  await tester.sendEventToBinding(pointer.scroll(delta));
}
