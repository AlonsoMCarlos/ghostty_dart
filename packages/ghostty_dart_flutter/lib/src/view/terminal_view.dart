import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../controller/terminal_controller.dart';
import '../input/keyboard/terminal_input_scope.dart';
import '../input/pointer/terminal_pointer_scope.dart';
import '../metrics/cell_metrics.dart';
import '../render/terminal_render.dart';
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
/// **Accessibility.** While an accessibility service is running, the view
/// exposes its visible text as one semantics node labelled
/// [semanticsLabel]; [announceOutput] also reads new output aloud.
///
/// **Ownership.** The view never disposes [controller]; dispose it when you
/// are done with it. If it is disposed while the view is still mounted, the
/// view draws only the background and ignores input. Replacing [controller]
/// frees the old one for another view and moves the focus report (DEC 1004)
/// to the new one. One controller drives at most one view at a time (a
/// debug-mode assert checks it). For [focusNode], see its docs.
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
  }) : assert(
         backgroundOpacity >= 0 && backgroundOpacity <= 1,
         'backgroundOpacity must be between 0 and 1',
       );

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

  @override
  State<VtTerminalView> createState() => VtTerminalViewState();
}

/// The state of a [VtTerminalView]: shows and hides the soft keyboard.
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

  @override
  void initState() {
    super.initState();
    _seams = ControllerSeams(widget.controller);
    widget.controller.addListener(_onControllerChanged);
    if (widget.focusNode == null) _ownFocusNode = _createFocusNode();
    _focusNode.addListener(_onFocusChanged);
    _focused = _focusNode.hasFocus;
  }

  FocusNode _createFocusNode() => FocusNode(debugLabel: 'VtTerminalView');

  @override
  void didUpdateWidget(VtTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      final oldSeams = _seams;
      oldSeams.release();
      _seams = ControllerSeams(widget.controller);
      _readOnlySeams = null;
      widget.controller.addListener(_onControllerChanged);
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

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _seams.release();
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
    return Stack(
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
            ),
          ),
        ),
        TerminalScrollbar(
          viewport: _seams,
          geometry: geometry,
          pointer: pointer,
          keys: pointerKeys,
          text: pointerText,
        ),
      ],
    );
  }
}
