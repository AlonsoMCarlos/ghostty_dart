/// Pointer gestures that make selections (`selection.h`, gestures and
/// gesture events).
library;

import 'dart:ffi';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../grid/grid_ref.dart' show GridRef, gridRefFromNative;
import '../terminal/terminal.dart' show VtTerminal;
import 'selection_enums.dart';
import 'selection_native.dart';
import 'selection_values.dart';
import 'vt_selection.dart';

/// Turns pointer events into selections the way Ghostty does: click and
/// drag selects cells, a double click selects words, a triple click lines,
/// dragging past the top or bottom edge autoscrolls, and so on.
///
/// Feed it the primary button's events of one terminal view. Each event
/// returns the selection to show (or `null`); install it with
/// `terminal.selection = ...`, which the gesture never does itself.
///
/// ```dart
/// final gesture = SelectionGesture(
///   terminal,
///   repeatInterval: const Duration(milliseconds: 500),
///   repeatDistance: 4,
/// );
/// // pointer down:
/// terminal.selection = gesture.press(cell, position: pos, time: t);
/// // pointer move with the button held:
/// final s = gesture.drag(cell, geometry: geometry, position: pos);
/// if (s != null) terminal.selection = s;
/// // pointer up:
/// gesture.release(cell);
/// ```
///
/// Cells are [GridPoint]s, usually [PointSpace.viewport] points computed
/// from the pointer and the cell size; positions are surface pixels with
/// (0, 0) at the top-left of the terminal view.
///
/// **Ownership:** a gesture belongs to the terminal given to its
/// constructor and keeps it reachable. Call [dispose] when done; disposing
/// the terminal disposes it first. A forgotten gesture is freed some time
/// after it is garbage collected (between event-loop turns). Members throw
/// [StateError] after [dispose] and when called from inside a callback of
/// the terminal.
final class SelectionGesture implements Finalizable {
  /// A gesture for [terminal].
  ///
  /// [behaviors] says what single, double and triple clicks select (cells,
  /// words, lines by default). Two presses count as a double click when
  /// they are at most [repeatInterval] apart in time and [repeatDistance]
  /// pixels apart, and both presses pass `time` (and `position`); `null`
  /// keeps the library default of 0, which disables double and triple
  /// clicks. [wordBoundaryCodepoints] works as in
  /// [VtTerminalSelection.selectWord].
  ///
  /// Throws [RangeError] for a negative [repeatInterval] or
  /// [repeatDistance], or a boundary value that is not a Unicode scalar
  /// value, and [StateError] if [terminal] is disposed.
  SelectionGesture(
    VtTerminal terminal, {
    this.behaviors,
    this.repeatInterval,
    this.repeatDistance,
    List<int>? wordBoundaryCodepoints,
  }) : _terminal = terminal,
       wordBoundaryCodepoints = _checkedCodepoints(wordBoundaryCodepoints),
       _handle = _create(
         handleOf<GhosttyTerminalImpl>(terminal),
         repeatInterval,
         repeatDistance,
       ) {
    bindHandle(this, _handle);
    final terminalHandle = _terminalHandle;
    terminalHandle.addDependent(_handle);
    // Like a NativeFinalizer, the Dart one watches the handle; dispose()
    // detaches it through a cleanup. The locals keep `this` out of the
    // closure. The token holds the terminal handle, so the terminal cannot
    // be finalized (on another thread) before this gesture is.
    final handle = _handle;
    _finalizer.attach(handle, (
      gesture: handle.pointer.address,
      terminal: terminalHandle,
    ), detach: handle);
    handle.addCleanup(() => _finalizer.detach(handle));
  }

  /// Validates the arguments, then creates the native gesture (so a
  /// validation error leaks nothing).
  static NativeHandle<GhosttySelectionGestureImpl> _create(
    NativeHandle<GhosttyTerminalImpl> terminal,
    Duration? repeatInterval,
    double? repeatDistance,
  ) {
    terminal.checkNotDisposed();
    if (repeatInterval != null && repeatInterval.isNegative) {
      throw RangeError.value(
        repeatInterval.inMicroseconds,
        'repeatInterval',
        'must not be negative',
      );
    }
    if (repeatDistance != null && !(repeatDistance >= 0)) {
      throw RangeError.value(
        repeatDistance,
        'repeatDistance',
        'must not be negative',
      );
    }
    final pointer = createNative<GhosttySelectionGestureImpl>(
      'ghostty_selection_gesture_new',
      (out) => ghostty_selection_gesture_new(nullptr, out),
    );
    return NativeHandle(
      pointer,
      typeName: 'SelectionGesture',
      free: (p) => ghostty_selection_gesture_free(p, _liveTerminal(terminal)),
      finalizer: null,
    );
  }

