/// @docImport '../view/terminal_view.dart';
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../theme/terminal_theme.dart';
import 'controller_internals.dart';

/// Called with bytes the terminal sends to the program: encoded keys and
/// text, mouse reports, pastes, and the terminal's replies to queries.
typedef VtTerminalOutputCallback = void Function(Uint8List data);

/// Called after the terminal grid changed size: [cols] × [rows] cells,
/// [pixelWidth] × [pixelHeight] device pixels in total (0 when the cell
/// size is not known yet). Same shape as xterm's `onResize`.
typedef VtTerminalResizeCallback =
    void Function(int cols, int rows, int pixelWidth, int pixelHeight);

/// The model behind a [VtTerminalView]: owns a libghostty-vt [VtTerminal]
/// and everything the view needs to draw it and to send input to it.
///
/// The controller is **pty-agnostic**. Feed it the program's output with
/// [write] or [writeBytes], and forward [onOutput] to the program's input
/// (a pty, a socket, an SSH channel). Resize the program's pty from
/// [onResize]:
///
/// ```dart
/// final controller = VtTerminalController(
///   onOutput: (bytes) => pty.write(bytes),
///   onResize: (cols, rows, pixelWidth, pixelHeight) =>
///       pty.resize(rows, cols),
/// );
/// pty.output.listen(controller.writeBytes);
/// // ...
/// controller.dispose();
/// ```
///
/// ## Callbacks
///
/// [onOutput], [onBell] and [onTitleChanged] are never called while the
/// terminal is parsing: events raised during [writeBytes] are queued and
/// delivered, in order, after the terminal returns. A callback may
/// therefore call [write] again (a local echo, for example); what that
/// raises is delivered after the events already queued.
///
/// ## Notifications
///
/// Listeners are notified synchronously, at most once per call, after any
/// call that may have changed what the view shows: [write], [writeBytes],
/// [resize], [paste], [scrollViewport], [selection] changes, a [theme]
/// change, input that scrolled the viewport back to the bottom, a title
/// change, the end of a render hold, and a Kitty graphics animation moving
/// to its next frame (the controller plays animations on a single timer
/// that runs only while one is playing). Listeners must be cheap; the view
/// only schedules a repaint. When the view resizes the terminal during
/// layout, [onResize] and the notification come after that frame instead.
///
/// ## Synchronized output
///
/// While a program holds rendering (DEC mode 2026) the view keeps showing
/// the last frame. The controller ends a hold that lasts longer than
/// [renderHoldTimeout] (a program that crashed mid-frame), as Ghostty does.
///
/// ## Ownership
///
/// One controller drives at most one [VtTerminalView] at a time (they share
/// one render state). Call [dispose] when done: it frees the terminal and
/// every native object the controller created. It is safe to call more
/// than once. Every other member throws [StateError] after [dispose].
class VtTerminalController extends ChangeNotifier {
  /// Creates a controller with a [cols] × [rows] terminal (each 1–65535).
  ///
  /// [scrollbackMaxBytes] limits the scrollback memory
  /// ([defaultScrollbackMaxBytes] unless given; `null` means no limit) and
  /// [scrollbackMaxLines] the number of scrollback lines (`null`, the
  /// default, means no line limit); the first limit reached applies.
  /// [theme] gives the terminal its default colours and palette.
  ///
  /// [imageStorageLimit] caps the memory of Kitty graphics images, in
  /// bytes per screen (primary and alternate have one storage each):
  /// `null`, the default, keeps libghostty-vt's limit (10 MB), and 0
  /// disables the Kitty graphics protocol entirely (the terminal no longer
  /// answers its support query, so programs fall back to text). It is
  /// ignored when the loaded library lacks Kitty graphics
  /// ([VtFeature.kittyGraphics]). The view draws the stored images; their
  /// textures are bounded by this limit, not by
  /// `VtTerminalView.cacheBudget`.
  ///
  /// Throws [RangeError] for an invalid size or a negative limit,
  /// [ArgumentError] for [OptionAsAlt.unknown], and the errors of
  /// [VtTerminal.new] if the native library cannot be loaded.
  VtTerminalController({
    int cols = 80,
    int rows = 24,
    int? scrollbackMaxBytes = defaultScrollbackMaxBytes,
    int? scrollbackMaxLines,
    int? imageStorageLimit,
    VtTerminalTheme theme = VtTerminalTheme.defaultTheme,
    this.onOutput,
    this.onResize,
    this.onBell,
    this.onTitleChanged,
    this.scrollToBottomOnInput = true,
    OptionAsAlt macosOptionAsAlt = OptionAsAlt.none,
  }) : terminal = VtTerminal(cols: cols, rows: rows),
       _theme = theme,
       _macosOptionAsAlt = _checkedOptionAsAlt(macosOptionAsAlt) {
    RenderState? renderState;
    KeyEncoder? keyEncoder;
    MouseEncoder? mouseEncoder;
    try {
      terminal
        ..scrollbackMaxBytes = scrollbackMaxBytes
        ..scrollbackMaxLines = scrollbackMaxLines;
      if (imageStorageLimit != null) {
        RangeError.checkNotNegative(imageStorageLimit, 'imageStorageLimit');
        if (_kittyGraphics) terminal.kittyImageStorageLimit = imageStorageLimit;
      }
      _renderState = renderState = RenderState();
      _keyEncoder = keyEncoder = KeyEncoder();
      _mouseEncoder = mouseEncoder = MouseEncoder();
      _installEffects();
      _pushTheme(theme);
    } catch (_) {
      mouseEncoder?.dispose();
      keyEncoder?.dispose();
      renderState?.dispose();
      terminal.dispose();
      rethrow;
    }
    bindControllerInternals(this, _internalsRef = _Internals(this));
    _animationEpoch = debugAnimationNow();
  }

