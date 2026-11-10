import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../../scroll/row_accumulator.dart';
import '../../scroll/terminal_scroll_router.dart';
import '../../seams/terminal_geometry.dart';
import '../../seams/terminal_seams.dart';
import 'pointer_mapping.dart';

/// Called with the details of a primary tap or a secondary release and the
/// viewport cell under it (see [TerminalPointerScope.onTapUp]), the shape
/// of xterm 4.0.0's `onTapUp` with a [GridPoint] for its `CellOffset`.
/// Never exported.
typedef TerminalTapUpCallback =
    void Function(TapUpDetails details, GridPoint cell);

/// Called with the details of a secondary press and the viewport cell under
/// it (see [TerminalPointerScope.onSecondaryTapDown]). Never exported.
typedef TerminalTapDownCallback =
    void Function(TapDownDetails details, GridPoint cell);

/// The devices that go through gesture recognizers (and so compete in the
/// gesture arena with enclosing scrollables, page views and drawers).
const _arenaDevices = {
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

/// Mouse, touch, stylus, trackpad and wheel input for the view (ADR 0011).
/// Never exported.
///
/// **Mouse** (raw pointer events, so reports never wait for the gesture
/// arena). While the program tracks the mouse (DEC 9, 1000, 1002, 1003),
/// presses, releases and motion are reported to it through
/// [TerminalPointerSink.sendMouse]. Holding Shift bypasses the reports and
/// selects instead (Ghostty's default). Otherwise the primary button
/// selects through a [SelectionGesture] that this widget creates and
/// disposes:
/// - drag selects cells; a double click selects words and a triple click
///   lines (the drag then extends by words or lines);
/// - a block (rectangle) selection is made while Option is held on Apple
///   platforms and Ctrl+Alt (or Super+Alt) elsewhere, re-read on every
///   drag event, as Ghostty does (Alt+drag usually moves the window on
///   Linux and Windows);
/// - dragging past the top or bottom edge autoscrolls every 15 ms
///   (Ghostty's `selection_scroll_ms`);
/// - Shift+click (and Shift+drag) extends the current selection to the
///   pointer, reading the selection again every time.
///
/// **Wheel.** Pixel deltas are accumulated into rows of the cell height
/// and routed by [TerminalScrollRouter]: wheel reports while the program
/// tracks the mouse, raw cursor keys on the alternate screen with DEC
/// 1007, otherwise the viewport. libghostty keeps a scrolled-back viewport
/// anchored while output arrives. A macOS mouse wheel scrolls at least one
/// line of three rows per discrete notch, as Ghostty does
/// ([wheelScrollExtent]).
///
/// **Touch, stylus and trackpad** go through gesture recognizers, so they
/// compete fairly with enclosing scrollables: a vertical drag (a
/// two-finger trackpad pan included) scrolls like the wheel, but is only
/// claimed while there is something to scroll
/// ([TerminalScrollRouter.canScroll]); a long press selects the word
/// under it and a drag extends it (keeping the word); a tap clears the
/// selection, or is reported as a left click while the program tracks
/// the mouse. There are no selection handles and no fling yet.
///
/// **Cursor.** The I-beam over text, the arrow while the program tracks
/// the mouse, the program's OSC 22 shape when it set one, and a crosshair
/// while a drag would select a block.
///
/// [pointer] must stay the same object while the view shows the same
/// controller: a different one ends the press in progress and drops the
/// click sequence.
class TerminalPointerScope extends StatefulWidget {
  /// Pointer input over [child].
  const TerminalPointerScope({
    super.key,
    required this.pointer,
    required this.viewport,
    required this.keys,
    required this.geometry,
    required this.child,
    this.text,
    this.mouseCursor,
    this.onPointerDown,
    this.onTapUp,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
  });

  /// Where mouse reports and selections go.
  final TerminalPointerSink pointer;

  /// The scrollback position, for wheel scrolling.
  final TerminalViewport viewport;

  /// Fallback for alternate-scroll arrow keys when [text] is not given.
  final TerminalKeySink keys;

  /// Where the raw alternate-scroll (DEC 1007) sequences go, byte for
  /// byte what Ghostty sends. Without it they go through [keys], whose
  /// encoder differs from Ghostty under the Kitty keyboard protocol.
  final TerminalTextSink? text;

  /// Where the grid is, to map pointer positions to cells.
  final TerminalGeometry geometry;

  /// The rest of the view.
  final Widget child;

  /// The cursor shown instead of the I-beam over text, or `null` for
  /// [SystemMouseCursors.text]. The program's OSC 22 shapes and the arrow
  /// while it tracks the mouse still apply.
  final MouseCursor? mouseCursor;

  /// Called first for every pointer press of any device, whether it is
  /// reported to the program, selects or scrolls; for example to request
  /// focus or show the soft keyboard.
  final ValueChanged<PointerDownEvent>? onPointerDown;

  /// A primary click or tap that selected nothing (no drag, no double
  /// click) and was not reported to the program, with its viewport cell.
  final TerminalTapUpCallback? onTapUp;

  /// A secondary (right) mouse press that was not reported to the
  /// program, with its viewport cell.
  final TerminalTapDownCallback? onSecondaryTapDown;

  /// The release of a secondary press passed to [onSecondaryTapDown].
  final TerminalTapUpCallback? onSecondaryTapUp;

  @override
  State<TerminalPointerScope> createState() => _TerminalPointerScopeState();
}

/// What the mouse button that is down is doing.
enum _Route {
  /// No button is down (or the press is ignored).
  none,

  /// Mouse buttons are reported to the program.
  report,

  /// The primary button drives the selection gesture.
  select,

  /// Shift+click: the end of the selection follows the pointer.
  extend,

  /// A secondary press that was not reported.
  secondary,
}

/// A vertical drag recognizer that only takes part while [canScroll] says
/// a scroll would do something, so an enclosing scrollable keeps the drag
/// over a terminal with nothing to scroll.
class _TerminalDragRecognizer extends VerticalDragGestureRecognizer {
  _TerminalDragRecognizer({
    required this.canScroll,
    super.debugOwner,
    super.supportedDevices,
  });

  final bool Function() canScroll;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      canScroll() && super.isPointerAllowed(event);

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) =>
      canScroll() && super.isPointerPanZoomAllowed(event);
}