  /// Frees a forgotten gesture on this isolate's event loop.
  ///
  /// Not a `NativeFinalizer`: `ghostty_selection_gesture_free` releases the
  /// gesture's tracked cell in its (still live) terminal, and a native
  /// finalizer may run on any thread while this isolate is inside a
  /// terminal call. A Dart [Finalizer] never runs while a terminal call is
  /// on the stack.
  static final _finalizer =
      Finalizer<({int gesture, NativeHandle<GhosttyTerminalImpl> terminal})>(
        (token) => ghostty_selection_gesture_free(
          Pointer.fromAddress(token.gesture),
          _liveTerminal(token.terminal),
        ),
      );

  /// An unmodifiable copy of [codepoints], after checking every value.
  static List<int>? _checkedCodepoints(List<int>? codepoints) {
    if (codepoints == null) return null;
    withCodepoints(codepoints, 'wordBoundaryCodepoints', (_, _) {});
    return List.unmodifiable(codepoints);
  }

  /// The terminal pointer for `ghostty_selection_gesture_free`, or NULL
  /// once [terminal] is disposed.
  ///
  /// The terminal disposes this gesture (a dependent) after marking itself
  /// disposed but before freeing itself, so NULL is also passed then. That
  /// is safe: the tracked cell lives in the terminal's page list, which
  /// the terminal frees right after.
  static Pointer<GhosttyTerminalImpl> _liveTerminal(
    NativeHandle<GhosttyTerminalImpl> terminal,
  ) => terminal.isDisposed ? nullptr : terminal.pointer;

  /// Strong reference: every event needs the terminal.
  final VtTerminal _terminal;
  final NativeHandle<GhosttySelectionGestureImpl> _handle;

  /// What single, double and triple clicks select; `null` uses the default
  /// [SelectionGestureBehaviors].
  final SelectionGestureBehaviors? behaviors;

  /// The longest time between two presses of a double or triple click;
  /// `null` uses the library default (0: no repeated clicks).
  final Duration? repeatInterval;

  /// The farthest two presses of a double or triple click may be apart, in
  /// pixels; `null` uses the library default (0).
  final double? repeatDistance;

  /// The codepoints that end words for word selection, or `null` for
  /// Ghostty's defaults. Unmodifiable.
  final List<int>? wordBoundaryCodepoints;

  NativeHandle<GhosttyTerminalImpl> get _terminalHandle =>
      handleOf<GhosttyTerminalImpl>(_terminal);

  /// Whether [dispose] has been called (directly or by disposing the
  /// terminal).
  bool get isDisposed => _handle.isDisposed;

  /// A press of the button on the cell at [at]: starts a click, or
  /// continues a double or triple click (see the constructor).
  ///
  /// Returns the selection the click makes at once (a word for a double
  /// click with the default [behaviors]), or `null` when it makes none (a
  /// single click). [position] is the pointer in surface pixels and [time]
  /// a monotonic timestamp (such as a pointer event's); both are needed to
  /// detect repeated clicks.
  ///
  /// Throws [ArgumentError] when [at] is outside its coordinate space or
  /// in [PointSpace.unknown]; clamp the pointer to the grid first.
  VtSelection? press(
    GridPoint at, {
    ({double x, double y})? position,
    Duration? time,
  }) => _apply(
    'press',
    GhosttySelectionGestureEventType.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS,
    (event, terminal) {
      _setRef(event, terminal, at, required: true);
      _setPosition(event, position);
      if (time != null) _setUint64(event, _Opt.timeNs, _nanoseconds(time));
      if (repeatInterval case final interval?) {
        _setUint64(event, _Opt.repeatIntervalNs, _nanoseconds(interval));
      }
      if (repeatDistance case final distance?) {
        _withValue(event, _Opt.repeatDistance, sizeOf<Double>(), (value) {
          value.cast<Double>().value = distance;
        });
      }
      if (behaviors case final table?) _setBehaviors(event, table);
      _setWordBoundaries(event);
    },
  );

