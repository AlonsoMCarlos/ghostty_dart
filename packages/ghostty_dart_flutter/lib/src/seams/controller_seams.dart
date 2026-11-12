import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../controller/controller_internals.dart';
import '../controller/terminal_controller.dart';
import '../theme/terminal_theme.dart';
import '../view/flood_pacing.dart';
import 'terminal_geometry.dart';
import 'terminal_seams.dart';

/// Implements every seam on top of one [VtTerminalController]. The view
/// creates one per controller and hands it to the renderer, the input
/// layers and the scrollbar. Never exported.
///
/// After the controller is disposed, the sinks are no-ops (see the
/// library docs of `terminal_seams.dart`).
final class ControllerSeams
    implements
        TerminalFrameSource,
        TerminalKeySink,
        TerminalTextSink,
        TerminalViewport,
        TerminalPointerSink {
  /// Seams for [controller], which must not be disposed.
  ControllerSeams(this.controller) : _internals = internalsOf(controller) {
    _internals.usedByWidgets = true;
  }

  /// The controller every seam delegates to.
  final VtTerminalController controller;
  final ControllerInternals _internals;

  @override
  bool get isDisposed => controller.isDisposed;

  // Listenable (frame source, text sink and viewport).
  //
  // The seams listen to the controller once and notify their own
  // listeners (the renderer, the scrollbar, the pointer and text input
  // layers), so a flood can delay all of them together (see [painted]).

  /// How often the view paints while output floods it; the view sets it
  /// from `VtTerminalView.floodPacing` on every build.
  ///
  /// In a flood every frame draws a whole new screen, and every listener
  /// that schedules a frame (the scrollbar follows the growing
  /// scrollback, the pointer and IME layers follow the cursor) would make
  /// the view paint at the display's refresh rate for text nobody can
  /// read; on Linux each of those frames also costs the UI thread the
  /// embedder's present (ADR 0011, amendments of 2026-11-12). Changes
  /// after a pause, and output that does not replace every row
  /// (full-screen programs, slower scrolling), are delivered at once as
  /// before.
  VtFloodPacing floodPacing = VtFloodPacing.smooth;

  /// The display's refresh rate in Hz (`FlutterView.display.refreshRate`);
  /// the view sets it on every build. Values the platform reports as
  /// unknown (0) or implausible count as 60 Hz ([vsyncPeriod]).
  double refreshRate = 60;

  /// The time between two vsyncs at [refreshRate] Hz: 60 Hz when the
  /// rate is unknown (Flutter reports 0) or below 24 Hz, at most 1000 Hz.
  static Duration vsyncPeriod(double refreshRate) {
    final hz = refreshRate.isFinite && refreshRate >= 24
        ? math.min(refreshRate, 1000.0)
        : 60.0;
    return Duration(microseconds: (1e6 / hz).round());
  }

  /// How many vsyncs a flood frame waits after the previous frame under
  /// [pacing] on a display of [refreshRate] Hz: the refresh rate divided
  /// by [VtFloodPacing.maxFramesPerSecond], rounded, at least one. For
  /// [VtFloodPacing.smooth] and [VtFloodPacing.balanced]: 1 and 2 at
  /// 60 Hz, 2 and 4 at 120 Hz, 2 and 5 at 144 Hz.
  static int floodVsyncs(VtFloodPacing pacing, double refreshRate) {
    final hz = 1e6 / vsyncPeriod(refreshRate).inMicroseconds;
    return math.max(1, (hz / pacing.maxFramesPerSecond).round());
  }

  /// The time between flood frames under [pacing] at [refreshRate] Hz:
  /// [floodVsyncs] vsync periods.
  static Duration floodFrameInterval(
    VtFloodPacing pacing,
    double refreshRate,
  ) => vsyncPeriod(refreshRate) * floodVsyncs(pacing, refreshRate);

  /// The monotonic clock flood frames are scheduled on: microseconds on
  /// Dart's timeline clock ([Timeline.now]), which is the clock of the
  /// engine's vsync timestamps (`fml::TimePoint` takes its time from
  /// Dart's timeline since the engine starts the VM,
  /// `runtime/dart_vm_initializer.cc`, Flutter 3.47.9).
  ///
  /// Tests replace it with the test's fake clock, which is also the clock
  /// of the frames `tester.pump` draws, so the pacing advances only with
  /// `tester.pump` and never depends on how fast the machine runs.
  @visibleForTesting
  static Duration Function() debugNow = _monotonicNow;

  static Duration _monotonicNow() => Duration(microseconds: Timeline.now);

  final _listeners = <VoidCallback>[];
  bool _listening = false;
  bool _flooded = false;

  /// The vsync time of the last frame that painted the view or received
  /// a flood notification, on [debugNow]'s clock; null until the first
  /// flooded paint. Flood frames are counted in vsyncs from it, so a
  /// notification that waits for a slow frame never schedules another
  /// one before that frame's interval has passed.
  Duration? _lastFrame;

  /// Wakes up within the vsync period before the next flood frame is due
  /// and requests that frame ([_floodFrame]).
  Timer? _floodTimer;

  /// The frame callback that delivers a flood notification, if requested.
  int? _floodFrame;

  @override
  void addListener(VoidCallback listener) {
    if (isDisposed) return;
    _listeners.add(listener);
    if (!_listening) {
      _listening = true;
      controller.addListener(_onControllerChanged);
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    // Allowed after dispose.
    _listeners.remove(listener);
    if (_listeners.isEmpty && _listening) {
      _listening = false;
      controller.removeListener(_onControllerChanged);
      _cancelFlood();
    }
  }

  @override
  void painted({required bool flooded}) {
    _flooded = flooded;
    _cancelFlood();
    if (flooded) _lastFrame = _frameTime();
  }

  void _onControllerChanged() {
    if (!_flooded) {
      _notifyListeners();
      return;
    }
    if (debugNotificationPending) return;
    final last = _lastFrame;
    final now = debugNow();
    // Asking for a frame at any time during the vsync period before the
    // due vsync gets exactly that vsync, so the timer wakes up early in
    // that period and may run late by most of it (the UI thread may be
    // busy) without missing it. The margin (an eighth of a period, at
    // least 1 ms) keeps the request after the previous vsync if the
    // refresh rate or the frame's timestamp is slightly off; the wait is
    // rounded up because Dart timers count whole milliseconds.
    final period = vsyncPeriod(refreshRate);
    final margin = period ~/ 8 > _minMargin ? period ~/ 8 : _minMargin;
    final wait = last == null
        ? Duration.zero
        : last +
              period * (floodVsyncs(floodPacing, refreshRate) - 1) +
              margin -
              now;
    if (wait <= Duration.zero) {
      _requestFloodFrame();
    } else {
      _floodTimer = Timer(
        Duration(milliseconds: (wait.inMicroseconds + 999) ~/ 1000),
        _onFloodTimer,
      );
    }
  }

  static const _minMargin = Duration(milliseconds: 1);

  void _onFloodTimer() {
    _floodTimer = null;
    _requestFloodFrame();
  }

  void _requestFloodFrame() {
    _floodFrame = SchedulerBinding.instance.scheduleFrameCallback(
      _onFloodFrameStart,
    );
  }

  // At the start of the frame, before it builds, lays out and paints:
  // every listener's change lands in this frame.
  void _onFloodFrameStart(Duration _) {
    _floodFrame = null;
    _lastFrame = _frameTime();
    _notifyListeners();
  }

  /// The vsync time of the frame being drawn on [debugNow]'s clock, or
  /// now outside a frame (and if the scheduler's timestamp is not on that
  /// clock, which the sanity check catches).
  Duration _frameTime() {
    final now = debugNow();
    final scheduler = SchedulerBinding.instance;
    switch (scheduler.schedulerPhase) {
      case SchedulerPhase.idle || SchedulerPhase.postFrameCallbacks:
        return now;
      case SchedulerPhase.transientCallbacks ||
          SchedulerPhase.midFrameMicrotasks ||
          SchedulerPhase.persistentCallbacks:
        final vsync = scheduler.currentSystemFrameTimeStamp;
        final age = now - vsync;
        return age.isNegative || age > const Duration(seconds: 1) ? now : vsync;
    }
  }

  void _cancelFlood() {
    _floodTimer?.cancel();
    _floodTimer = null;
    final frame = _floodFrame;
    if (frame != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
      _floodFrame = null;
    }
  }

  /// Whether a delayed notification is pending (tests).
  @visibleForTesting
  bool get debugNotificationPending =>
      _floodTimer != null || _floodFrame != null;

  // As ChangeNotifier does: a listener removed by an earlier one is not
  // called, and an error in one is reported without skipping the others.
  void _notifyListeners() {
    for (final listener in List.of(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      try {
        listener();
      } catch (exception, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: exception,
            stack: stack,
            library: 'ghostty_dart_flutter',
            context: ErrorDescription(
              'while notifying the listeners of a VtTerminalView',
            ),
          ),
        );
      }
    }
  }

  // Layout (the view)

  /// Resizes the terminal to [geometry] from the view's layout: the
  /// terminal changes at once, while `onResize` and the listener
  /// notification run after the frame, where listeners may rebuild.
  void resizeDuringLayout(TerminalGeometry geometry) {
    if (isDisposed) return;
    _internals.resizeDuringLayout(
      geometry.cols,
      geometry.rows,
      cellWidthPx: geometry.metrics.widthPx,
      cellHeightPx: geometry.metrics.heightPx,
    );
  }

  /// Gives up reading frames, so another seams object (a new view of the
  /// same controller) may. The view calls it when it leaves the tree
  /// (deactivate) and when it is disposed; its next paint, if any, takes
  /// ownership again.
  void release() {
    _cancelFlood();
    if (!isDisposed && identical(_internals.frameOwner, this)) {
      _internals.frameOwner = null;
    }
  }

  // TerminalFrameSource

  @override
  VtTerminalTheme get theme => controller.theme;

  @override
  bool get isRenderHeld => !isDisposed && _internals.isRenderHeld;

  @override
  RenderState updateFrame() {
    final internals = internalsOf(controller);
    assert(
      internals.frameOwner == null || identical(internals.frameOwner, this),
      'Two views read frames from one VtTerminalController; a controller '
      'drives at most one VtTerminalView at a time.',
    );
    internals.frameOwner = this;
    return internals.renderState..update(controller.terminal);
  }

  @override
  void endFrame() => internalsOf(controller).renderState.markClean();

  @override
  List<ViewportHighlight> viewportHighlights() {
    if (isDisposed) return const [];
    final highlights = _internals.screenHighlights();
    if (highlights.isEmpty) return const [];
    final vt = controller.terminal;
    // The viewport's top row in screen coordinates (as in
    // cursorViewportCell: the scrollbar counts screen rows).
    final top = vt.scrollbar.offset;
    final rows = vt.rows;
    return [
      for (final (:color, :start, :end) in highlights)
        if (end.y >= top && start.y < top + rows)
          (
            color: color,
            startX: start.x,
            startY: start.y - top,
            endX: end.x,
            endY: end.y - top,
          ),
    ];
  }

  // TerminalKeySink

  @override
  bool sendKey(VtKeyEvent event) => !isDisposed && controller.sendKey(event);

  @override
  ValueNotifier<KeyModifiers> get latchedModifiers =>
      _internals.latchedModifiers;

  // TerminalTextSink

  @override
  void sendText(String text) {
    if (!isDisposed) controller.sendText(text);
  }

  @override
  PasteResult paste(String text, {bool allowUnsafe = false}) => isDisposed
      ? PasteResult.nothingToPaste
      : controller.paste(text, allowUnsafe: allowUnsafe);

  @override
  void sendFocus({required bool focused}) {
    if (!isDisposed) controller.sendFocus(focused: focused);
  }

  @override
  String? get selectedText => isDisposed ? null : controller.selectedText;

  @override
  GridPoint? get cursorViewportCell {
    if (isDisposed) return null;
    final vt = controller.terminal;
    final scrollbar = vt.scrollbar;
    // The active area is the last `rows` rows of the scrollable area; the
    // viewport starts `offset` rows from its top.
    final y = vt.cursorY + (scrollbar.total - vt.rows) - scrollbar.offset;
    if (y < 0 || y >= vt.rows) return null;
    return GridPoint.viewport(vt.cursorX, y);
  }

  @override
  bool get isPasswordInput =>
      !isDisposed && _internals.renderState.cursor.isPasswordInput;

  // TerminalViewport

  @override
  ViewportScrollbar get scrollbar => isDisposed
      ? const ViewportScrollbar(total: 0, offset: 0, length: 0)
      : controller.scrollbar;

  @override
  void scrollViewport(ViewportScroll target) {
    if (!isDisposed) controller.scrollViewport(target);
  }

  @override
  bool get isAlternateScreen => !isDisposed && controller.isAlternateScreen;

  // TerminalPointerSink

  @override
  bool get isMouseTracking => !isDisposed && controller.isMouseTracking;

  @override
  bool isModeEnabled(TerminalMode mode) =>
      !isDisposed && controller.isModeEnabled(mode);

  @override
  MouseShape get mouseShape =>
      isDisposed ? MouseShape.defaultShape : controller.mouseShape;

  @override
  void setMouseGeometry(MouseEncoderSize size) {
    if (!isDisposed) _internals.mouseEncoder.configure(size: size);
  }

  @override
  void setMouseButtonsPressed({required bool anyPressed}) {
    if (!isDisposed) {
      _internals.mouseEncoder.configure(anyButtonPressed: anyPressed);
    }
  }

  @override
  bool sendMouse(VtMouseEvent event) =>
      !isDisposed && controller.sendMouse(event);

  @override
  VtTerminal get terminal {
    if (isDisposed) {
      throw StateError('VtTerminalController has been disposed');
    }
    return controller.terminal;
  }

  @override
  VtSelection? get selection => isDisposed ? null : controller.selection;

  @override
  set selection(VtSelection? value) {
    if (!isDisposed) controller.selection = value;
  }
}