/// The pointer layer's state: the press in progress, the selection
/// gesture, the accumulators and timers, and the cursor.
class _TerminalPointerScopeState extends State<TerminalPointerScope> {
  /// Ghostty's default `click-repeat-interval` off macOS
  /// (`src/config/Config.zig` at tag `vt-1.0.0`). Flutter exposes no OS
  /// double-click interval (`kDoubleTapTimeout` is a fixed 300 ms for
  /// touch).
  static const _repeatInterval = Duration(milliseconds: 500);

  /// Ghostty's `selection_scroll_ms` (`src/termio/Thread.zig` at tag
  /// `vt-1.0.0`).
  static const _autoscrollInterval = Duration(milliseconds: 15);

  SelectionGesture? _gesture;
  _Route _route = _Route.none;
  int? _activePointer;

  /// The buttons reported as pressed to the program.
  int _reportedButtons = 0;

  /// The last cell a motion report was sent for (motion de-duplication;
  /// the controller's `setFromTerminal` clears the encoder's own).
  GridPoint? _lastMotionCell;
  int _lastMotionButtons = -1;

  final _wheelRows = RowAccumulator();
  final _wheelStream = WheelStream();
  final _wheelCols = RowAccumulator();
  final _dragRows = RowAccumulator();

  Timer? _autoscrollTimer;
  Offset _lastLocal = Offset.zero;

  /// The word a touch long press selected, in screen coordinates, so a
  /// drag extends from whichever end keeps it.
  GridPoint? _wordStart;
  GridPoint? _wordEnd;

  MouseCursor _cursor = SystemMouseCursors.text;
  bool _cursorUpdateScheduled = false;