  /// The scrollback memory limit a controller starts with: 10 MiB.
  ///
  /// The library's own default is a single history page (about 400 KB);
  /// Ghostty's app uses 50 MB. A widget may have several terminals open
  /// (tabs), so this sits in between: tens of thousands of lines.
  static const defaultScrollbackMaxBytes = 10 * 1024 * 1024;

  /// The longest a render hold (synchronized output, DEC mode 2026) may
  /// last before the controller ends it: 1 second, Ghostty's
  /// `sync_reset_ms` (`src/termio/Thread.zig` at libghostty-vt 1.0.0).
  static const renderHoldTimeout = Duration(seconds: 1);

  /// The libghostty-vt terminal this controller owns.
  ///
  /// Use it to read state the controller does not wrap (grid cells, modes,
  /// cursor, colours, Kitty graphics...) and to set options. Do not
  /// [VtTerminal.dispose] it, do not call [VtTerminal.write] on it (use
  /// [writeBytes], so output and notifications are delivered), and do not
  /// replace the `onWritePty`, `onBell`, `onTitleChanged` or
  /// `onRenderHold` callbacks: the controller installs them.
  final VtTerminal terminal;

  late final RenderState _renderState;
  late final KeyEncoder _keyEncoder;
  late final MouseEncoder _mouseEncoder;
  TerminalFormatter? _formatter;
  final _latchedModifiers = ValueNotifier(KeyModifiers.none);

  /// Receives the bytes for the program's input; see
  /// [VtTerminalOutputCallback]. Without it, output is discarded.
  VtTerminalOutputCallback? onOutput;

  /// Called after [resize] changed the grid; see [VtTerminalResizeCallback].
  VtTerminalResizeCallback? onResize;

  /// Called when the program rings the bell (BEL).
  VoidCallback? onBell;

  /// Called with the new window title when the program sets it (OSC 0/2).
  ValueChanged<String>? onTitleChanged;

  /// Whether user input ([sendKey], [sendText], [paste]) that produces
  /// output scrolls the viewport back to the bottom. Key releases and
  /// lone modifier keys never scroll. Defaults to `true`.
  bool scrollToBottomOnInput;