  /// A release of the button on the cell at [at], or off the grid when
  /// [at] is `null` or outside its coordinate space.
  ///
  /// Ends the drag but keeps the click sequence, so the next [press] can
  /// still become a double click. Makes no selection: keep the last one.
  void release([GridPoint? at]) => _apply(
    'release',
    GhosttySelectionGestureEventType
        .GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE,
    (event, terminal) {
      if (at != null) _setRef(event, terminal, at, required: false);
    },
  );

  /// A move of the pointer, with the button held, over the cell at [at].
  ///
  /// Returns the selection from the press to [at] at the granularity of
  /// the click (cells, words, lines), or `null` when there is none yet (a
  /// drag that has not yet crossed 60% of a cell). With [rectangle] (usually
  /// while Alt is held) the selection is a block.
  ///
  /// [geometry] tells where cells and edges are. Afterwards, check
  /// [autoscroll]: while it is [SelectionAutoscroll.up] or
  /// [SelectionAutoscroll.down], call [autoscrollTick] from a timer.
  ///
  /// Throws [ArgumentError] when [at] is outside its coordinate space or
  /// in [PointSpace.unknown], and [RangeError] for an invalid [geometry].
  VtSelection? drag(
    GridPoint at, {
    required SelectionGestureGeometry geometry,
    ({double x, double y})? position,
    bool rectangle = false,
  }) => _apply(
    'drag',
    GhosttySelectionGestureEventType.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG,
    (event, terminal) {
      _setRef(event, terminal, at, required: true);
      _setGeometry(event, geometry);
      _setPosition(event, position);
      _setRectangle(event, rectangle);
      _setWordBoundaries(event);
    },
  );

  /// One step of autoscroll during a drag past the top or bottom edge:
  /// scrolls the viewport one row in the [autoscroll] direction and
  /// continues the drag at [at], a [PointSpace.viewport] cell.
  ///
  /// The gesture has no timer: call this periodically while [autoscroll]
  /// is not [SelectionAutoscroll.none] (faster ticks scroll faster).
  /// Returns the new selection, or `null` when there is nothing to scroll;
  /// `null` with [clickCount] 0 means the pressed cell left the screen and
  /// the gesture was reset, so stop the timer. Scrolling changes the
  /// terminal: earlier selections and grid references become stale.
  ///
  /// Throws [ArgumentError] unless [at] is a [PointSpace.viewport] point,
  /// and [RangeError] for an invalid [geometry] or coordinate.
  VtSelection? autoscrollTick(
    GridPoint at, {
    required SelectionGestureGeometry geometry,
    ({double x, double y})? position,
    bool rectangle = false,
  }) {
    if (at.space != PointSpace.viewport) {
      throw ArgumentError.value(at, 'at', 'must be a viewport point');
    }
    return _apply(
      'autoscrollTick',
      GhosttySelectionGestureEventType
          .GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK,
      (event, terminal) {
        _withValue(
          event,
          _Opt.viewport,
          sizeOf<GhosttyPointCoordinate>(),
          (value) => value.cast<GhosttyPointCoordinate>().ref
            ..x = RangeError.checkValueInInterval(at.x, 0, 0xFFFF, 'at.x')
            ..y = RangeError.checkValueInInterval(at.y, 0, 0xFFFFFFFF, 'at.y'),
        );
        _setGeometry(event, geometry);
        _setPosition(event, position);
        _setRectangle(event, rectangle);
        _setWordBoundaries(event);
      },
      scrolls: true,
    );
  }

  /// A deep (force) press, as on a pressure-sensitive trackpad: selects the
  /// word under the last press, or returns `null` if there is none.
  VtSelection? deepPress() => _apply(
    'deepPress',
    GhosttySelectionGestureEventType
        .GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS,
    (event, terminal) => _setWordBoundaries(event),
  );

  /// Cancels the click sequence and any drag: the next [press] is a fresh
  /// single click. Does not touch the terminal's selection.
  void reset() {
    final pointer = _pointer('reset');
    ghostty_selection_gesture_reset(pointer, _terminalHandle.pointer);
  }

  /// The number of clicks in the current sequence (1 single, 2 double, 3
  /// triple), or 0 when no click is active.
  int get clickCount => _read(
    'clickCount',
    GhosttySelectionGestureData.GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT,
    sizeOf<Uint8>(),
    (out) => out.value,
  )!;