  late final Map<Type, GestureRecognizerFactory> _gestures = {
    _TerminalDragRecognizer:
        GestureRecognizerFactoryWithHandlers<_TerminalDragRecognizer>(
          () => _TerminalDragRecognizer(
            canScroll: () => _router.canScroll,
            debugOwner: this,
            supportedDevices: {..._arenaDevices, PointerDeviceKind.trackpad},
          ),
          (recognizer) => recognizer
            // Report the slop distance too, so no scroll is lost.
            ..dragStartBehavior = DragStartBehavior.down
            ..onStart = _onDragStart
            ..onUpdate = _onDragUpdate,
        ),
    LongPressGestureRecognizer:
        GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(
            debugOwner: this,
            supportedDevices: _arenaDevices,
          ),
          (recognizer) => recognizer
            ..onLongPressStart = _onLongPressStart
            ..onLongPressMoveUpdate = _onLongPressMove,
        ),
    TapGestureRecognizer:
        GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(
            debugOwner: this,
            supportedDevices: _arenaDevices,
          ),
          (recognizer) => recognizer.onTapUp = _onTouchTap,
        ),
  };

  TerminalPointerSink get _pointer => widget.pointer;
  TerminalGeometry get _geometry => widget.geometry;

  TerminalScrollRouter get _router => TerminalScrollRouter(
    viewport: widget.viewport,
    pointer: widget.pointer,
    keys: widget.keys,
    text: widget.text,
  );

  @override
  void initState() {
    super.initState();
    widget.viewport.addListener(_onTerminalChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    _pushGeometry();
    _cursor = _computeCursor();
  }

  @override
  void didUpdateWidget(TerminalPointerScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewport, widget.viewport)) {
      oldWidget.viewport.removeListener(_onTerminalChanged);
      widget.viewport.addListener(_onTerminalChanged);
    }
    final pointerChanged = !identical(oldWidget.pointer, widget.pointer);
    if (pointerChanged ||
        oldWidget.geometry.metrics.widthPx != widget.geometry.metrics.widthPx) {
      // The repeat distance is one cell; a new terminal needs a new
      // gesture.
      _endPointer(cancelled: true, sink: oldWidget.pointer);
      _disposeGesture();
    }
    if (pointerChanged || oldWidget.geometry != widget.geometry) {
      _pushGeometry();
    }
    if (pointerChanged || oldWidget.mouseCursor != widget.mouseCursor) {
      _cursor = _computeCursor();
    }
  }

  @override
  void dispose() {
    widget.viewport.removeListener(_onTerminalChanged);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _endPointer(cancelled: true, sink: widget.pointer);
    _disposeGesture();
    super.dispose();
  }

  void _pushGeometry() {
    if (!_pointer.isDisposed) {
      _pointer.setMouseGeometry(_geometry.mouseEncoderSize);
    }
  }

  void _disposeGesture() {
    _gesture?.dispose();
    _gesture = null;
  }

  /// The selection gesture, created on first use from the pointer sink's
  /// terminal; `null` once the controller is disposed.
  SelectionGesture? get _selectionGesture {
    if (_pointer.isDisposed) return null;
    final gesture = _gesture;
    if (gesture != null && !gesture.isDisposed) return gesture;
    return _gesture = SelectionGesture(
      _pointer.terminal,
      repeatInterval: _repeatInterval,
      // Ghostty uses one cell width (`max_distance` in `src/Surface.zig`).
      repeatDistance: _geometry.metrics.widthPx.toDouble(),
    );
  }

  /// The viewport cell under [local], clamped to the geometry's grid and
  /// to the terminal's: after a public `resize` the terminal can be
  /// smaller than the last layout until the next one.
  GridPoint _cellAt(Offset local) {
    final cell = _geometry.viewportCellAt(local);
    final vt = _pointer.terminal;
    return GridPoint.viewport(
      math.min(cell.x, vt.cols - 1),
      math.min(cell.y, vt.rows - 1),
    );
  }

  /// Runs a gesture or selection call, dropping the event if the grid
  /// changed under it (the library rejects cells or geometry that no
  /// longer fit with [ArgumentError] or [RangeError]).
  T? _guarded<T>(T Function() call) {
    try {
      return call();
    } on ArgumentError {
      return null;
    }
  }

  // -------------------------------------------------------------------
  // Cursor
  // -------------------------------------------------------------------

  MouseCursor _computeCursor() {
    final text = widget.mouseCursor ?? SystemMouseCursors.text;
    if (_pointer.isDisposed) return text;
    return terminalMouseCursor(
      tracking: _pointer.isMouseTracking,
      shape: _pointer.mouseShape,
      modifiers: currentKeyModifiers(),
      platform: defaultTargetPlatform,
      text: text,
    );
  }

  /// Re-reads the cursor once per frame at most: the terminal notifies on
  /// every write, and modes and the OSC 22 shape have no notification of
  /// their own.
  void _scheduleCursorUpdate() {
    if (_cursorUpdateScheduled) return;
    _cursorUpdateScheduled = true;
    final scheduler = SchedulerBinding.instance;
    scheduler.addPostFrameCallback((_) {
      _cursorUpdateScheduled = false;
      if (!mounted) return;
      final cursor = _computeCursor();
      if (cursor != _cursor) setState(() => _cursor = cursor);
    });
    if (!scheduler.hasScheduledFrame) scheduler.ensureVisualUpdate();
  }

  void _onTerminalChanged() => _scheduleCursorUpdate();

  static final _modifierKeys = {
    ...LogicalKeyboardKey.expandSynonyms({
      LogicalKeyboardKey.shift,
      LogicalKeyboardKey.alt,
      LogicalKeyboardKey.control,
      LogicalKeyboardKey.meta,
    }),
  };

  bool _onKey(KeyEvent event) {
    // Shift, Alt, Ctrl and Meta change what a click does, so they change
    // the cursor. Never consumes the event.
    if (_modifierKeys.contains(event.logicalKey)) _scheduleCursorUpdate();
    return false;
  }

  // -------------------------------------------------------------------
  // Mouse events (raw)
  // -------------------------------------------------------------------

  static bool _isMouse(PointerEvent event) =>
      event.kind == PointerDeviceKind.mouse ||
      event.kind == PointerDeviceKind.unknown;

  /// Whether mouse events go to the program now (it tracks the mouse and
  /// Shift is not held).
  bool _reports(KeyModifiers modifiers) =>
      !modifiers.hasShift && _pointer.isMouseTracking;

  void _onPointerDown(PointerDownEvent event) {
    widget.onPointerDown?.call(event);
    if (_pointer.isDisposed || !_isMouse(event)) return;
    if (_activePointer != null && _activePointer != event.pointer) return;
    _activePointer = event.pointer;
    _lastLocal = event.localPosition;
    final modifiers = currentKeyModifiers();

    if (_reports(modifiers)) {
      _route = _Route.report;
      _syncReportedButtons(event, modifiers);
      return;
    }

    final cell = _cellAt(event.localPosition);
    if (event.buttons & kPrimaryButton != 0) {
      if (modifiers.hasShift && _pointer.selection != null) {
        _route = _Route.extend;
        _extendSelectionTo(cell);
        return;
      }
      _route = _Route.select;
      final gesture = _selectionGesture;
      if (gesture == null) return;
      final selection = _guarded(
        () => gesture.press(
          cell,
          position: _geometry.toSurface(event.localPosition),
          time: event.timeStamp,
        ),
      );
      _setSelection(selection);
      return;
    }
    if (event.buttons & kSecondaryButton != 0) {
      _route = _Route.secondary;
      widget.onSecondaryTapDown?.call(
        TapDownDetails(
          globalPosition: event.position,
          localPosition: event.localPosition,
          kind: event.kind,
        ),
        cell,
      );
      return;
    }
    _route = _Route.none;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_pointer.isDisposed || event.pointer != _activePointer) return;
    _lastLocal = event.localPosition;
    switch (_route) {
      case _Route.report:
        final modifiers = currentKeyModifiers();
        // Another button pressed or released while one is held arrives as
        // a move with different buttons; the press or release report
        // carries the position, so no motion report follows it.
        if (event.buttons != _reportedButtons) {
          _syncReportedButtons(event, modifiers);
        } else {
          _reportMotion(event, modifiers);
        }
      case _Route.select:
        _dragSelection();
      case _Route.extend:
        _extendSelectionTo(_cellAt(event.localPosition));
      case _Route.secondary || _Route.none:
        break;
    }
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (_pointer.isDisposed || _activePointer != null || !_isMouse(event)) {
      return;
    }
    _lastLocal = event.localPosition;
    final modifiers = currentKeyModifiers();
    // Any-event tracking (DEC 1003) reports motion with no button; the
    // encoder drops it in the other modes.
    if (_reports(modifiers)) _reportMotion(event, modifiers);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    if (!_pointer.isDisposed) {
      final cell = _cellAt(event.localPosition);
      switch (_route) {
        case _Route.select:
          final gesture = _gesture;
          if (gesture != null && !gesture.isDisposed) {
            final tap = !gesture.hasDragged && gesture.clickCount == 1;
            _guarded(() => gesture.release(cell));
            if (tap) widget.onTapUp?.call(_tapUpDetails(event), cell);
          }
        case _Route.secondary:
          widget.onSecondaryTapUp?.call(_tapUpDetails(event), cell);
        case _Route.report:
          _syncReportedButtons(event, currentKeyModifiers());
        case _Route.extend || _Route.none:
          break;
      }
    }
    _endPointer(cancelled: false, sink: _pointer);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    _endPointer(cancelled: true, sink: _pointer);
  }

  /// Ends the mouse press in progress: releases reported buttons (so the
  /// program never sees a button stuck down), stops autoscroll and resets
  /// the route.
  void _endPointer({
    required bool cancelled,
    required TerminalPointerSink sink,
  }) {
    _autoscrollTimer?.cancel();
    _autoscrollTimer = null;
    if (!sink.isDisposed) {
      if (_reportedButtons != 0) {
        final position = _geometry.toSurface(_lastLocal);
        for (final bit in buttonBits(_reportedButtons)) {
          sink.sendMouse(
            VtMouseEvent(
              action: MouseAction.release,
              button: mouseButtonOf(bit),
              x: position.x,
              y: position.y,
            ),
          );
        }
        sink.setMouseButtonsPressed(anyPressed: false);
      }
      if (cancelled && _route == _Route.select) {
        final gesture = _gesture;
        if (gesture != null && !gesture.isDisposed) gesture.release();
      }
    }
    _reportedButtons = 0;
    _route = _Route.none;
    _activePointer = null;
  }

  // -------------------------------------------------------------------
  // Mouse reports
  // -------------------------------------------------------------------

  /// Sends a press for every button newly held in [event] and a release
  /// for every one let go, and keeps the encoder's "any button pressed"
  /// state current.
  void _syncReportedButtons(PointerEvent event, KeyModifiers modifiers) {
    final buttons = event is PointerUpEvent ? 0 : event.buttons;
    final pressed = buttons & ~_reportedButtons;
    final released = _reportedButtons & ~buttons;
    _reportedButtons = buttons;
    _pointer.setMouseButtonsPressed(anyPressed: buttons != 0);
    final position = _geometry.toSurface(event.localPosition);
    void send(MouseAction action, int bits) {
      for (final bit in buttonBits(bits)) {
        _pointer.sendMouse(
          VtMouseEvent(
            action: action,
            button: mouseButtonOf(bit),
            modifiers: modifiers,
            x: position.x,
            y: position.y,
          ),
        );
      }
    }

    send(MouseAction.release, released);
    send(MouseAction.press, pressed);
    _lastMotionCell = _geometry.viewportCellAt(event.localPosition);
    _lastMotionButtons = buttons;
  }

  /// Reports motion, dropping motion that stays in the same cell with the
  /// same buttons unless the program asked for pixel positions (SGR-Pixels,
  /// DEC 1016).
  void _reportMotion(PointerEvent event, KeyModifiers modifiers) {
    final buttons = event is PointerHoverEvent ? 0 : _reportedButtons;
    final cell = _geometry.viewportCellAt(event.localPosition);
    if (cell == _lastMotionCell &&
        buttons == _lastMotionButtons &&
        !_pointer.isModeEnabled(TerminalMode.mouseFormatSgrPixels)) {
      return;
    }
    _lastMotionCell = cell;
    _lastMotionButtons = buttons;
    final position = _geometry.toSurface(event.localPosition);
    _pointer.sendMouse(
      VtMouseEvent(
        action: MouseAction.motion,
        button: heldButtonOf(buttons),
        modifiers: modifiers,
        x: position.x,
        y: position.y,
      ),
    );
  }

  // -------------------------------------------------------------------
  // Selection
  // -------------------------------------------------------------------

  void _setSelection(VtSelection? selection) {
    if (selection == null && _pointer.selection == null) return;
    _pointer.selection = selection;
  }

  bool get _rectangle =>
      isRectangleSelect(currentKeyModifiers(), defaultTargetPlatform);

  void _dragSelection() {
    final gesture = _gesture;
    if (gesture == null || gesture.isDisposed) return;
    final selection = _guarded(
      () => gesture.drag(
        _cellAt(_lastLocal),
        geometry: _geometry.selectionGeometry,
        position: _geometry.toSurface(_lastLocal),
        rectangle: _rectangle,
      ),
    );
    if (selection != null) _pointer.selection = selection;
    _updateAutoscroll(gesture);
  }

  void _updateAutoscroll(SelectionGesture gesture) {
    final wanted =
        gesture.autoscroll == SelectionAutoscroll.up ||
        gesture.autoscroll == SelectionAutoscroll.down;
    if (!wanted) {
      _autoscrollTimer?.cancel();
      _autoscrollTimer = null;
    } else {
      _autoscrollTimer ??= Timer.periodic(
        _autoscrollInterval,
        (_) => _autoscrollTick(),
      );
    }
  }

  void _autoscrollTick() {
    final gesture = _gesture;
    if (_pointer.isDisposed ||
        gesture == null ||
        gesture.isDisposed ||
        _route != _Route.select) {
      _autoscrollTimer?.cancel();
      _autoscrollTimer = null;
      return;
    }
    final selection = _guarded(
      () => gesture.autoscrollTick(
        _cellAt(_lastLocal),
        geometry: _geometry.selectionGeometry,
        position: _geometry.toSurface(_lastLocal),
        rectangle: _rectangle,
      ),
    );
    // The tick scrolled the terminal itself; setting the selection is what
    // notifies the view. `null` means nothing scrolled (top or bottom
    // reached, or the pressed cell left the screen).
    if (selection != null) _pointer.selection = selection;
    _updateAutoscroll(gesture);
  }

  /// Moves the end of the current selection to [cell], keeping its start
  /// (Shift+click). Reads the selection again every time: a snapshot goes
  /// stale on the next write or scroll.
  void _extendSelectionTo(GridPoint cell) {
    final current = _pointer.selection;
    if (current == null) return;
    final start = current.start.pointIn(PointSpace.screen);
    if (start == null) return;
    _select(start, cell, rectangle: current.isRectangle);
  }

  void _select(GridPoint from, GridPoint to, {bool rectangle = false}) {
    final selection = _guarded(
      () => _pointer.terminal.selectRange(from, to, rectangle: rectangle),
    );
    if (selection != null) _pointer.selection = selection;
  }

  // -------------------------------------------------------------------
  // Touch, stylus and trackpad (gesture recognizers)
  // -------------------------------------------------------------------

  void _onDragStart(DragStartDetails details) => _dragRows.reset();

  void _onDragUpdate(DragUpdateDetails details) {
    if (_pointer.isDisposed) return;
    // Moving down drags the content down: it scrolls up.
    final rows = _dragRows.add(-details.delta.dy, _geometry.metrics.height);
    _router.scroll(
      rows,
      surface: _geometry.toSurface(details.localPosition),
      modifiers: currentKeyModifiers(),
    );
  }

  void _onLongPressStart(LongPressStartDetails details) {
    if (_pointer.isDisposed) return;
    final word = _guarded(
      () => _pointer.terminal.selectWord(_cellAt(details.localPosition)),
    );
    _wordStart = word?.start.pointIn(PointSpace.screen);
    _wordEnd = word?.end.pointIn(PointSpace.screen);
    if (word != null) _pointer.selection = word;
  }

  /// Extends the long-pressed word to the pointer, from the word's far end
  /// when the pointer is before the word, so the word stays selected.
  void _onLongPressMove(LongPressMoveUpdateDetails details) {
    final start = _wordStart, end = _wordEnd;
    if (_pointer.isDisposed || start == null || end == null) return;
    final target = _pointer.terminal
        .gridRef(_cellAt(details.localPosition))
        ?.pointIn(PointSpace.screen);
    if (target == null) return;
    final before =
        target.y < start.y || (target.y == start.y && target.x < start.x);
    _select(before ? end : start, target);
  }

  void _onTouchTap(TapUpDetails details) {
    if (_pointer.isDisposed) return;
    if (_reports(KeyModifiers.none)) {
      final position = _geometry.toSurface(details.localPosition);
      void send(MouseAction action) => _pointer.sendMouse(
        VtMouseEvent(
          action: action,
          button: MouseButton.left,
          x: position.x,
          y: position.y,
        ),
      );
      _pointer.setMouseButtonsPressed(anyPressed: true);
      send(MouseAction.press);
      _pointer.setMouseButtonsPressed(anyPressed: false);
      send(MouseAction.release);
      return;
    }
    _setSelection(null);
    widget.onTapUp?.call(details, _cellAt(details.localPosition));
  }

  static TapUpDetails _tapUpDetails(PointerEvent event) => TapUpDetails(
    kind: event.kind,
    globalPosition: event.position,
    localPosition: event.localPosition,
  );

  // -------------------------------------------------------------------
  // Wheel
  // -------------------------------------------------------------------

  void _onPointerSignal(PointerSignalEvent event) {
    if (_pointer.isDisposed) return;
    if (event is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (resolved) => _onWheel(resolved as PointerScrollEvent),
      );
    } else if (event is PointerScrollInertiaCancelEvent) {
      _wheelRows.reset();
      _wheelCols.reset();
    }
  }

  void _onWheel(PointerScrollEvent event) {
    if (_pointer.isDisposed) return;
    final modifiers = currentKeyModifiers();
    var delta = event.scrollDelta;
    // Some platforms turn Shift+wheel into a horizontal scroll; with Shift
    // the wheel always scrolls the scrollback.
    if (modifiers.hasShift && delta.dy == 0) delta = Offset(0, delta.dx);
    final rowExtent = _geometry.metrics.height;
    final rows = _wheelRows.add(
      wheelScrollExtent(
        delta.dy,
        rowExtent,
        platform: defaultTargetPlatform,
        kind: event.kind,
        isolated: _wheelStream.isolated(event.timeStamp),
      ),
      rowExtent,
    );
    final cols = modifiers.hasShift
        ? 0
        : _wheelCols.add(delta.dx, _geometry.metrics.width);
    _router.scroll(
      rows,
      cols: cols,
      surface: _geometry.toSurface(event.localPosition),
      modifiers: modifiers,
    );
  }

  @override
  Widget build(BuildContext context) {
    // The terminal owns its selection: an ancestor SelectionArea must not
    // take part in drags over it.
    return SelectionContainer.disabled(
      child: MouseRegion(
        cursor: _cursor,
        child: RawGestureDetector(
          gestures: _gestures,
          behavior: HitTestBehavior.opaque,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerHover: _onPointerHover,
            onPointerCancel: _onPointerCancel,
            onPointerSignal: _onPointerSignal,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