  VtTerminalTheme _theme;
  OptionAsAlt _macosOptionAsAlt;
  bool _disposed = false;
  bool _renderHeld = false;
  Timer? _renderHoldTimer;
  bool _resizeDeliveryScheduled = false;

  /// How deep we are inside calls into the terminal; events raised while
  /// it is above zero, or while [_flushing], are queued in [_pending].
  int _depth = 0;
  bool _flushing = false;
  final _pending = ListQueue<void Function()>();

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// The number of columns of the terminal grid.
  int get cols => _checked.cols;

  /// The number of rows of the terminal grid.
  int get rows => _checked.rows;

  /// The window title the program set (OSC 0/2), or `''`.
  String get title => _checked.title;

  /// The colours of the terminal. Setting a different theme pushes its
  /// colours into the terminal at once (see [VtTerminalTheme]) and notifies
  /// listeners.
  ///
  /// The notification is synchronous, like every other one, except while a
  /// frame is being built, laid out or painted for a view of this
  /// controller: then it is delivered once after that frame, so listeners
  /// may call `setState`. Still, prefer setting it from `initState`,
  /// `didUpdateWidget` (only when it changed) or an event handler, never
  /// from a `build` method.
  VtTerminalTheme get theme {
    _checkNotDisposed();
    return _theme;
  }

  set theme(VtTerminalTheme value) {
    _checkNotDisposed();
    if (value == _theme) return;
    _theme = value;
    _guard(() => _pushTheme(value));
    if (_internalsUsedByWidgets &&
        SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
      _notifyAfterFrame();
    } else {
      notifyListeners();
    }
  }

  bool _themeNotificationScheduled = false;
  _Internals? _internalsRef;

  bool get _internalsUsedByWidgets => _internalsRef?.usedByWidgets ?? false;

