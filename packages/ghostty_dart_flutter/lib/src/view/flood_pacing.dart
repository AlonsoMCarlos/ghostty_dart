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
///   floodPacing: VtFloodPacing.smooth, // Kitty-like, at more CPU
/// )
/// ```
enum VtFloodPacing {
  /// At most about 60 frames a second: every vsync at 60 Hz, every second
  /// one at 120 and 144 Hz. The smoothest scroll, at about twice the
  /// frame cost of [balanced] during a flood.
  smooth(60),

  /// The default: at most about 30 frames a second, every second vsync at
  /// 60 Hz and every fourth at 120 Hz. An even cadence at about half the
  /// frame cost of [smooth].
  balanced(30),

  /// At most about 20 frames a second, every third vsync at 60 Hz: the
  /// least CPU while a flood lasts, for battery-powered devices or many
  /// views flooding at once.
  ///
  /// Not lower on purpose: when no frame is scheduled for 51 ms, Flutter's
  /// engine tells the Dart VM that the UI thread is idle for the next
  /// 100 ms (`kNotifyIdleTaskWaitTime`, `shell/common/animator.cc`,
  /// Flutter 3.47.9), and work the VM does in that window (garbage
  /// collection) can delay the next frame. In the firehose benchmark
  /// (2026-11-12) every fourth vsync at 60 Hz gave gaps of 90–160 ms
  /// instead of 67; every third vsync asks for its frame before that
  /// deadline.
  efficient(20);

  const VtFloodPacing(this.maxFramesPerSecond);

  /// The highest frame rate while output floods the view. The actual rate
  /// is the display's refresh rate divided by a whole number of vsyncs, so
  /// it can be a little higher or lower (72 frames a second for [smooth]
  /// on a 144 Hz display).
  final int maxFramesPerSecond;
}
