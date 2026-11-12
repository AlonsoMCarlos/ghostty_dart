// VtTerminalView.floodPacing (ADR 0011, amendment of 2026-11-12,
// vsync-aligned flood pacing): the view hands the policy and its
// display's refresh rate to its seams, and a flood paints on that many
// vsyncs.

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';

import 'view_harness.dart';

void main() {
  // Lines that scroll the whole 10-row grid past: every visible row is
  // new.
  String screenful(int frame) =>
      [for (var i = 0; i < 20; i++) '\r\nframe $frame line $i'].join();

  /// The vsyncs (0-based) at which a flood written once per vsync was
  /// painted, after the two frames that detect it.
  Future<List<int>> floodFrames(
    WidgetTester tester,
    ViewHarness h,
    double hz,
    int vsyncs,
  ) async {
    final period = ControllerSeams.vsyncPeriod(hz);
    final painted = <int>[];
    for (var vsync = 0; vsync < 10 * vsyncs; vsync++) {
      final scans = h.render.debugRowScans;
      h.controller.write(screenful(vsync));
      await tester.pump(period);
      if (h.render.debugRowScans != scans) painted.add(vsync);
    }
    return painted.skip(2).toList();
  }

  void expectEvery(List<int> frames, int vsyncs) {
    expect(frames.length, greaterThanOrEqualTo(6));
    for (var i = 1; i < frames.length; i++) {
      expect(frames[i] - frames[i - 1], vsyncs, reason: 'frames $frames');
    }
  }

  testWidgets('defaults to balanced at the display refresh rate', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final h = await pumpTerminalView(tester, autofocus: false);
    expectEvery(await floodFrames(tester, h, 120, 4), 4);
  });

  testWidgets('floodPacing picks the vsyncs per flood frame and can change', (
    tester,
  ) async {
    tester.view.display.refreshRate = 60;
    addTearDown(tester.view.display.resetRefreshRate);
    setWindow(tester);
    final h = createViewHarness(tester);
    Future<void> pump(VtFloodPacing pacing) => h.pumpView(
      VtTerminalView(
        key: h.viewKey,
        controller: h.controller,
        textStyle: viewStyle,
        floodPacing: pacing,
      ),
    );
    await pump(VtFloodPacing.efficient);
    expectEvery(await floodFrames(tester, h, 60, 3), 3);
    await pump(VtFloodPacing.smooth);
    expectEvery(await floodFrames(tester, h, 60, 1), 1);
  });
}
