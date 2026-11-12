import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../controller/terminal_controller.dart';
import '../input/input_hooks.dart';
import '../input/keyboard/terminal_input_scope.dart';
import '../input/pointer/mouse_reports.dart';
import '../input/pointer/terminal_pointer_scope.dart';
import '../metrics/cell_metrics.dart';
import '../render/terminal_render.dart';
import '../render/text_rendering.dart';
import '../scroll/terminal_scrollbar.dart';
import '../seams/controller_seams.dart';
import '../seams/read_only_seams.dart';
import '../seams/terminal_geometry.dart';
import '../seams/terminal_seams.dart';
import 'terminal_semantics.dart';

/// A terminal view: draws a [VtTerminalController]'s terminal and sends the
/// user's keyboard, text, mouse and touch input to it.
///
/// Why this widget: libghostty-vt does the terminal work (parsing, screen,
/// key and mouse encoding, selection, scrollback), and the view only
/// re-records the rows that changed since the last frame, so a busy program
/// costs little UI time. It is pty-agnostic: connect the controller's
/// `onOutput` and `onResize` to your pty, socket or SSH channel.
///
/// ```dart
/// VtTerminalView(
///   controller: controller,
///   textStyle: const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 14),
///   autofocus: true,
/// )
/// ```
///
/// **Size.** The view fills the space its parent gives it (it needs
/// bounded constraints) and, with [autoResize], resizes the terminal to the
/// largest grid of whole cells that fits inside [padding]. The controller's
/// `onResize` then reports the new size, once, after the frame: forward it
/// to the program's pty.
///
/// **Font.** Cells are measured from [textStyle] (see
/// [VtCellMetrics.measure]); its `height` sets the line height. Flutter has
/// no portable "monospace" family, so pass a monospace font you bundle with
/// your app to get the same metrics on every platform; without one the
/// view uses [defaultTextStyle], which asks for the platform's monospace
/// fonts by name.
///
/// **Colours** come from the controller's `theme` (and the program's OSC
/// colour changes): set `controller.theme` to change them.
///
/// **Input.** Keys go through libghostty-vt's key encoder (legacy and
/// Kitty protocols). The default shortcuts never take keys from the shell:
/// Ctrl+V and Ctrl+A reach it, and copy and paste are Ctrl+Shift+C/V and
/// Ctrl/Shift+Insert, or Cmd+C/V on Apple platforms. Text from IMEs and
/// soft keyboards is sent as typed. A mouse press focuses the view; a tap
/// also shows the soft keyboard. While the program tracks the mouse,
/// presses, motion and the wheel are reported to it (hold Shift to select
/// instead).
///
/// **Hooks.** [onTerminalKey], [onTerminalText], [mouseReportFilter] and
/// [onTerminalMouse] let an app change what reaches the program (custom
/// key bindings, an input method of its own, mouse gating); [readOnly]
/// views never call them. They run synchronously on the UI isolate and
/// must not dispose [controller]. The view's actions also answer
/// [SelectAllTextIntent] (select everything, scrollback included), though
/// no default shortcut sends it.
///
/// **Accessibility.** While an accessibility service is running, the view
/// exposes its visible text as one semantics node labelled
/// [semanticsLabel]; [announceOutput] also reads new output aloud.
///
/// **Ownership.** The view never disposes [controller]; dispose it when you
/// are done with it. If it is disposed while the view is still mounted, the
/// view draws only the background and ignores input. Replacing [controller]
/// frees the old one for another view and moves the focus report (DEC 1004)
/// to the new one. One controller drives at most one view at a time (a
/// debug-mode assert checks it). A view gives the controller up as soon as
/// it leaves the tree, so a new view of the same controller may paint in
/// the same frame (an `IndexedStack` after a tab closes, a moved subtree).
/// For [focusNode], see its docs.
class VtTerminalView extends StatefulWidget {
  /// Creates a view of [controller].
  const VtTerminalView({
    super.key,
    required this.controller,
    this.textStyle,
    this.padding = EdgeInsets.zero,
    this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.shortcuts,
    this.onKeyEvent,
    this.textScaler,
    this.autoResize = true,
    this.cursorStyle,
    this.alwaysShowCursor = false,
    this.backgroundOpacity = 1.0,
    this.mouseCursor,
    this.keyboardType,
    this.keyboardAppearance = Brightness.dark,
    this.deleteDetection = true,
    this.onUnsafePaste,
    this.onTapUp,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.semanticsLabel = 'Terminal',
    this.announceOutput = false,
    this.textRendering = VtTextRendering.atlas,
    this.cacheBudget = defaultCacheBudget,
    this.onTerminalKey,
    this.onTerminalText,
    this.mouseReportFilter,
    this.onTerminalMouse,
    this.wordBoundaryCodepoints,
    this.rectangleSelection = false,
  }) : assert(
         backgroundOpacity >= 0 && backgroundOpacity <= 1,
         'backgroundOpacity must be between 0 and 1',
       ),
       assert(cacheBudget >= 0, 'cacheBudget must not be negative');