  /// Notifies once after the current frame (coalesced).
  void _notifyAfterFrame() {
    if (_themeNotificationScheduled) return;
    _themeNotificationScheduled = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _themeNotificationScheduled = false;
        _notify();
      }, debugLabel: 'VtTerminalController.theme')
      ..ensureVisualUpdate();
  }

  /// Whether the macOS Option key acts as Alt for [sendKey] (it only has
  /// an effect on macOS). Defaults to [OptionAsAlt.none];
  /// [OptionAsAlt.unknown] is rejected with [ArgumentError].
  OptionAsAlt get macosOptionAsAlt {
    _checkNotDisposed();
    return _macosOptionAsAlt;
  }

  set macosOptionAsAlt(OptionAsAlt value) {
    _checkNotDisposed();
    _macosOptionAsAlt = _checkedOptionAsAlt(value);
  }

  static OptionAsAlt _checkedOptionAsAlt(OptionAsAlt value) {
    if (value == OptionAsAlt.unknown) {
      throw ArgumentError.value(value, 'macosOptionAsAlt');
    }
    return value;
  }

  // ---------------------------------------------------------------------
  // Program output in
  // ---------------------------------------------------------------------

  /// Feeds [data], the program's output, to the terminal as UTF-8.
  void write(String data) => writeBytes(utf8.encode(data));

  /// Feeds [data], the program's output, to the terminal.
  ///
  /// Replies the terminal generates (to cursor position or device
  /// attribute queries, for example) reach [onOutput] after this call
  /// returns, then listeners are notified.
  void writeBytes(Uint8List data) {
    _checkNotDisposed();
    if (data.isEmpty) return;
    _guard(() => terminal.write(data));
    _tickAnimations();
    _notify();
  }

  // ---------------------------------------------------------------------
  // Kitty graphics animations (ADR 0014)
  // ---------------------------------------------------------------------

  /// Whether the loaded library implements Kitty graphics.
  static final bool _kittyGraphics = libghosttyVtBuildInfo.supports(
    VtFeature.kittyGraphics,
  );

  /// [debugAnimationNow] when the controller was created: animation time
  /// is measured from it, so it starts at 0 and only moves forward.
  late final Duration _animationEpoch;

  /// The single timer for the next due animation frame, if any.
  Timer? _animationTimer;

  /// The animation time ([_animationEpoch]-relative milliseconds) the
  /// pending [_animationTimer] fires at.
  int? _animationDue;

  /// Advances the playing Kitty animations to now and schedules the next
  /// frame. Cheap while the storage was never used (one native read of
  /// its generation); does nothing without Kitty graphics. Returns whether
  /// it ticked. Never called from inside a terminal callback: only after
  /// [writeBytes] returned from the terminal and from the timer.
  bool _tickAnimations() {
    if (!_kittyGraphics || _disposed) return false;
    if (terminal.kittyGraphicsGeneration == 0 && _animationDue == null) {
      return false;
    }
    final now = (debugAnimationNow() - _animationEpoch).inMilliseconds;
    final due = _guard(() => terminal.tickKittyAnimations(now < 0 ? 0 : now));
    if (due != _animationDue) {
      _animationTimer?.cancel();
      _animationTimer = null;
      _animationDue = due;
      if (due != null) {
        // A due time in the past (a late tick) fires on the next turn.
        final wait = due - now;
        _animationTimer = Timer(
          Duration(milliseconds: wait < 0 ? 0 : wait),
          _onAnimationTimer,
        );
      }
    }
    return true;
  }

  void _onAnimationTimer() {
    _animationTimer = null;
    _animationDue = null;
    // A frame was due: the tick moved at least one image to its next
    // frame (a new image generation), so the view must repaint.
    if (_tickAnimations()) _notify();
  }

  // ---------------------------------------------------------------------
  // Size
  // ---------------------------------------------------------------------

  /// Resizes the grid to [cols] × [rows] cells (each 1–65535) of
  /// [cellWidthPx] × [cellHeightPx] device pixels, then calls [onResize]
  /// and notifies listeners. Omitted cell sizes keep the previous ones.
  ///
  /// Does nothing if nothing changes. The view resizes the terminal itself
  /// (deferring the callback and the notification past the frame); call
  /// this only without a view, and never during build or layout.
  void resize(int cols, int rows, {int? cellWidthPx, int? cellHeightPx}) {
    if (!_resizeTerminal(cols, rows, cellWidthPx, cellHeightPx)) return;
    _deliverResize();
  }

  /// Resizes the terminal at once and returns whether anything changed.
  bool _resizeTerminal(
    int cols,
    int rows,
    int? cellWidthPx,
    int? cellHeightPx,
  ) {
    final vt = _checked;
    final widthPx = cellWidthPx == null ? null : cellWidthPx * cols;
    final heightPx = cellHeightPx == null ? null : cellHeightPx * rows;
    if (cols == vt.cols &&
        rows == vt.rows &&
        (widthPx == null || widthPx == vt.widthPx) &&
        (heightPx == null || heightPx == vt.heightPx)) {
      return false;
    }
    _guard(
      () => vt.resize(
        cols,
        rows,
        cellWidthPx: cellWidthPx,
        cellHeightPx: cellHeightPx,
      ),
    );
    return true;
  }

  void _deliverResize() {
    if (_disposed) return;
    onResize?.call(
      terminal.cols,
      terminal.rows,
      terminal.widthPx,
      terminal.heightPx,
    );
    _notify();
  }

  /// [resize] for the view's layout: the terminal changes now (so the
  /// frame being laid out draws the new grid), while [onResize] and the
  /// notification run once after the frame, where listeners may rebuild.
  void _resizeDuringLayout(
    int cols,
    int rows,
    int cellWidthPx,
    int cellHeightPx,
  ) {
    if (!_resizeTerminal(cols, rows, cellWidthPx, cellHeightPx)) return;
    if (_resizeDeliveryScheduled) return;
    _resizeDeliveryScheduled = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _resizeDeliveryScheduled = false;
        _deliverResize();
      }, debugLabel: 'VtTerminalController.resize')
      ..ensureVisualUpdate();
  }

  // ---------------------------------------------------------------------
  // User input out
  // ---------------------------------------------------------------------

  /// Encodes [event] for the terminal's current modes (legacy, or the Kitty
  /// keyboard protocol when the program enabled it) and sends it to
  /// [onOutput].
  ///
  /// Returns `true` if bytes were sent; `false` for events that encode to
  /// nothing (a lone modifier in legacy mode, a release without Kitty
  /// release reporting).
  bool sendKey(VtKeyEvent event) {
    final vt = _checked;
    // set_from_terminal resets Option-as-Alt (key/encoder.h), so set it
    // again for every event.
    _keyEncoder
      ..setFromTerminal(vt)
      ..configure(macosOptionAsAlt: _macosOptionAsAlt);
    final bytes = _keyEncoder.encode(event);
    if (bytes.isEmpty) return false;
    final scrolls =
        event.action != KeyAction.release && !_modifierKeys.contains(event.key);
    _sendUserInput(bytes, scroll: scrolls);
    return true;
  }

  static const _modifierKeys = {
    VtKey.shiftLeft,
    VtKey.shiftRight,
    VtKey.controlLeft,
    VtKey.controlRight,
    VtKey.altLeft,
    VtKey.altRight,
    VtKey.metaLeft,
    VtKey.metaRight,
    VtKey.capsLock,
  };

  /// Sends [text] to the program as UTF-8, unchanged: committed IME or
  /// soft-keyboard text. Does nothing for empty text.
  void sendText(String text) {
    _checkNotDisposed();
    if (text.isEmpty) return;
    _sendUserInput(utf8.encode(text), scroll: true);
  }

  /// Pastes [text] the way the program asked for (bracketed paste, mode
  /// 2004, when enabled) and sends it to [onOutput].
  ///
  /// Returns [PasteResult.rejected], sending nothing, when the text could
  /// run commands by itself (for example it contains a newline and the
  /// program did not enable bracketed paste) and [allowUnsafe] is `false`:
  /// ask the user, then paste again with `allowUnsafe: true`.
  PasteResult paste(String text, {bool allowUnsafe = false}) {
    final vt = _checked;
    final result = _guard(() {
      final result = vt.pasteText(text, allowUnsafe: allowUnsafe);
      if (result == PasteResult.pasted) _scrollToBottomForInput();
      return result;
    });
    _notify();
    return result;
  }

  /// Encodes [event] as a mouse report for the program's tracking mode and
  /// format, and sends it to [onOutput]. Returns `true` if bytes were sent
  /// (`false` while the program does not track the mouse).
  ///
  /// Positions are device pixels from the top-left of the view, padding
  /// included; the view keeps the encoder's geometry up to date.
  bool sendMouse(VtMouseEvent event) {
    final vt = _checked;
    _mouseEncoder.setFromTerminal(vt);
    final bytes = _mouseEncoder.encode(event);
    if (bytes.isEmpty) return false;
    _emit(bytes);
    return true;
  }

  /// Reports that the view gained ([focused] `true`) or lost focus, if the
  /// program asked for focus events (DEC mode 1004); otherwise does
  /// nothing.
  void sendFocus({required bool focused}) {
    final vt = _checked;
    if (!vt.isModeEnabled(TerminalMode.focusEvent)) return;
    _emit(encodeFocusEvent(focused ? VtFocusEvent.gained : VtFocusEvent.lost));
  }

  // ---------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------

  /// The current selection, or `null`. Setting it highlights a selection
  /// computed by the terminal's `select…` methods (see
  /// [VtTerminalSelection]) and notifies listeners.
  ///
  /// Reading returns a borrowed snapshot: it goes stale on the next write,
  /// scroll or selection change, and assigning a stale one throws
  /// [StateError]. Read it again instead of keeping it.
  VtSelection? get selection => _checked.selection;

  set selection(VtSelection? value) {
    final vt = _checked;
    _guard(() => vt.selection = value);
    _notify();
  }

  /// Clears the selection.
  void clearSelection() => selection = null;

  /// Selects everything on the active screen, scrollback included (nothing
  /// when the screen is blank).
  void selectAll() => selection = _checked.selectAll();

  // ---------------------------------------------------------------------
  // Highlights
  // ---------------------------------------------------------------------

  final _highlights = <VtTerminalHighlight>[];

  /// Highlights the cells from [start] to [end], both inclusive, with
  /// [color], painted over the text; for search results, for example.
  ///
  /// [start] and [end] may be in any [PointSpace] and in either order;
  /// the range runs in line order between them, like a non-rectangular
  /// [VtTerminalSelection.selectRange]. Both ends are tracked, so the
  /// highlight follows its text as output scrolls it, until the text
  /// leaves the scrollback. Every view of this controller paints each
  /// live highlight, in creation order, over whole cells (with [color]'s
  /// alpha) after the text and the cursor. A highlight is painted only
  /// while the screen it was made on (primary or alternate) is active.
  ///
  /// The returned [VtTerminalHighlight] belongs to this controller:
  /// [VtTerminalHighlight.dispose] removes it, and [dispose] removes
  /// every highlight. Adding one notifies listeners.
  ///
  /// ```dart
  /// final hit = controller.addHighlight(
  ///   const GridPoint.screen(4, 120),
  ///   const GridPoint.screen(9, 120),
  ///   color: const Color(0x80FFFF00),
  /// );
  /// // later
  /// hit.dispose();
  /// ```
  ///
  /// Throws [RangeError] when a point is outside the grid,
  /// [ArgumentError] for [PointSpace.unknown], and [StateError] after
  /// [dispose].
  VtTerminalHighlight addHighlight(
    GridPoint start,
    GridPoint end, {
    required Color color,
  }) {
    final vt = _checked;
    final highlight = _guard(() {
      final from = vt.trackGridRef(start);
      if (from == null) {
        throw RangeError('start $start is outside the terminal grid');
      }
      final to = vt.trackGridRef(end);
      if (to == null) {
        from.dispose();
        throw RangeError('end $end is outside the terminal grid');
      }
      final a = from.pointIn(PointSpace.screen);
      final b = to.pointIn(PointSpace.screen);
      final reversed =
          a != null && b != null && (b.y < a.y || (b.y == a.y && b.x < a.x));
      return VtTerminalHighlight._(
        this,
        color,
        reversed ? to : from,
        reversed ? from : to,
        vt.activeScreen,
      );
    });
    _highlights.add(highlight);
    _notify();
    return highlight;
  }

  /// The live highlights, in creation order (see [addHighlight]).
  /// Unmodifiable; a new list after every change.
  List<VtTerminalHighlight> get highlights {
    _checkNotDisposed();
    return List.unmodifiable(_highlights);
  }

  void _removeHighlight(VtTerminalHighlight highlight) {
    if (_highlights.remove(highlight)) _notify();
  }

  /// The live highlights on the active screen with both ends known, as
  /// screen points with `start` before `end`, in creation order.
  List<({Color color, GridPoint start, GridPoint end})> _screenHighlights() {
    if (_highlights.isEmpty || _disposed) return const [];
    final screen = terminal.activeScreen;
    return [
      for (final highlight in _highlights)
        if (highlight._screen == screen)
          if (highlight.start case final start?)
            if (highlight.end case final end?)
              (color: highlight.color, start: start, end: end),
    ];
  }

  /// The selected text as plain text, soft-wrapped lines joined, or `null`
  /// when nothing is selected.
  String? get selectedText {
    final vt = _checked;
    final current = vt.selection;
    if (current == null) return null;
    final formatter = _formatter ??= TerminalFormatter(vt, unwrap: true);
    return formatter.formatText(selection: current);
  }

  // ---------------------------------------------------------------------
  // Viewport and modes
  // ---------------------------------------------------------------------

  /// The viewport's position in the scrollback, for a scrollbar. Poll it
  /// when notified; compare with `==`.
  ViewportScrollbar get scrollbar => _checked.scrollbar;

  /// Moves the viewport (see [ViewportScroll]) and notifies listeners.
  void scrollViewport(ViewportScroll target) {
    final vt = _checked;
    _guard(() => vt.scrollViewport(target));
    _notify();
  }

  /// Whether the alternate screen (full-screen programs) is active. It has
  /// no scrollback.
  bool get isAlternateScreen =>
      _checked.activeScreen == TerminalScreen.alternate;

  /// Whether the program tracks the mouse (any of DEC modes 9, 1000, 1002,
  /// 1003).
  bool get isMouseTracking => _checked.isMouseTracking;

  /// Whether [mode] is set.
  bool isModeEnabled(TerminalMode mode) => _checked.isModeEnabled(mode);

  /// The mouse pointer shape the program asked for (OSC 22).
  MouseShape get mouseShape => _checked.mouseShape;

  // ---------------------------------------------------------------------
  // Lifetime
  // ---------------------------------------------------------------------

  /// Frees the terminal and every native object the controller created,
  /// and drops all listeners. Safe to call more than once.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending.clear();
    for (final highlight in List.of(_highlights)) {
      highlight.dispose();
    }
    _renderHoldTimer?.cancel();
    _animationTimer?.cancel();
    _animationTimer = null;
    _formatter?.dispose();
    _mouseEncoder.dispose();
    _keyEncoder.dispose();
    _renderState.dispose();
    terminal.dispose();
    _latchedModifiers.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  VtTerminal get _checked {
    _checkNotDisposed();
    return terminal;
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('VtTerminalController has been disposed');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Runs [action], which calls into the terminal, and delivers the events
  /// it raised once the outermost call returns.
  T _guard<T>(T Function() action) {
    _depth++;
    try {
      return action();
    } finally {
      _depth--;
      if (_depth == 0) _flush();
    }
  }

  /// Delivers the queued events in order. A callback that calls back into
  /// the controller only queues more events, which this loop delivers
  /// after the ones already queued. If a callback throws, the events after
  /// it stay queued for the next flush.
  void _flush() {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_pending.isNotEmpty && !_disposed) {
        _pending.removeFirst()();
      }
    } finally {
      _flushing = false;
    }
  }

  /// Delivers [event] now, or after the current terminal call or flush.
  void _deliver(void Function() event) {
    if (_depth > 0 || _flushing) {
      _pending.add(event);
    } else {
      event();
    }
  }

  void _emit(Uint8List bytes) => _deliver(() => onOutput?.call(bytes));

  void _sendUserInput(Uint8List bytes, {required bool scroll}) {
    final scrolled = scroll && _scrollToBottomForInput();
    _emit(bytes);
    if (scrolled) _notify();
  }

  /// Scrolls to the bottom if [scrollToBottomOnInput] asks for it; returns
  /// whether the viewport moved. Does not notify.
  bool _scrollToBottomForInput() {
    if (!scrollToBottomOnInput || terminal.scrollbar.isAtBottom) return false;
    _guard(() => terminal.scrollViewport(const ViewportScroll.bottom()));
    return true;
  }

  void _installEffects() {
    // A NativeCallable is a GC root: capture the controller weakly so a
    // forgotten controller can still be collected and finalized.
    final self = WeakReference(this);
    terminal
      ..onWritePty = (data) {
        // The library reuses its buffer after the callback returns.
        final copy = Uint8List.fromList(data);
        self.target?._emit(copy);
      }
      ..onBell = () {
        self.target?._deliver(() => self.target?.onBell?.call());
      }
      ..onTitleChanged = (title) {
        self.target?._deliver(() {
          final controller = self.target;
          if (controller == null || controller._disposed) return;
          controller.onTitleChanged?.call(title);
          controller._notify();
        });
      }
      ..onRenderHold = (held) => self.target?._renderHoldChanged(held);
  }

  void _renderHoldChanged(bool held) {
    _renderHeld = held;
    _renderHoldTimer?.cancel();
    _renderHoldTimer = null;
    if (held) {
      _renderHoldTimer = Timer(renderHoldTimeout, _renderHoldExpired);
    } else {
      _deliver(_notify);
    }
  }

  /// Ends a hold the program never ended, as Ghostty's
  /// `resetSynchronizedOutput` does: clearing the mode (which raises no
  /// callback) lets the next `CSI ? 2026 h` start a new hold.
  void _renderHoldExpired() {
    _renderHoldTimer = null;
    if (_disposed || !_renderHeld) return;
    _renderHeld = false;
    _guard(
      () => terminal.setMode(TerminalMode.synchronizedOutput, enabled: false),
    );
    _notify();
  }

  void _pushTheme(VtTerminalTheme theme) {
    terminal
      ..colorForegroundDefault = VtTerminalTheme.rgbOf(theme.foreground)
      ..colorBackgroundDefault = VtTerminalTheme.rgbOf(theme.background)
      ..colorCursorDefault = VtTerminalTheme.rgbOf(theme.cursor)
      ..colorPaletteDefault = theme.toPalette();
  }
}

