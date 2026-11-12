/// How often a `VtTerminalView` paints while output floods it (ADR 0011,
/// amendment of 2026-11-12, vsync-aligned flood pacing).
///
/// Output floods the view when every visible row is new in each of the
/// last two frames: a program such as `tree` or `cat` of a large log
/// scrolls a screen or more per frame, faster than anyone can read. Each
/// frame then draws a whole new screen, and on most desktop platforms each
/// frame also costs the UI thread a fixed amount to present, so painting
/// at the display's refresh rate spends CPU on text that only shows the
/// output's progress.
///
/// While output floods the view, the view paints on a fixed whole number
/// of display refreshes (vsyncs) after the previous paint, so frames are
/// evenly spaced: the policy sets the highest frame rate, and the number
/// of vsyncs per frame is the display's refresh rate
/// (`FlutterView.display.refreshRate`, 60 Hz when the platform does not
/// report one) divided by it, rounded. Every other change (typing, a
/// full-screen program redrawing in place, output that scrolls less than a
/// screen per frame, and the first change after a pause) paints at the
/// next vsync, whatever the policy.
///
/// ```dart
/// VtTerminalView(
///   controller: controller,
///   floodPacing: VtFloodPacing.balanced, // half the frames, less CPU
/// )
/// ```
enum VtFloodPacing {
  /// The default: at most about 60 frames a second, every vsync at 60 Hz
  /// and every second one at 120 and 144 Hz. The smoothest scroll, at
  /// about 1.5 times the CPU per megabyte of [balanced] during a flood.
  smooth(60),

  /// At most about 30 frames a second, every second vsync at 60 Hz and
  /// every fourth at 120 Hz: an even cadence at less CPU than [smooth],
  /// for battery-powered devices or many views flooding at once.
  ///
  /// There is no slower policy on purpose: on a real GPU (2026-11-12),
  /// painting every third vsync at 60 Hz missed about every third due
  /// vsync, so its frame gaps alternated between 50 and 67 ms, which reads
  /// as jumps rather than as a slower scroll.
  balanced(30);

  const VtFloodPacing(this.maxFramesPerSecond);

  /// The highest frame rate while output floods the view. The actual rate
  /// is the display's refresh rate divided by a whole number of vsyncs, so
  /// it can be a little higher or lower (72 frames a second for [smooth]
  /// on a 144 Hz display).
  final int maxFramesPerSecond;
}
