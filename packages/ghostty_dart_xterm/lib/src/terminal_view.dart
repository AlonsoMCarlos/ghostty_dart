// Ported from package:xterm 4.0.0 (lib/src/terminal_view.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.
// Changed: the view is ghostty_dart_flutter's VtTerminalView over the
// terminal's libghostty-vt engine (ADR 0013). Keys are encoded by
// libghostty-vt while terminal.inputHandler is defaultInputHandler and go
// through the custom handler otherwise; mouse reports come from
// libghostty-vt's encoder unless terminal.mouseHandler is custom;
// scrollController is accepted and ignored (libghostty-vt scrolls).

import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart'
    show
        GridPoint,
        KeyModifiers,
        MouseAction,
        MouseButton,
        PointSpace,
        TerminalMode,
        VtCursorStyle,
        VtMouseEvent,
        VtTerminalGrid;
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

import 'core/buffer/cell_offset.dart';
import 'core/input/handler.dart';
import 'core/input/keys.dart';
import 'core/mouse/button.dart';
import 'core/mouse/button_state.dart';
import 'core/mouse/handler.dart';
import 'internal/terminal_internals.dart';
import 'terminal.dart';
import 'ui/controller.dart';
import 'ui/controller_binding.dart';
import 'ui/cursor_type.dart';
import 'ui/input_map.dart';
import 'ui/pointer_input.dart';
import 'ui/selection_mode.dart';
import 'ui/shortcut/shortcuts.dart';
import 'ui/terminal_text_style.dart';
import 'ui/terminal_theme.dart';
import 'ui/themes.dart';

/// A widget that shows a [Terminal] and sends the user's keys, text and
/// mouse input to it: xterm's `TerminalView`, drawn by
/// `ghostty_dart_flutter`.
///
/// ```dart
/// TerminalView(
///   terminal,
///   controller: controller,
///   textStyle: const TerminalStyle(fontFamily: 'JetBrains Mono'),
///   autofocus: true,
/// )
/// ```
///
/// Differences from xterm 4.0.0 (all in `COMPATIBILITY.md`):
/// - While `terminal.inputHandler` is [defaultInputHandler], keys are
///   encoded by libghostty-vt (Kitty keyboard protocol, key releases,
///   AltGr), so some bytes differ from xterm's keytab; a custom handler
///   gets every key, as in xterm. Mouse reports come from libghostty-vt's
///   encoder (every format, correct rows) unless `terminal.mouseHandler`
///   is custom.
/// - [scrollController] is accepted and ignored: libghostty-vt owns the
///   scrollback and the view scrolls it.
/// - Show a [Terminal] in one [TerminalView] at a time.
/// - The view never disposes [terminal]; call [Terminal.dispose] when
///   done with it.
class TerminalView extends StatefulWidget {
  /// A view of [terminal].
  const TerminalView(
    this.terminal, {
    super.key,
    this.controller,
    this.theme = TerminalThemes.defaultTheme,
    this.textStyle = const TerminalStyle(),
    this.textScaler,
    this.padding,
    this.scrollController,
    this.autoResize = true,
    this.backgroundOpacity = 1,
    this.focusNode,
    this.autofocus = false,
    this.onTapUp,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.mouseCursor = SystemMouseCursors.text,
    this.keyboardType = TextInputType.emailAddress,
    this.keyboardAppearance = Brightness.dark,
    this.cursorType = TerminalCursorType.block,
    this.alwaysShowCursor = false,
    this.deleteDetection = false,
    this.shortcuts,
    this.onKeyEvent,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.simulateScroll = true,
  });

  /// The underlying terminal that this widget renders.
  final Terminal terminal;

  /// The selection, highlights and pointer settings; `null` makes the view
  /// use (and dispose) its own.
  final TerminalController? controller;

  /// The theme to use for this terminal.
  ///
  /// It becomes the terminal's theme, so it applies to every view of it.
  final TerminalTheme theme;

