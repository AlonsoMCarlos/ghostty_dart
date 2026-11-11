// Shared setup for the renderer tests: a real controller, its seams and a
// TerminalRenderWidget sized to the grid.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/render/terminal_render.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_geometry.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_seams.dart';

import '../support/fonts.dart';

/// The grid font of the renderer tests (JetBrains Mono when bundled; the
/// test framework's fallback font otherwise).
const gridStyle = TextStyle(fontFamily: jetBrainsMonoFamily, fontSize: 13);

/// The key of the [RepaintBoundary] around the renderer (for goldens).
const terminalKey = ValueKey('terminal');

/// A mounted renderer and what drives it.
final class RenderHarness {
  RenderHarness._(
    this.tester,
    this.controller,
    this.seams,
    this.geometry,
    this.cacheBudget,
    this.textRendering,
  );

  /// The text path the renderer is pumped with (changed by [rebuild]).
  VtTextRendering textRendering;

  /// The renderer's cache budget (`TerminalRenderWidget.cacheBudget`).
  final int cacheBudget;

  /// The tester that pumped it.
  final WidgetTester tester;

  /// The controller; disposed by a tear-down unless the test did.
  final VtTerminalController controller;

  /// Seams over [controller].
  final ControllerSeams seams;

  /// The geometry the renderer was pumped with.
  TerminalGeometry geometry;

  /// The render object.
  RenderTerminal get render =>
      tester.renderObject<RenderTerminal>(find.byType(TerminalRenderWidget));

  /// Writes [data] and pumps one frame.
  Future<void> write(String data) async {
    controller.write(data);
    await tester.pump();
  }

  /// Resizes the terminal to [cols] × [rows] and the renderer with it.
  Future<void> resize(int cols, int rows) async {
    controller.resize(cols, rows);
    await rebuild(
      geometry: TerminalGeometry(
        metrics: geometry.metrics,
        cols: cols,
        rows: rows,
        padding: geometry.padding,
      ),
    );
  }

  /// The renderer's pixels (RGBA, at the device pixel ratio).
  Future<Uint8List> pixels() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(terminalKey),
    );
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(
        pixelRatio: geometry.devicePixelRatio,
      );
      try {
        return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
      }
    });
    return bytes!.buffer.asUint8List();
  }

  /// Rebuilds the renderer with new parameters; [wrap] puts widgets
  /// around it (e.g. `TickerMode`, `Offstage`).
  Future<void> rebuild({
    TerminalFrameSource? source,
    TextStyle textStyle = gridStyle,
    TextScaler textScaler = TextScaler.noScaling,
    bool focused = true,
    bool hideCursor = false,
    VtCursorStyle? cursorStyle,
    bool alwaysShowCursor = false,
    double backgroundOpacity = 1,
    TerminalGeometry? geometry,
    VtTextRendering? textRendering,
    Widget Function(Widget child)? wrap,
  }) async {
    if (geometry != null) this.geometry = geometry;
    if (textRendering != null) this.textRendering = textRendering;
    final view = _view(
      source ?? seams,
      this.geometry,
      textStyle: textStyle,
      textScaler: textScaler,
      focused: focused,
      hideCursor: hideCursor,
      cursorStyle: cursorStyle,
      alwaysShowCursor: alwaysShowCursor,
      backgroundOpacity: backgroundOpacity,
      cacheBudget: cacheBudget,
      textRendering: this.textRendering,
    );
    await tester.pumpWidget(wrap == null ? view : wrap(view));
  }
}

Widget _view(
  TerminalFrameSource source,
  TerminalGeometry geometry, {
  required TextStyle textStyle,
  required TextScaler textScaler,
  required bool focused,
  required bool hideCursor,
  required VtCursorStyle? cursorStyle,
  required bool alwaysShowCursor,
  required double backgroundOpacity,
  required int cacheBudget,
  required VtTextRendering textRendering,
}) => Align(
  alignment: Alignment.topLeft,
  child: RepaintBoundary(
    key: terminalKey,
    child: SizedBox.fromSize(
      size: geometry.viewSize,
      child: TerminalRenderWidget(
        source: source,
        geometry: geometry,
        textStyle: textStyle,
        textScaler: textScaler,
        focused: focused,
        hideCursor: hideCursor,
        cursorStyle: cursorStyle,
        alwaysShowCursor: alwaysShowCursor,
        backgroundOpacity: backgroundOpacity,
        cacheBudget: cacheBudget,
        textRendering: textRendering,
      ),
    ),
  ),
);

/// Pumps a [cols] × [rows] renderer at [devicePixelRatio] and writes
/// [initial] first.
Future<RenderHarness> pumpRenderer(
  WidgetTester tester, {
  int cols = 20,
  int rows = 5,
  double devicePixelRatio = 1,
  TextStyle textStyle = gridStyle,
  EdgeInsets padding = EdgeInsets.zero,
  bool focused = true,
  String initial = '',
  VtTerminalTheme theme = VtTerminalTheme.defaultTheme,
  int cacheBudget = RenderTerminal.defaultCacheBudget,
  VtTextRendering textRendering = VtTextRendering.atlas,
}) async {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = const Size(8000, 4000);
  addTearDown(tester.view.reset);
  final controller = VtTerminalController(cols: cols, rows: rows, theme: theme);
  addTearDown(controller.dispose);
  if (initial.isNotEmpty) controller.write(initial);
  final seams = ControllerSeams(controller);
  final metrics = VtCellMetrics.measure(
    textStyle,
    devicePixelRatio: devicePixelRatio,
  );
  final geometry = TerminalGeometry(
    metrics: metrics,
    cols: cols,
    rows: rows,
    padding: padding,
  );
  final harness = RenderHarness._(
    tester,
    controller,
    seams,
    geometry,
    cacheBudget,
    textRendering,
  );
  await harness.rebuild(textStyle: textStyle, focused: focused);
  return harness;
}