  /// Whether the current (or last) click has been dragged.
  bool get hasDragged => _read(
    'hasDragged',
    GhosttySelectionGestureData.GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED,
    sizeOf<Bool>(),
    (out) => out.cast<Bool>().value,
  )!;

  /// Which way the drag wants the viewport to scroll; see [autoscrollTick].
  SelectionAutoscroll get autoscroll => _read(
    'autoscroll',
    GhosttySelectionGestureData.GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL,
    sizeOf<UnsignedInt>(),
    (out) => selectionAutoscrollCodec.decode(out.cast<UnsignedInt>().value),
  )!;

  /// What the current click sequence selects (from [behaviors] and
  /// [clickCount]).
  SelectionGestureBehavior get behavior => _read(
    'behavior',
    GhosttySelectionGestureData.GHOSTTY_SELECTION_GESTURE_DATA_BEHAVIOR,
    sizeOf<UnsignedInt>(),
    (out) =>
        selectionGestureBehaviorCodec.decode(out.cast<UnsignedInt>().value),
  )!;

  /// The cell of the press that started the current click, or `null` when
  /// there is none (no click, or the cell left the active screen). A
  /// borrowed [GridRef], valid until the terminal changes.
  GridRef? get anchor => _read(
    'anchor',
    GhosttySelectionGestureData.GHOSTTY_SELECTION_GESTURE_DATA_ANCHOR,
    sizeOf<GhosttyGridRef>(),
    (out) => gridRefFromNative(_terminalHandle, out.cast<GhosttyGridRef>().ref),
  );

  /// Frees the native gesture. Safe to call more than once.
  void dispose() => _handle.dispose();

  /// Creates an event of [type], lets [configure] set its options, applies
  /// it and frees it. [scrolls] marks events that scroll the viewport.
  VtSelection? _apply(
    String member,
    int type,
    void Function(
      Pointer<GhosttySelectionGestureEventImpl> event,
      NativeHandle<GhosttyTerminalImpl> terminal,
    )
    configure, {
    bool scrolls = false,
  }) {
    final gesture = _pointer(member);
    final terminal = _terminalHandle;
    final event = createNative<GhosttySelectionGestureEventImpl>(
      'ghostty_selection_gesture_event_new',
      (out) => ghostty_selection_gesture_event_new(nullptr, out, type),
    );
    try {
      configure(event, terminal);
      return withScratch(sizeOf<GhosttySelection>(), (block) {
        final out = block.cast<GhosttySelection>();
        final raw = ghostty_selection_gesture_event(
          gesture,
          terminal.pointer,
          event,
          out,
        );
        if (scrolls) terminal.bumpEpoch();
        return checkResultHasValue(raw, 'ghostty_selection_gesture_event')
            ? selectionFromNative(terminal, out.ref)
            : null;
      });
    } finally {
      ghostty_selection_gesture_event_free(event);
    }
  }

  /// Reads gesture data [key] (for the getter [member]) into [size] bytes of scratch memory; `null`
  /// for `GHOSTTY_NO_VALUE`.
  R? _read<R extends Object>(
    String member,
    int key,
    int size,
    R Function(Pointer<Uint8> out) decode,
  ) {
    final gesture = _pointer(member);
    return withScratch(size, (out) {
      final hasValue = checkResultHasValue(
        ghostty_selection_gesture_get(
          gesture,
          _terminalHandle.pointer,
          key,
          out.cast(),
        ),
        'ghostty_selection_gesture_get',
      );
      return hasValue ? decode(out) : null;
    });
  }

  /// Sets the pointer's cell. An [at] outside its coordinate space throws
  /// when [required], else leaves the option unset ("off the grid").
  void _setRef(
    Pointer<GhosttySelectionGestureEventImpl> event,
    NativeHandle<GhosttyTerminalImpl> terminal,
    GridPoint at, {
    required bool required,
  }) => withScratch(sizeOf<GhosttyGridRef>(), (value) {
    if (resolveGridRef(terminal, at, value.cast<GhosttyGridRef>().ref)) {
      _set(event, _Opt.ref, value);
    } else if (required) {
      throw ArgumentError.value(at, 'at', 'is outside the terminal');
    }
  });

  void _setPosition(
    Pointer<GhosttySelectionGestureEventImpl> event,
    ({double x, double y})? position,
  ) {
    if (position == null) return;
    _withValue(event, _Opt.position, sizeOf<GhosttySurfacePosition>(), (value) {
      value.cast<GhosttySurfacePosition>().ref
        ..x = position.x
        ..y = position.y;
    });
  }

