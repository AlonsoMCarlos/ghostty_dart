// Shared set-up for the tests of the whole VtTerminalView: a real
// controller in a test window of known size. The grid font is the test
// framework's own (every glyph one em wide; ascent 0.75 em, descent 0.25
// em), so 10 px text gives 10 x 10 px cells.

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/render/terminal_render.dart';

/// 10 x 10 px cells in the test font.
const viewStyle = TextStyle(fontFamily: 'FlutterTest', fontSize: 10);

/// A mounted view over a real controller.
final class ViewHarness {
  ViewHarness._(this.tester, this.controller);

  /// The tester that pumped the view.
  final WidgetTester tester;

  /// The controller (disposed in tear-down unless a test did).
  final VtTerminalController controller;

  final _output = <int>[];

  /// Every `onResize` call: (cols, rows, pixelWidth, pixelHeight).
  final resizes = <(int, int, int, int)>[];

  /// The scheduler phase of every `onResize` call.
  final resizePhases = <SchedulerPhase>[];

  /// The key of the view.
  final viewKey = GlobalKey<VtTerminalViewState>();

  /// Everything sent to `onOutput` since the last call, as Latin-1.
  String takeOutput() {
    final text = latin1.decode(_output);
    _output.clear();
    return text;
  }

  /// The renderer.
  RenderTerminal get render =>
      tester.renderObject<RenderTerminal>(find.byType(TerminalRenderWidget));

  /// The centre of the viewport cell [col], [row] (no padding, view at
  /// the top-left of the window).
  Offset cell(int col, int row) => Offset(col * 10 + 5, row * 10 + 5);

  /// Pumps [view] (built with [viewKey] and [controller]) as the app.
  Future<void> pumpView(VtTerminalView view) =>
      tester.pumpWidget(wrapView(view));
}

/// The app around a view: a text direction, and the whole window (the
/// device pixel ratio comes from the test window's `View`).
Widget wrapView(Widget view) => Directionality(
  textDirection: TextDirection.ltr,
  child: SizedBox.expand(child: view),
);

/// Sets the test window to [width] x [height] logical px at [dpr], and
/// resets it after the test.
void setWindow(
  WidgetTester tester, {
  double width = 200,
  double height = 100,
  double dpr = 1,
}) {
  tester.view
    ..devicePixelRatio = dpr
    ..physicalSize = Size(width * dpr, height * dpr);
  addTearDown(tester.view.reset);
}

/// A controller whose output and resizes [ViewHarness] records, and a
/// harness for it; nothing is pumped.
ViewHarness createViewHarness(WidgetTester tester, {int cols = 80}) {
  late ViewHarness harness;
  final controller = VtTerminalController(
    cols: cols,
    onOutput: (bytes) => harness._output.addAll(bytes),
    onResize: (cols, rows, w, h) {
      harness.resizes.add((cols, rows, w, h));
      harness.resizePhases.add(SchedulerBinding.instance.schedulerPhase);
    },
  );
  addTearDown(controller.dispose);
  return harness = ViewHarness._(tester, controller);
}

/// Pumps a [VtTerminalView] in a 200 x 100 window (20 x 10 cells).
Future<ViewHarness> pumpTerminalView(
  WidgetTester tester, {
  bool autofocus = true,
  bool readOnly = false,
  bool hardwareKeyboardOnly = false,
  bool announceOutput = false,
  EdgeInsets padding = EdgeInsets.zero,
  double dpr = 1,
}) async {
  setWindow(tester, dpr: dpr);
  final h = createViewHarness(tester);
  await h.pumpView(
    VtTerminalView(
      key: h.viewKey,
      controller: h.controller,
      textStyle: viewStyle,
      autofocus: autofocus,
      readOnly: readOnly,
      hardwareKeyboardOnly: hardwareKeyboardOnly,
      announceOutput: announceOutput,
      padding: padding,
    ),
  );
  return h;
}

/// Presses and releases [key].
Future<void> tapKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  String? character,
}) async {
  await tester.sendKeyDownEvent(key, character: character);
  await tester.sendKeyUpEvent(key);
}

/// Sends a mouse wheel event of [delta] at [at], stamped [timeStamp].
Future<void> sendWheel(
  WidgetTester tester,
  Offset at,
  Offset delta, {
  Duration timeStamp = Duration.zero,
}) async {
  final pointer = TestPointer(77, PointerDeviceKind.mouse)..hover(at);
  await tester.sendEventToBinding(pointer.scroll(delta, timeStamp: timeStamp));
  await tester.pump();
}

/// Writes [count] numbered lines, leaving the cursor on an empty line.
void writeLines(VtTerminalController controller, int count) {
  final text = StringBuffer();
  for (var i = 0; i < count; i++) {
    text.write('line $i\r\n');
  }
  controller.write(text.toString());
}