  /// The default [cacheBudget]: 16 MiB per view.
  static const defaultCacheBudget = RenderTerminal.defaultCacheBudget;

  /// The font the view uses when [textStyle] is `null`, and the base that
  /// a given [textStyle] is merged onto: 14 px, the generic `monospace`
  /// family (resolved by fontconfig on Linux and by Android), then common
  /// monospace fonts of each platform and the platforms' colour emoji fonts
  /// by name.
  static const defaultTextStyle = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: [
      'Menlo',
      'Monaco',
      'Consolas',
      'Cascadia Mono',
      'DejaVu Sans Mono',
      'Liberation Mono',
      'Noto Sans Mono',
      'Courier New',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Noto Color Emoji',
    ],
    fontSize: 14,
  );

  /// The terminal to show. The view does not dispose it (see "Ownership"
  /// above).
  final VtTerminalController controller;

  /// The font of the grid; use a monospace font. Flutter has no portable
  /// "monospace" family, so pass a font you bundle with your app for the
  /// same metrics everywhere. It is merged onto [defaultTextStyle]; its
  /// `height` sets the line height, while colours, `letterSpacing` and
  /// decorations are ignored (the terminal sets those).
  final TextStyle? textStyle;

  /// The space between the view's edges and the grid, filled with the
  /// terminal's background colour. Snapped to device pixels. (xterm also
  /// adds the `MediaQuery` padding; wrap the view in a `SafeArea` for
  /// that.)
  final EdgeInsets padding;

  /// The focus node for keyboard input. When `null` the view creates its
  /// own and disposes it; a node you pass stays yours to dispose. Swapping
  /// nodes while the view is focused moves the focus to the new node.
  final FocusNode? focusNode;

  /// Whether the view requests focus when first built.
  final bool autofocus;

  /// Whether user input is ignored (output is still shown and selection
  /// and copy still work). Mouse presses, motion and the wheel are not
  /// reported to the program either. Turning it on in the middle of a drag
  /// the program tracks drops that drag's release report.
  final bool readOnly;

  /// Whether to take input from hardware keys only, never opening a soft
  /// keyboard or an IME connection.
  final bool hardwareKeyboardOnly;

  /// The shortcut map, replacing the default one. `null` uses the default,
  /// which never takes Ctrl+V or Ctrl+A from the shell: copy and paste are
  /// Ctrl+Shift+C/V and Ctrl/Shift+Insert, or Cmd+C/V on Apple platforms.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Sees every key event before the terminal does; return
  /// [KeyEventResult.handled] to keep the terminal from receiving it.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// Scales the font; `null` follows the app's text scaling
  /// ([MediaQuery.textScalerOf]), as xterm's `textScaler` does.
  final TextScaler? textScaler;

  /// Whether the view resizes the terminal to fit its size. When `false`
  /// the grid keeps the controller's size (set it with
  /// [VtTerminalController.resize]) and is drawn from the top-left; with
  /// unbounded constraints the view then sizes itself to the grid.
  final bool autoResize;

  /// Draws the cursor in this shape instead of the one the program asks
  /// for (DECSCUSR); `null`, the default, follows the program, as Ghostty
  /// does (xterm forces a block unless told otherwise).
  final VtCursorStyle? cursorStyle;

  /// Draws the cursor even while the program hides it.
  final bool alwaysShowCursor;

  /// The opacity of the default background, from 0 (transparent, the app
  /// behind shows through) to 1. Cells with their own background colour
  /// stay opaque.
  final double backgroundOpacity;

  /// The mouse cursor over text; `null` is the I-beam
  /// ([SystemMouseCursors.text], xterm's default). The program's own
  /// pointer shape (OSC 22) and the arrow while it tracks the mouse still
  /// apply.
  final MouseCursor? mouseCursor;

  /// The soft keyboard type; `null` picks [TextInputType.visiblePassword]
  /// on Android (no suggestion strip, no autocorrect) and
  /// [TextInputType.text] elsewhere. (xterm's default is
  /// [TextInputType.emailAddress], which Android keyboards still decorate
  /// with suggestions.)
  final TextInputType? keyboardType;

  /// The soft keyboard's appearance (honoured on iOS). Dark by default, as
  /// in xterm: terminals are usually dark.
  final Brightness keyboardAppearance;

  /// Whether Backspace is detected on soft keyboards that send no key event
  /// for it (by keeping hidden text in the editing state). On by default
  /// (xterm: off) because Android soft keyboards, Gboard included, send no
  /// Backspace key event, so without it Backspace does nothing there.
  final bool deleteDetection;

  /// Asked before pasting text that could run commands by itself (it holds
  /// a newline and the program did not enable bracketed paste); complete
  /// with `true` to paste it anyway. Without it, such text is not pasted,
  /// as Ghostty's paste protection does: show a confirmation dialog here.
  final Future<bool> Function(String text)? onUnsafePaste;

  /// A primary click or tap that selected nothing and was not reported to
  /// the program, with its details (positions, device kind) and the
  /// viewport cell under it; xterm's `onTapUp` with a [GridPoint].
  final void Function(TapUpDetails details, GridPoint cell)? onTapUp;

  /// A secondary (right) mouse press not reported to the program, with its
  /// details and viewport cell; for a context menu at
  /// `details.globalPosition`, for example.
  final void Function(TapDownDetails details, GridPoint cell)?
  onSecondaryTapDown;

  /// The release of a press passed to [onSecondaryTapDown].
  final void Function(TapUpDetails details, GridPoint cell)? onSecondaryTapUp;

  /// The label of the view's semantics node.
  final String semanticsLabel;

  /// Whether new output is announced to screen readers, at most twice a
  /// second; long output is cut at the start, so the newest lines are
  /// read. Off by default: a busy program would flood the user.
  final bool announceOutput;

  /// How the grid's text is drawn: from a glyph atlas (the default, much
  /// cheaper for screens of new text) or as laid-out paragraphs. Choose
  /// [VtTextRendering.paragraphs] for exact paragraph shaping and
  /// coverage, or to rule out the atlas while debugging; see
  /// [VtTextRendering]. Changing it records the screen again.
  final VtTextRendering textRendering;

  /// About how many bytes of rendering caches the view keeps: the cached
  /// picture of each recently shown row, the glyph atlas images and laid
  /// out text. Together they stay within this budget, except the pictures
  /// of the rows on screen and the atlas images they draw, which are
  /// always kept; laid out text takes at most a quarter of it, and the
  /// glyph atlas is rebuilt from the screen once it outgrows half of it.
  ///
  /// The default, [defaultCacheBudget] (16 MiB), keeps about 1,000 rows of
  /// 200 heavily styled columns with the glyph atlas, enough for a program
  /// that switches between several full screens to redraw them without
  /// recording rows again. A larger budget helps an app that replays more
  /// screens than that; a smaller one suits many small views. Changing it
  /// keeps the caches and evicts what no longer fits. The caches are also
  /// released when the view is hidden for a few seconds, on memory
  /// pressure (all but what the screen shows), and when the font changes.
  final int cacheBudget;

  /// Called for every key press and repeat the view would encode or leave
  /// to the platform text input, after [onKeyEvent], the [shortcuts] and
  /// the IME (while it composes it owns the keys); never for key
  /// releases or lone modifier keys, nor for the repeats of a press the
  /// view encoded or left to the platform.
  ///
  /// - `null`: the view handles the key as usual.
  /// - a non-empty string: the key is consumed
  ///   ([KeyEventResult.handled]) and the string is sent to the program,
  ///   in order with text still arriving from the platform, as
  ///   [VtTerminalController.sendText] does (it scrolls to the bottom);
  ///   the key toolbar's latched modifiers are cleared.
  /// - an empty string: nothing is sent and the key is
  ///   [KeyEventResult.ignored], so it goes on to the rest of the app.
  ///
  /// Soft-keyboard Backspace (see [deleteDetection]) and the IME's
  /// newline, done, go, search and send actions come here too, as a
  /// synthesised [KeyDownEvent] of Backspace or Enter.
  ///
  /// ```dart
  /// onTerminalKey: (event, modifiers) =>
  ///     event.logicalKey == LogicalKeyboardKey.f1 ? 'help\r' : null,
  /// ```
  final VtTerminalKeyHook? onTerminalKey;

  /// Called with each committed text (IME commits, soft-keyboard input,
  /// the text of keys left to the platform) just before it is sent, in
  /// order; not for pastes. Return `null` to send the text, or the string
  /// to send instead (empty: nothing). A single character typed with
  /// latched toolbar modifiers is sent as a key and skips this hook.
  final VtTerminalTextHook? onTerminalText;

  /// Asked, while the program tracks the mouse and Shift is not held,
  /// whether to report each mouse press (and touch tap), wheel step and
  /// motion event; `null` reports them all. Not asked for the release of
  /// a reported press, so the program never sees a button stuck down.
  ///
  /// - `false` for a press: the whole gesture acts as if the program did
  ///   not track the mouse (it selects, and [onTapUp],
  ///   [onSecondaryTapDown] and [onSecondaryTapUp] are called).
  /// - `false` for a wheel step: it scrolls as if untracked (arrow keys
  ///   on the alternate screen with DEC 1007, otherwise the scrollback).
  /// - `false` for motion: that report is dropped.
  ///
  /// The event's `button` is the pressed button for a press,
  /// [MouseButton.four] to [MouseButton.seven] for wheel up, down, left
  /// and right, the held button for motion with a button down, and `null`
  /// for motion with none.
  final VtTerminalMouseFilter? mouseReportFilter;

  /// Called for every mouse report that passed [mouseReportFilter]
  /// (releases included) instead of encoding it, with the viewport cell
  /// under the pointer. Return `null` to encode and send the report as
  /// usual, or the string to send instead (empty: nothing).
  final VtTerminalMouseHook? onTerminalMouse;

  /// The codepoints that end a word when a double click or a long press
  /// selects one; `null` uses libghostty's default set (whitespace and
  /// common punctuation). For example `' ()[]{}'.runes.toList()`.
  final List<int>? wordBoundaryCodepoints;

  /// Whether a plain primary drag selects a rectangle (a block of
  /// columns). When `false` (the default) a drag selects running text,
  /// and a rectangle still needs Option on Apple platforms or Ctrl+Alt
  /// elsewhere.
  final bool rectangleSelection;

  @override
  State<VtTerminalView> createState() => VtTerminalViewState();
}

