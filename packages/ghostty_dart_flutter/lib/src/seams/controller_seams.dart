import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../controller/controller_internals.dart';
import '../controller/terminal_controller.dart';
import '../theme/terminal_theme.dart';
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

  /// The shortest time from a paint, or from the last notification, to
  /// the next notification while output floods the view, during the
  /// first [sustainedFloodAfter] of a flood: 25 ms (ADR 0011, amendments
  /// of 2026-11-12). The frame that notification schedules starts at the
  /// next vsync, so a flood is painted about 30 times a second on 60 and
  /// 120 Hz displays (every second or fourth vsync) and 36 on 144 Hz.
  ///
  /// In a flood every frame draws a whole new screen, and every listener
  /// that schedules a frame (the scrollbar follows the growing
  /// scrollback, the pointer and IME layers follow the cursor) would make
  /// the view paint at the display's refresh rate for text nobody can
  /// read. Changes after a pause, and output that does not replace every
  /// row (full-screen programs, slower scrolling), are delivered at once
  /// as before.
  static const floodInterval = Duration(milliseconds: 25);

  /// How long a flood lasts before [sustainedFloodInterval] replaces
  /// [floodInterval]: 1 second. Bursts shorter than that (a long `ls`, a
  /// build log) keep the smoother rate.
  static const sustainedFloodAfter = Duration(seconds: 1);

  /// [floodInterval] once a flood has lasted [sustainedFloodAfter]: 60 ms,
  /// about 15 frames a second at 60, 120 and 144 Hz (every fourth, eighth
  /// or ninth vsync).
  ///
  /// Each frame costs a fixed amount on the UI thread besides the view's
  /// own work: on Linux the embedder presents it through GTK on that same
  /// thread, and that took several times the view's ~1–2 ms per frame in
  /// the firehose benchmark (ADR 0011, amendment of 2026-11-12, frame
  /// cost). Text that scrolls a screen per frame for seconds is unreadable
  /// at any rate, so a sustained flood shows its progress at a lower one.
  static const sustainedFloodInterval = Duration(milliseconds: 60);

  /// The monotonic clock the flood interval is measured with: the time
  /// since an arbitrary fixed point, never going back.
  ///
  /// Defaults to a process-wide [Stopwatch]. Tests replace it with the
  /// test's fake clock, so the interval advances only with `tester.pump`
  /// and never depends on how fast the machine runs the test.
  @visibleForTesting
  static Duration Function() debugNow = _monotonicNow;

  static final _monotonic = Stopwatch()..start();
  static Duration _monotonicNow() => _monotonic.elapsed;

  final _listeners = <VoidCallback>[];
  bool _listening = false;
  bool _flooded = false;

  /// When the current flood started (the first paint that reported one,
  /// on [debugNow]'s clock); null while not flooded.
  Duration? _floodStart;

  /// When the last paint or the last notification happened, whichever
  /// came later (on [debugNow]'s clock): while flooded, notifications are
  /// at least [floodInterval] (or [sustainedFloodInterval]) apart from
  /// both. Counting from the notification too matters when frames are
  /// slower than the interval (a large window, a slow GPU, a software
  /// renderer): without it every write between the notification and the
  /// paint it scheduled would notify again (one round of listeners per
  /// pty read, thousands a second) for frames that were already coming.
  Duration _lastEvent = Duration.zero;
  Timer? _floodTimer;

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
      _cancelFloodTimer();
    }
  }

  @override
  void painted({required bool flooded}) {
    final now = debugNow();
    _flooded = flooded;
    _floodStart = flooded ? (_floodStart ?? now) : null;
    _cancelFloodTimer();
    _lastEvent = now;
  }

  void _onControllerChanged() {
    if (_flooded) {
      if (_floodTimer != null) return;
      final now = debugNow();
      final wait = _intervalAt(now) - (now - _lastEvent);
      if (wait > Duration.zero) {
        _floodTimer = Timer(wait, _onFloodTimer);
        return;
      }
    }
    _notifyListeners();
  }

  Duration _intervalAt(Duration now) =>
      now - (_floodStart ?? now) >= sustainedFloodAfter
      ? sustainedFloodInterval
      : floodInterval;

  void _onFloodTimer() {
    _floodTimer = null;
    _notifyListeners();
  }

  void _cancelFloodTimer() {
    _floodTimer?.cancel();
    _floodTimer = null;
  }

  /// Whether a delayed notification is pending (tests).
  @visibleForTesting
  bool get debugNotificationPending => _floodTimer != null;

  // As ChangeNotifier does: a listener removed by an earlier one is not
  // called, and an error in one is reported without skipping the others.
  void _notifyListeners() {
    _lastEvent = debugNow();
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
    _cancelFloodTimer();
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