final class _Internals implements ControllerInternals {
  _Internals(this._controller);

  final VtTerminalController _controller;

  @override
  RenderState get renderState => _controller._renderState;

  @override
  MouseEncoder get mouseEncoder => _controller._mouseEncoder;

  @override
  bool get isRenderHeld => _controller._renderHeld;

  @override
  ValueNotifier<KeyModifiers> get latchedModifiers =>
      _controller._latchedModifiers;

  @override
  Object? frameOwner;

  @override
  bool usedByWidgets = false;

  @override
  void resizeDuringLayout(
    int cols,
    int rows, {
    required int cellWidthPx,
    required int cellHeightPx,
  }) => _controller._resizeDuringLayout(cols, rows, cellWidthPx, cellHeightPx);

  @override
  List<({Color color, GridPoint start, GridPoint end})> screenHighlights() =>
      _controller._screenHighlights();

  @override
  bool get isAnimating => _controller._animationTimer != null;
}

/// A coloured range painted over a terminal's text; see
/// [VtTerminalController.addHighlight].
///
/// Its ends are tracked: they follow the text as output scrolls it. Once
/// the text leaves the scrollback, [start] or [end] becomes `null` and the
/// highlight is no longer painted (it stays in
/// [VtTerminalController.highlights] until disposed).
///
/// **Ownership:** it belongs to its [controller]. [dispose] removes it;
/// disposing the controller disposes it too.
final class VtTerminalHighlight {
  VtTerminalHighlight._(
    this.controller,
    this.color,
    this._start,
    this._end,
    this._screen,
  );