  /// The style to use for painting characters.
  final TerminalStyle textStyle;

  /// Scales the font; `null` follows [MediaQuery.textScalerOf].
  final TextScaler? textScaler;

  /// Padding around the terminal's grid, filled with the background colour.
  /// The [MediaQuery] padding is added to it, as in xterm.
  final EdgeInsets? padding;

  /// Accepted for xterm compatibility and ignored: libghostty-vt owns the
  /// scrollback, and the view scrolls it with the wheel, touch and its
  /// scrollbar.
  final ScrollController? scrollController;

  /// Should this widget automatically notify the underlying terminal when its
  /// size changes. [true] by default.
  final bool autoResize;

  /// Opacity of the terminal background. Set to 0 to make the terminal
  /// background transparent.
  final double backgroundOpacity;

  /// An optional focus node to use as the focus node for this widget.
  final FocusNode? focusNode;

  /// True if this widget will be selected as the initial focus when no other
  /// node in its scope is currently focused.
  final bool autofocus;

  /// Callback for when the user taps on the terminal.
  ///
  /// The [CellOffset] is a buffer position: row 0 is the oldest scrollback
  /// line.
  final void Function(TapUpDetails, CellOffset)? onTapUp;

  /// Function called when the user taps on the terminal with a secondary
  /// button.
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;

  /// Function called when the user stops holding down a secondary button.
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;

  /// The mouse cursor for mouse pointers that are hovering over the terminal.
  /// [SystemMouseCursors.text] by default.
  final MouseCursor mouseCursor;

  /// The type of information for which to optimize the text input control.
  /// [TextInputType.emailAddress] by default.
  final TextInputType keyboardType;

  /// The appearance of the keyboard. [Brightness.dark] by default.
  ///
  /// This setting is only honored on iOS devices.
  final Brightness keyboardAppearance;

  /// The type of cursor to use. [TerminalCursorType.block] by default.
  final TerminalCursorType cursorType;

  /// Whether to always show the cursor. This is useful for debugging.
  /// [false] by default.
  final bool alwaysShowCursor;

  /// Workaround to detect delete key for platforms and IMEs that does not
  /// emit hardware delete event. Prefered on mobile platforms. [false] by
  /// default.
  final bool deleteDetection;

  /// Shortcuts for this terminal. This has higher priority than input handler
  /// of the terminal If not provided, [defaultTerminalShortcuts] will be used.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Keyboard event handler of the terminal. This has higher priority than
  /// [shortcuts] and input handler of the terminal.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// True if no input should send to the terminal.
  final bool readOnly;

  /// True if only hardware keyboard events should be used as input. This will
  /// also prevent any on-screen keyboard to be shown.
  final bool hardwareKeyboardOnly;

  /// If true, when the terminal is in alternate buffer (for example running
  /// vim, man, etc), if the application does not declare that it can handle
  /// scrolling, the terminal will simulate scrolling by sending up/down arrow
  /// keys to the application. This is standard behavior for most terminal
  /// emulators. True by default.
  ///
  /// It sets the default of DEC mode 1007 (alternate scroll), so a program
  /// that turns 1007 on still gets arrow keys when this is false.
  final bool simulateScroll;

  @override
  State<TerminalView> createState() => TerminalViewState();
}

/// The state of a [TerminalView]: shows and hides the soft keyboard and
/// tells where the cursor is. Reach it with a
/// `GlobalKey<TerminalViewState>`.
class TerminalViewState extends State<TerminalView> {
  final _viewKey = GlobalKey<VtTerminalViewState>();

  late TerminalController _controller;

  late VtTerminalController _vt;

  TerminalTheme? _appliedTheme;

  bool? _appliedSimulateScroll;

  SelectionMode? _builtSelectionMode;