/// The state of a [VtTerminalView]: shows and hides the soft keyboard and
/// tells where the cursor is (for a popup next to it, for example).
///
/// Reach it with a `GlobalKey<VtTerminalViewState>` on the view:
///
/// ```dart
/// final viewKey = GlobalKey<VtTerminalViewState>();
/// // VtTerminalView(key: viewKey, controller: controller)
/// viewKey.currentState?.requestKeyboard();
/// ```
class VtTerminalViewState extends State<VtTerminalView> {
  final _inputKey = GlobalKey<TerminalInputScopeState>();
  late ControllerSeams _seams;
  ReadOnlyPointerSeams? _readOnlySeams;
  FocusNode? _ownFocusNode;
  bool _focused = false;

  /// Whether the IME is composing: hides the cursor without a rebuild (the
  /// composing state can change while the tree is built, when the input
  /// layer closes its connection from `didUpdateWidget`).
  final _composing = ValueNotifier<bool>(false);

  // The measured metrics and what they were measured with.
  VtCellMetrics? _metrics;
  TextStyle? _metricsStyle;
  double? _metricsDpr;
  TextScaler? _metricsScaler;

  // The grid the last layout used, to notice a resize from elsewhere.
  int _cols = 0;
  int _rows = 0;

  // The geometry of the last layout, for cursorRect.
  TerminalGeometry? _geometry;