  /// The controller that paints this highlight.
  final VtTerminalController controller;

  /// The fill colour, painted with its alpha over the text.
  final Color color;

  final TrackedGridRef _start;
  final TrackedGridRef _end;

  /// The screen (primary or alternate) the highlight was made on.
  final TerminalScreen _screen;

  bool _disposed = false;

  /// The first highlighted cell now, in [PointSpace.screen]; `null` once
  /// its text left the scrollback, or after [dispose].
  GridPoint? get start => _point(_start);

  /// The last highlighted cell now (inclusive), in [PointSpace.screen];
  /// `null` once its text left the scrollback, or after [dispose].
  GridPoint? get end => _point(_end);

  GridPoint? _point(TrackedGridRef ref) {
    if (_disposed || controller.isDisposed) return null;
    return ref.pointIn(PointSpace.screen);
  }

  /// Whether [dispose] has been called, directly or by disposing the
  /// controller.
  bool get isDisposed => _disposed;

  /// Removes the highlight: views stop painting it and the controller's
  /// listeners are notified. Safe to call more than once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _start.dispose();
    _end.dispose();
    controller._removeHighlight(this);
  }

  @override
  String toString() => isDisposed
      ? 'VtTerminalHighlight(disposed)'
      : 'VtTerminalHighlight($start..$end, $color)';
}