  /// Which state shows each terminal, to clear its device pixel ratio only
  /// while it is still this view's.
  static final _viewOf = Expando<TerminalViewState>('TerminalView');

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TerminalController();
    _controller.addListener(_onControllerChanged);
    _bindTerminal();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateDevicePixelRatio();
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.removeListener(_onControllerChanged);
      terminalControllerBinding(_controller).detach(_vt);
      if (oldWidget.controller == null) {
        _controller.dispose();
      }
      _controller = widget.controller ?? TerminalController();
      _controller.addListener(_onControllerChanged);
      terminalControllerBinding(_controller).attach(_vt);
    }
    if (!identical(oldWidget.terminal, widget.terminal)) {
      _releaseTerminal(oldWidget.terminal);
      terminalControllerBinding(_controller).detach(_vt);
      _appliedTheme = null;
      _appliedSimulateScroll = null;
      _bindTerminal();
      _updateDevicePixelRatio();
    } else {
      _applyTheme();
      _applySimulateScroll();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    terminalControllerBinding(_controller).detach(_vt);
    if (widget.controller == null) {
      _controller.dispose();
    }
    _releaseTerminal(widget.terminal);
    super.dispose();
  }

  void _bindTerminal() {
    _vt = terminalInternals(widget.terminal).vtController;
    _viewOf[widget.terminal] = this;
    terminalControllerBinding(_controller).attach(_vt);
    _applyTheme();
    _applySimulateScroll();
  }

  void _releaseTerminal(Terminal terminal) {
    if (!identical(_viewOf[terminal], this)) return;
    _viewOf[terminal] = null;
    terminalInternals(terminal).viewDevicePixelRatio = null;
  }

  void _updateDevicePixelRatio() {
    final dpr =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.maybeOf(context)?.devicePixelRatio;
    final internals = terminalInternals(widget.terminal);
    if (internals.viewDevicePixelRatio != dpr) {
      internals.viewDevicePixelRatio = dpr;
    }
  }

  void _applyTheme() {
    final theme = widget.theme;
    if (identical(theme, _appliedTheme) || _vt.isDisposed) return;
    _appliedTheme = theme;
    _vt.theme = _vtTheme(theme);
  }

  void _applySimulateScroll() {
    final simulate = widget.simulateScroll;
    if (simulate == _appliedSimulateScroll || _vt.isDisposed) return;
    _appliedSimulateScroll = simulate;
    _vt.terminal.setModeDefault(
      TerminalMode.mouseAlternateScroll,
      enabled: simulate,
    );
  }

  void _onControllerChanged() {
    // Only the selection mode changes what the view is built with; the
    // hooks read the controller when they run.
    if (_controller.selectionMode != _builtSelectionMode && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    _builtSelectionMode = _controller.selectionMode;
    final padding =
        (widget.padding ?? EdgeInsets.zero) +
        (MediaQuery.maybePaddingOf(context) ?? EdgeInsets.zero);
    return VtTerminalView(
      key: _viewKey,
      controller: _vt,
      textStyle: widget.textStyle.toTextStyle(),
      padding: padding,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      hardwareKeyboardOnly: widget.hardwareKeyboardOnly,
      shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
      onKeyEvent: widget.onKeyEvent,
      textScaler: widget.textScaler,
      autoResize: widget.autoResize,
      cursorStyle: _cursorStyle(widget.cursorType),
      alwaysShowCursor: widget.alwaysShowCursor,
      backgroundOpacity: widget.backgroundOpacity,
      mouseCursor: widget.mouseCursor,
      keyboardType: widget.keyboardType,
      keyboardAppearance: widget.keyboardAppearance,
      deleteDetection: widget.deleteDetection,
      // xterm pastes without asking.
      onUnsafePaste: _pasteAnyway,
      onTapUp: widget.onTapUp == null ? null : _onTapUp,
      onSecondaryTapDown: widget.onSecondaryTapDown == null
          ? null
          : _onSecondaryTapDown,
      onSecondaryTapUp: widget.onSecondaryTapUp == null
          ? null
          : _onSecondaryTapUp,
      onTerminalKey: _onTerminalKey,
      onTerminalText: _onTerminalText,
      mouseReportFilter: _mouseReportFilter,
      onTerminalMouse: _onTerminalMouse,
      wordBoundaryCodepoints: widget.terminal.wordSeparators?.toList(),
      rectangleSelection: _controller.selectionMode == SelectionMode.block,
    );
  }

  /// Focuses the view and shows the soft keyboard.
  void requestKeyboard() {
    _viewKey.currentState?.requestKeyboard();
  }

  /// Hides the soft keyboard; the view keeps the focus.
  void closeKeyboard() {
    _viewKey.currentState?.closeKeyboard();
  }

  /// The cursor's cell relative to the view's top-left corner (padding
  /// included); [Rect.zero] before the first layout or while the cursor is
  /// scrolled out of view.
  Rect get cursorRect => _viewKey.currentState?.cursorRect ?? Rect.zero;

  /// [cursorRect] in global coordinates, for a popup at the cursor (see
  /// `SuggestionPortal`).
  Rect get globalCursorRect =>
      _viewKey.currentState?.globalCursorRect ?? Rect.zero;

  /// Whether the text input connection (soft keyboard, IME) is open.
  bool get hasInputConnection =>
      _viewKey.currentState?.hasInputConnection ?? false;

  static Future<bool> _pasteAnyway(String text) async => true;

  /* Taps */

  /// The buffer position (row 0 is the oldest scrollback line) of the
  /// viewport [cell].
  CellOffset _bufferOffset(GridPoint cell) {
    if (!_vt.isDisposed) {
      final point = _vt.terminal
          .gridRef(GridPoint.viewport(cell.x, cell.y))
          ?.pointIn(PointSpace.screen);
      if (point != null) return CellOffset(point.x, point.y);
    }
    return CellOffset(cell.x, cell.y);
  }

  void _onTapUp(TapUpDetails details, GridPoint cell) {
    widget.onTapUp?.call(details, _bufferOffset(cell));
  }

  void _onSecondaryTapDown(TapDownDetails details, GridPoint cell) {
    widget.onSecondaryTapDown?.call(details, _bufferOffset(cell));
  }

  void _onSecondaryTapUp(TapUpDetails details, GridPoint cell) {
    widget.onSecondaryTapUp?.call(details, _bufferOffset(cell));
  }

  /* Keys and text (custom input handlers) */

  bool get _usesDefaultInputHandler =>
      identical(widget.terminal.inputHandler, defaultInputHandler);

  String? _callInputHandler(
    TerminalKey key, {
    bool shift = false,
    bool ctrl = false,
    bool alt = false,
  }) {
    final terminal = widget.terminal;
    return terminal.inputHandler?.call(
      TerminalKeyboardEvent(
        key: key,
        shift: shift,
        ctrl: ctrl,
        alt: alt,
        state: terminal,
        altBuffer: terminal.isUsingAltBuffer,
        platform: terminal.platform,
      ),
    );
  }

  /// A key for a custom input handler, as xterm's `_handleKeyEvent` does;
  /// `null` leaves it to the view.
  String? _onTerminalKey(KeyEvent event, KeyModifiers modifiers) {
    if (_usesDefaultInputHandler) return null;
    final key = keyToTerminalKey(event.logicalKey);
    if (key == null) return null;
    final output = _callInputHandler(
      key,
      shift: modifiers.hasShift,
      ctrl: modifiers.hasCtrl,
      alt: modifiers.hasAlt,
    );
    if (output != null) return output;
    final character = event.character;
    if (!modifiers.hasCtrl &&
        !modifiers.hasAlt &&
        character != null &&
        _isPrintable(character)) {
      // xterm then inserts the key's text. With a text input connection
      // the platform sends it (and _onTerminalText sees it); without one
      // (hardwareKeyboardOnly) it is inserted here.
      if (hasInputConnection) return null;
      return _insert(character);
    }
    // Not handled: the key goes on to the rest of the app, as in xterm.
    return '';
  }

  /// Text for a custom input handler, as xterm's `_onInsert` does.
  String? _onTerminalText(String text) {
    if (_usesDefaultInputHandler) return null;
    return _insert(text);
  }

  String _insert(String text) {
    final key = charToTerminalKey(text.trim());
    return (key == null ? null : _callInputHandler(key)) ?? text;
  }

  static bool _isPrintable(String character) {
    if (character.isEmpty) return false;
    final rune = character.runes.first;
    return rune >= 0x20 && rune != 0x7f && !(rune >= 0x80 && rune < 0xa0);
  }

  /* Mouse */

  bool _mouseReportFilter(VtMouseEvent event) {
    final controller = _controller;
    if (controller.suspendedPointerInputs) return false;
    final button = event.button;
    // xterm 4.0.0 reports the wheel whatever pointerInputs say.
    if (button != null && _wheelButtons.containsKey(button)) return true;
    return switch (event.action) {
      MouseAction.press || MouseAction.release =>
        controller.shouldSendPointerInput(PointerInput.tap),
      MouseAction.motion => controller.shouldSendPointerInput(
        button == null ? PointerInput.move : PointerInput.drag,
      ),
      MouseAction.unknown => false,
    };
  }

  /// A mouse report for a custom mouse handler, through
  /// [Terminal.mouseInput] as in xterm; `null` (default handler) lets the
  /// view encode it.
  String? _onTerminalMouse(VtMouseEvent event, GridPoint cell) {
    final terminal = widget.terminal;
    if (identical(terminal.mouseHandler, defaultMouseHandler)) return null;
    // xterm reports no motion.
    if (event.action == MouseAction.motion) return '';
    final button = switch (event.button) {
      MouseButton.left => TerminalMouseButton.left,
      MouseButton.middle => TerminalMouseButton.middle,
      MouseButton.right => TerminalMouseButton.right,
      final wheel? => _wheelButtons[wheel],
      null => null,
    };
    if (button == null) return '';
    final state = event.action == MouseAction.release
        ? TerminalMouseButtonState.up
        : TerminalMouseButtonState.down;
    // Sent through the terminal's output path directly, so the report
    // does not scroll the view to the bottom (xterm's does not either).
    terminal.mouseInput(button, state, _bufferOffset(cell));
    return '';
  }

  static const _wheelButtons = {
    MouseButton.four: TerminalMouseButton.wheelUp,
    MouseButton.five: TerminalMouseButton.wheelDown,
    MouseButton.six: TerminalMouseButton.wheelLeft,
    MouseButton.seven: TerminalMouseButton.wheelRight,
  };
}

VtCursorStyle _cursorStyle(TerminalCursorType type) => switch (type) {
  TerminalCursorType.block => VtCursorStyle.block,
  TerminalCursorType.underline => VtCursorStyle.underline,
  TerminalCursorType.verticalBar => VtCursorStyle.bar,
};

VtTerminalTheme _vtTheme(TerminalTheme theme) => VtTerminalTheme(
  cursor: theme.cursor,
  selection: theme.selection,
  foreground: theme.foreground,
  background: theme.background,
  black: theme.black,
  white: theme.white,
  red: theme.red,
  green: theme.green,
  yellow: theme.yellow,
  blue: theme.blue,
  magenta: theme.magenta,
  cyan: theme.cyan,
  brightBlack: theme.brightBlack,
  brightRed: theme.brightRed,
  brightGreen: theme.brightGreen,
  brightYellow: theme.brightYellow,
  brightBlue: theme.brightBlue,
  brightMagenta: theme.brightMagenta,
  brightCyan: theme.brightCyan,
  brightWhite: theme.brightWhite,
  searchHitBackground: theme.searchHitBackground,
  searchHitBackgroundCurrent: theme.searchHitBackgroundCurrent,
  searchHitForeground: theme.searchHitForeground,
);