  late final _selectAllAction = _SelectAllAction(this);

  // A touch press that may become a tap (shows the soft keyboard).
  int? _tapPointer;
  Offset? _tapDown;
  Duration _tapDownTime = Duration.zero;

  FocusNode get _focusNode => widget.focusNode ?? _ownFocusNode!;

  /// Focuses the view and shows the soft keyboard (opens the text input
  /// connection). A [VtTerminalView.hardwareKeyboardOnly] or
  /// [VtTerminalView.readOnly] view only takes the focus.
  void requestKeyboard() {
    final input = _inputKey.currentState;
    if (input == null) {
      _focusNode.requestFocus();
    } else {
      input.requestKeyboard();
    }
  }

  /// Hides the soft keyboard (closes the text input connection). The view
  /// keeps the focus, so hardware keys still work.
  void closeKeyboard() => _inputKey.currentState?.closeKeyboard();

  /// Whether the text input connection (soft keyboard, IME) is open.
  bool get hasInputConnection =>
      _inputKey.currentState?.hasTextInputConnection ?? false;

  /// The cursor's cell in the view's local coordinates (padding included),
  /// one cell wide; [Rect.zero] before the first layout, while the cursor
  /// is scrolled out of view, and once the controller is disposed.
  Rect get cursorRect {
    final geometry = _geometry;
    if (geometry == null) return Rect.zero;
    final cell = _seams.cursorViewportCell;
    if (cell == null || cell.x >= geometry.cols || cell.y >= geometry.rows) {
      return Rect.zero;
    }
    return geometry.cellRect(cell.x, cell.y);
  }