  void _setGeometry(
    Pointer<GhosttySelectionGestureEventImpl> event,
    SelectionGestureGeometry geometry,
  ) => _withValue(
    event,
    _Opt.geometry,
    sizeOf<GhosttySelectionGestureGeometry>(),
    (value) => value.cast<GhosttySelectionGestureGeometry>().ref
      ..columns = _uint32(geometry.columns, 'geometry.columns', min: 1)
      ..cell_width = _uint32(geometry.cellWidth, 'geometry.cellWidth', min: 1)
      ..padding_left = _uint32(geometry.paddingLeft, 'geometry.paddingLeft')
      ..screen_height = _uint32(
        geometry.screenHeight,
        'geometry.screenHeight',
        min: 1,
      ),
  );

  void _setRectangle(
    Pointer<GhosttySelectionGestureEventImpl> event,
    bool rectangle,
  ) => _withValue(event, _Opt.rectangle, sizeOf<Bool>(), (value) {
    value.cast<Bool>().value = rectangle;
  });

  void _setBehaviors(
    Pointer<GhosttySelectionGestureEventImpl> event,
    SelectionGestureBehaviors table,
  ) => _withValue(
    event,
    _Opt.behaviors,
    sizeOf<GhosttySelectionGestureBehaviors>(),
    (value) => value.cast<GhosttySelectionGestureBehaviors>().ref
      ..single_click = selectionGestureBehaviorCodec.encode(table.singleClick)
      ..double_click = selectionGestureBehaviorCodec.encode(table.doubleClick)
      ..triple_click = selectionGestureBehaviorCodec.encode(table.tripleClick),
  );

  void _setWordBoundaries(Pointer<GhosttySelectionGestureEventImpl> event) {
    final codepoints = wordBoundaryCodepoints;
    if (codepoints == null) return;
    withCodepoints(codepoints, 'wordBoundaryCodepoints', (data, length) {
      _withValue(
        event,
        _Opt.wordBoundaryCodepoints,
        sizeOf<GhosttyCodepoints>(),
        (value) {
          // An empty set is NULL + 0 for this option (the selection
          // functions use a valid pointer instead).
          value.cast<GhosttyCodepoints>().ref
            ..ptr = length == 0 ? nullptr : data
            ..len = length;
        },
      );
    });
  }

  void _setUint64(
    Pointer<GhosttySelectionGestureEventImpl> event,
    int option,
    int value,
  ) => _withValue(event, option, sizeOf<Uint64>(), (out) {
    out.cast<Uint64>().value = value;
  });

  /// Sets event [option] to a value of [size] bytes that [write] stores in
  /// zeroed scratch memory.
  static void _withValue(
    Pointer<GhosttySelectionGestureEventImpl> event,
    int option,
    int size,
    void Function(Pointer<Uint8> value) write,
  ) => withScratch(size, (value) {
    write(value);
    _set(event, option, value);
  });

  static void _set(
    Pointer<GhosttySelectionGestureEventImpl> event,
    int option,
    Pointer<Uint8> value,
  ) => checkResult(
    ghostty_selection_gesture_event_set(event, option, value.cast()),
    'ghostty_selection_gesture_event_set',
  );

  /// The native gesture, after checking that it and its terminal are not
  /// disposed and the terminal is not running a callback.
  Pointer<GhosttySelectionGestureImpl> _pointer(String member) {
    final pointer = _handle.pointer;
    final terminal = _terminalHandle;
    terminal.checkNotDisposed();
    checkNotInTerminalCallback(terminal, 'SelectionGesture.$member');
    return pointer;
  }

  static int _nanoseconds(Duration duration) => duration.inMicroseconds * 1000;

  static int _uint32(int value, String name, {int min = 0}) =>
      RangeError.checkValueInInterval(value, min, 0xFFFFFFFF, name);
}

/// The `GhosttySelectionGestureEventOption` values used here.
abstract final class _Opt {
  static const ref = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF;
  static const position = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION;
  static const repeatDistance = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE;
  static const timeNs = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS;
  static const repeatIntervalNs = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS;
  static const wordBoundaryCodepoints = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_WORD_BOUNDARY_CODEPOINTS;
  static const behaviors = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS;
  static const rectangle = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE;
  static const geometry = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY;
  static const viewport = GhosttySelectionGestureEventOption
      .GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT;
}