  /// [cursorRect] in global coordinates; [Rect.zero] when [cursorRect] is,
  /// or while the view is not laid out.
  Rect get globalCursorRect {
    final rect = cursorRect;
    final box = context.findRenderObject();
    if (rect == Rect.zero || box is! RenderBox || !box.hasSize) {
      return Rect.zero;
    }
    return rect.shift(box.localToGlobal(Offset.zero));
  }

  bool get _canSelectAll => !widget.controller.isDisposed;

  void _selectAll() {
    if (_canSelectAll) widget.controller.selectAll();
  }

  @override
  void initState() {
    super.initState();
    _seams = ControllerSeams(widget.controller)
      ..addListener(_onControllerChanged);
    if (widget.focusNode == null) _ownFocusNode = _createFocusNode();
    _focusNode.addListener(_onFocusChanged);
    _focused = _focusNode.hasFocus;
  }

  FocusNode _createFocusNode() => FocusNode(debugLabel: 'VtTerminalView');

  @override
  void didUpdateWidget(VtTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      final oldSeams = _seams
        ..removeListener(_onControllerChanged)
        ..release();
      _seams = ControllerSeams(widget.controller)
        ..addListener(_onControllerChanged);
      _readOnlySeams = null;
      // The focus moves from one program to the other (DEC 1004); the
      // seams ignore a disposed controller.
      if (_focusNode.hasFocus && !widget.readOnly) {
        oldSeams.sendFocus(focused: false);
        _seams.sendFocus(focused: true);
      }
    }
    if (oldWidget.focusNode != widget.focusNode) {
      final oldNode = (oldWidget.focusNode ?? _ownFocusNode)!;
      oldNode.removeListener(_onFocusChanged);
      if (widget.focusNode != null) {
        final replaced = _ownFocusNode;
        _ownFocusNode = null;
        // The child Focus widget still holds it until it rebuilds: dispose
        // it after this frame, never while it is attached.
        if (replaced != null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => replaced.dispose(),
          );
        }
      } else {
        _ownFocusNode ??= _createFocusNode();
      }
      // Keep the focus: the request waits until the new node is attached.
      if (oldNode.hasFocus) _focusNode.requestFocus();
      _focusNode.addListener(_onFocusChanged);
    }
  }

  // Frame ownership (one painting view per controller, ADR 0011) ends when
  // the view leaves the tree, not when it is disposed: dispose runs after
  // the frame, by which time a new view of the same controller (an
  // IndexedStack after a tab closes, a reparented subtree) may already
  // have painted. A deactivated view's render object is detached, so it
  // cannot paint; if the view is reinserted (GlobalKey), its next paint
  // takes ownership again.
  @override
  void deactivate() {
    _seams.release();
    super.deactivate();
  }

  @override
  void dispose() {
    _seams
      ..removeListener(_onControllerChanged)
      ..release();
    _focusNode.removeListener(_onFocusChanged);
    // Children unmount first, so the Focus widget has let go of it.
    _ownFocusNode?.dispose();
    _composing.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus != _focused) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  void _onComposingChanged(bool composing) => _composing.value = composing;

  /// Lays the view out again when the grid size changed elsewhere (a
  /// [VtTerminalController.resize] call): the geometry must follow it, or
  /// with [VtTerminalView.autoResize] the view fits the terminal again.
  ///
  /// It listens through the seams, not to the controller: reading the
  /// size costs two native calls, and while output floods the view the
  /// seams coalesce notifications instead of delivering one per write.
  void _onControllerChanged() {
    final controller = widget.controller;
    if (controller.isDisposed) return;
    if (controller.cols != _cols || controller.rows != _rows) {
      setState(() {});
    }
  }

  VtCellMetrics _measure(TextStyle style, double dpr, TextScaler scaler) {
    final cached = _metrics;
    if (cached != null &&
        style == _metricsStyle &&
        dpr == _metricsDpr &&
        scaler == _metricsScaler) {
      return cached;
    }
    _metricsStyle = style;
    _metricsDpr = dpr;
    _metricsScaler = scaler;
    return _metrics = VtCellMetrics.measure(
      style,
      devicePixelRatio: dpr,
      textScaler: scaler,
      lineHeight: style.height ?? 1.0,
    );
  }

  // A mouse press focuses the view (and opens the text input connection
  // for desktop IMEs); a touch or stylus tap also shows the soft keyboard.
  // A touch drag or long press does not, so scrolling and selecting never
  // pop the keyboard up.
  void _onPointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      requestKeyboard();
      return;
    }
    _tapPointer = event.pointer;
    _tapDown = event.position;
    _tapDownTime = event.timeStamp;
  }

  void _onPointerUp(PointerUpEvent event) {
    final down = _tapDown;
    final isTap =
        event.pointer == _tapPointer &&
        down != null &&
        (event.position - down).distance < kTouchSlop &&
        event.timeStamp - _tapDownTime < kLongPressTimeout;
    _tapPointer = null;
    _tapDown = null;
    if (isTap) requestKeyboard();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _tapPointer = null;
    _tapDown = null;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final dpr =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.maybeOf(context)?.devicePixelRatio ??
        1.0;
    final scaler =
        widget.textScaler ??
        MediaQuery.maybeTextScalerOf(context) ??
        TextScaler.noScaling;
    final style = VtTerminalView.defaultTextStyle.merge(widget.textStyle);
    final metrics = _measure(style, dpr, scaler);

    Widget view = LayoutBuilder(
      builder: (context, constraints) {
        final geometry = _layout(constraints, metrics);
        return SizedBox.fromSize(
          size: geometry.viewSize,
          child: _grid(geometry, style, scaler),
        );
      },
    );
    view = Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: view,
    );
    return TerminalSemantics(
      controller: controller,
      label: widget.semanticsLabel,
      readOnly: widget.readOnly,
      announceOutput: widget.announceOutput,
      onTap: requestKeyboard,
      child: view,
    );
  }

  /// The grid for [constraints], resizing the terminal to it with
  /// [VtTerminalView.autoResize] (during layout: the controller delivers
  /// `onResize` after the frame).
  TerminalGeometry _layout(BoxConstraints constraints, VtCellMetrics metrics) {
    final controller = widget.controller;
    final TerminalGeometry geometry;
    if (widget.autoResize) {
      geometry = TerminalGeometry.fit(
        constraints.biggest,
        metrics,
        padding: widget.padding,
      );
      _seams.resizeDuringLayout(geometry);
    } else {
      if (!controller.isDisposed) {
        _cols = controller.cols;
        _rows = controller.rows;
      }
      final cols = _cols == 0 ? 1 : _cols;
      final rows = _rows == 0 ? 1 : _rows;
      final natural = TerminalGeometry(
        metrics: metrics,
        cols: cols,
        rows: rows,
        padding: widget.padding,
      );
      geometry = TerminalGeometry(
        metrics: metrics,
        cols: cols,
        rows: rows,
        padding: widget.padding,
        viewSize: constraints.constrain(natural.viewSize),
      );
    }
    _cols = geometry.cols;
    _rows = geometry.rows;
    _geometry = geometry;
    return geometry;
  }

  /// The fill behind the IME preedit: the terminal's current background
  /// (the theme's, or the program's OSC 11 colour), read when the preedit
  /// is drawn, so it follows changes.
  Color? _composingBackground() {
    final controller = widget.controller;
    if (controller.isDisposed) return null;
    final background = controller.terminal.colorBackground;
    return background == null
        ? controller.theme.background.withValues(alpha: 1)
        : Color(0xFF000000 | background.value);
  }

  Widget _grid(TerminalGeometry geometry, TextStyle style, TextScaler scaler) {
    final controller = widget.controller;
    // A read-only view never reports the mouse or sends scroll keys: the
    // pointer layer sees a terminal that does not track the mouse.
    final readOnly = widget.readOnly
        ? (_readOnlySeams ??= ReadOnlyPointerSeams(_seams))
        : null;
    final TerminalPointerSink pointer = readOnly ?? _seams;
    final TerminalKeySink pointerKeys = readOnly ?? _seams;
    final TerminalTextSink pointerText = readOnly ?? _seams;
    final reports =
        widget.mouseReportFilter == null && widget.onTerminalMouse == null
        ? MouseReports.none
        : MouseReports(
            filter: widget.mouseReportFilter,
            hook: widget.onTerminalMouse,
            text: pointerText,
          );
    final grid = Stack(
      fit: StackFit.expand,
      children: [
        TerminalPointerScope(
          pointer: pointer,
          viewport: _seams,
          keys: pointerKeys,
          text: pointerText,
          geometry: geometry,
          mouseCursor: widget.mouseCursor,
          onTapUp: widget.onTapUp,
          onSecondaryTapDown: widget.onSecondaryTapDown,
          onSecondaryTapUp: widget.onSecondaryTapUp,
          reports: reports,
          wordBoundaryCodepoints: widget.wordBoundaryCodepoints,
          rectangleSelection: widget.rectangleSelection,
          child: TerminalInputScope(
            key: _inputKey,
            keys: _seams,
            text: _seams,
            geometry: geometry,
            focusNode: _focusNode,
            autofocus: widget.autofocus,
            readOnly: widget.readOnly,
            hardwareKeyboardOnly: widget.hardwareKeyboardOnly,
            shortcuts: widget.shortcuts,
            onKeyEvent: widget.onKeyEvent,
            textStyle: style,
            onComposingChanged: _onComposingChanged,
            keyboardType: widget.keyboardType,
            keyboardAppearance: widget.keyboardAppearance,
            deleteDetection: widget.deleteDetection,
            onUnsafePaste: widget.onUnsafePaste,
            composingBackground: _composingBackground,
            macosOptionAsAlt: () => controller.isDisposed
                ? OptionAsAlt.none
                : controller.macosOptionAsAlt,
            onTerminalKey: widget.onTerminalKey,
            onTerminalText: widget.onTerminalText,
            child: TerminalRenderWidget(
              source: _seams,
              geometry: geometry,
              textStyle: style,
              textScaler: scaler,
              focused: _focused,
              cursorHidden: _composing,
              cursorStyle: widget.cursorStyle,
              alwaysShowCursor: widget.alwaysShowCursor,
              backgroundOpacity: widget.backgroundOpacity,
              textRendering: widget.textRendering,
              cacheBudget: widget.cacheBudget,
            ),
          ),
        ),
        TerminalScrollbar(
          viewport: _seams,
          geometry: geometry,
          pointer: pointer,
          keys: pointerKeys,
          text: pointerText,
          reports: reports,
        ),
      ],
    );
    return Actions(
      actions: <Type, Action<Intent>>{SelectAllTextIntent: _selectAllAction},
      child: grid,
    );
  }
}

/// Selects everything ([VtTerminalController.selectAll]) for
/// [SelectAllTextIntent]; enabled while the controller is not disposed.
class _SelectAllAction extends Action<SelectAllTextIntent> {
  _SelectAllAction(this._state);

  final VtTerminalViewState _state;

  @override
  bool isEnabled(SelectAllTextIntent intent) => _state._canSelectAll;

  @override
  void invoke(SelectAllTextIntent intent) => _state._selectAll();
}
