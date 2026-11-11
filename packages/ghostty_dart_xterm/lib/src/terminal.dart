// Ported from package:xterm 4.0.0 (lib/src/terminal.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.
// Changed: libghostty-vt (through ghostty_dart_flutter's
// VtTerminalController) parses the program's output and keeps the screen,
// so Terminal is not an EscapeHandler; its handler methods write the
// equivalent escape sequence while the parser is at ground and throw
// StateError otherwise (ADR 0013). Adds dispose, writeBytes and
// onOutputBytes (ADR 0013, additive).

import 'dart:collection';
import 'dart:convert';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart'
    show
        ResizeWindowRequest,
        TerminalMode,
        TerminalScreen,
        UnknownOscSequence,
        UnknownSequence,
        VtTerminal,
        VtTerminalEffects;
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart'
    show VtTerminalController;

import 'base/observable.dart';
import 'core/buffer/buffer.dart';
import 'core/buffer/buffer_lines.dart' show packAttributes, packColor;
import 'core/buffer/cell_offset.dart';
import 'core/buffer/line.dart';
import 'core/buffer/terminal_engine.dart';
import 'core/cursor.dart';
import 'core/escape/emitter.dart';
import 'core/input/handler.dart';
import 'core/input/keys.dart';
import 'core/mouse/button.dart';
import 'core/mouse/button_state.dart';
import 'core/mouse/handler.dart';
import 'core/mouse/mode.dart';
import 'core/platform.dart';
import 'core/state.dart';
import 'internal/terminal_internals.dart';
import 'utils/ascii.dart';
import 'utils/circular_buffer.dart';

/// [Terminal] is an interface to interact with command line applications. It
/// translates escape sequences from the application into updates to the
/// [buffer] and events such as [onTitleChange] or [onBell], as well as
/// translating user input into escape sequences that the application can
/// understand.
///
/// The emulator is libghostty-vt. Feed it the program's output with
/// [write] (or [writeBytes]) and send [onOutput] (or [onOutputBytes]) to
/// the program's input:
///
/// ```dart
/// final terminal = Terminal(
///   maxLines: 10000,
///   onOutput: (data) => pty.write(utf8.encode(data)),
///   onResize: (width, height, pixelWidth, pixelHeight) =>
///       pty.resize(height, width),
/// );
/// pty.output.listen((data) => terminal.write(utf8.decode(data)));
/// // ...
/// terminal.dispose(); // not in xterm: frees libghostty-vt's memory
/// ```
///
/// Differences from xterm 4.0.0 are listed in `COMPATIBILITY.md`. The ones
/// to know first: the terminal holds native memory, so call [dispose] when
/// done (a finalizer is the safety net); [buffer] lines are snapshots
/// (read them again after a write); and the `EscapeHandler` methods
/// ([setCursor], [eraseDisplay], …) write escape sequences, so they throw
/// [StateError] while the program's output stopped inside a sequence.
class Terminal with Observable implements TerminalState {
  /// The number of lines that the scrollback buffer can hold. If the buffer
  /// exceeds this size, the lines at the top of the buffer will be removed.
  ///
  /// libghostty-vt drops scrollback in whole pages, so somewhat more lines
  /// may be kept.
  final int maxLines;

  /// Function that is called when the program requests the terminal to ring
  /// the bell. If not set, the terminal will do nothing.
  void Function()? onBell;

  /// Function that is called when the program requests the terminal to change
  /// the title of the window to [title].
  void Function(String title)? onTitleChange;

  /// Function that is called when the program requests the terminal to change
  /// the icon of the window. [icon] is the name of the icon.
  ///
  /// Only [setIconName] calls it: libghostty-vt 1.0.0 does not report the
  /// icon name sequences (OSC 0 and 1) separately from the title.
  void Function(String icon)? onIconChange;

  /// Function that is called when the terminal emits data to the underlying
  /// program. This is typically caused by user inputs from [textInput],
  /// [keyInput], [mouseInput], or [paste].
  ///
  /// Bytes from libghostty-vt (keys and mouse reports typed into a
  /// `TerminalView`, replies to the program's queries) are decoded as
  /// UTF-8, or as Latin-1 for a chunk that is not valid UTF-8 (X10 mouse
  /// reports). [onOutputBytes] has the exact bytes.
  void Function(String data)? onOutput;

  /// Called with the exact bytes of each chunk the terminal sends to the
  /// program, before [onOutput] is called with the same chunk as text.
  /// Text produced in Dart ([textInput], [keyInput], …) arrives UTF-8
  /// encoded. Not in xterm.
  void Function(Uint8List data)? onOutputBytes;

  /// Function that is called when the dimensions of the terminal change.
  ///
  /// [resize] passes its own arguments, as in xterm. When a `TerminalView`
  /// resizes the terminal, `pixelWidth` and `pixelHeight` are the cell
  /// size in logical pixels, rounded, as xterm's view reports them.
  void Function(int width, int height, int pixelWidth, int pixelHeight)?
  onResize;

  /// The [TerminalInputHandler] used by this terminal. [defaultInputHandler] is
  /// used when not specified. User of this class can provide their own
  /// implementation of [TerminalInputHandler] or extend [defaultInputHandler]
  /// with [CascadeInputHandler].
  TerminalInputHandler? inputHandler;

  /// The [TerminalMouseHandler] that turns [mouseInput] into reports for
  /// the program. [defaultMouseHandler] when not specified.
  TerminalMouseHandler? mouseHandler;

  /// The callback that is called when the terminal receives a unrecognized
  /// escape sequence.
  ///
  /// Only OSC sequences libghostty-vt does not implement reach it (OSC 66,
  /// for instance, is Kitty's text sizing protocol there); the content is
  /// split at `;` into the code and its arguments, as in xterm.
  void Function(String code, List<String> args)? onPrivateOSC;

  /// Flag to toggle os specific behaviors.
  final TerminalTargetPlatform platform;

  /// Characters that break selection when double clicking. If not set, the
  /// [Buffer.defaultWordSeparators] will be used.
  final Set<int>? wordSeparators;

  /// Creates an 80 × 24 terminal.
  Terminal({
    this.maxLines = 1000,
    this.onBell,
    this.onTitleChange,
    this.onIconChange,
    this.onOutput,
    this.onResize,
    this.platform = TerminalTargetPlatform.unknown,
    this.inputHandler = defaultInputHandler,
    this.mouseHandler = defaultMouseHandler,
    this.onPrivateOSC,
    this.reflowEnabled = true,
    this.wordSeparators,
    this.onOutputBytes,
  }) {
    final controller = VtTerminalController(
      cols: _initialCols,
      rows: _initialRows,
      // xterm limits lines, not bytes.
      scrollbackMaxBytes: null,
      scrollbackMaxLines: _scrollbackLines(_initialRows),
    );
    _controller = controller;
    _engine = TerminalEngine(controller)..writeSequence = _writeSequence;
    _internals = _TerminalInternals(controller);
    bindTerminalEngine(this, _engine);
    bindTerminalInternals(this, _internals);
    controller
      ..onOutput = _onEngineOutput
      ..onResize = _onEngineResize
      ..onBell = _onEngineBell
      ..onTitleChanged = _onEngineTitle
      ..addListener(_engine.invalidate);
    // The native callables are GC roots: capture the terminal weakly so a
    // forgotten terminal can still be collected and finalized.
    final self = WeakReference(this);
    controller.terminal
      ..setUnknownSequenceMaxBytes(_unknownSequenceMaxBytes)
      ..onUnknownSequence = (sequence) {
        self.target?._queueUnknownSequence(sequence);
      }
      ..onResizeWindow = (request) {
        self.target?._queueResizeWindow(request);
      };
  }

  static const _initialCols = 80;
  static const _initialRows = 24;

  /// The longest OSC sequence [onPrivateOSC] receives whole; longer ones
  /// arrive truncated.
  static const _unknownSequenceMaxBytes = 64 * 1024;

  late final VtTerminalController _controller;
  late final TerminalEngine _engine;
  late final _TerminalInternals _internals;

  final _emitter = const EscapeEmitter();

  late final _mainBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: false,
    wordSeparators: wordSeparators,
  );

  late final _altBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: true,
    wordSeparators: wordSeparators,
  );

  /// Events libghostty-vt raised inside a write, delivered after it.
  final _pending = ListQueue<void Function()>();
  bool _draining = false;

  /// Set while [resize] runs, so the controller's resize callback does not
  /// call [onResize] a second time.
  bool _resizing = false;

  VtTerminal get _vt => _engine.vt;

  bool _mode(TerminalMode mode) => _vt.isModeEnabled(mode);

  /* TerminalState */

  /// Number of cells in a terminal row.
  @override
  int get viewWidth => _controller.cols;

  /// Number of rows in this terminal.
  @override
  int get viewHeight => _controller.rows;

  /// The current text style (the SGR pen): a new copy on every read, so
  /// changing it does not change the terminal; use [setCursorBold] and the
  /// other methods for that.
  @override
  CursorStyle get cursor {
    final style = _vt.cursorSgrStyle;
    return CursorStyle(
      foreground: packColor(style.foreground),
      background: packColor(style.background),
      attrs: packAttributes(style),
    );
  }

  /// Whether insert mode (IRM, ANSI mode 4) is set.
  @override
  bool get insertMode => _mode(TerminalMode.insert);

  /// Whether line feed mode (LNM, ANSI mode 20) is set.
  @override
  bool get lineFeedMode => _mode(TerminalMode.linefeed);

  /// Whether application cursor keys (DECCKM, DEC mode 1) are set.
  @override
  bool get cursorKeysMode => _mode(TerminalMode.cursorKeys);

  /// Whether reverse video (DECSCNM, DEC mode 5) is set.
  @override
  bool get reverseDisplayMode => _mode(TerminalMode.reverseColors);

  /// Whether origin mode (DECOM, DEC mode 6) is set.
  @override
  bool get originMode => _mode(TerminalMode.origin);

  /// Whether autowrap (DECAWM, DEC mode 7) is set.
  @override
  bool get autoWrapMode => _mode(TerminalMode.wraparound);

  /// The mouse events the program asked for (DEC modes 9, 1000, 1002,
  /// 1003).
  @override
  MouseMode get mouseMode {
    if (_mode(TerminalMode.mouseEventAny)) return MouseMode.upDownScrollMove;
    if (_mode(TerminalMode.mouseEventButton)) {
      return MouseMode.upDownScrollDrag;
    }
    if (_mode(TerminalMode.mouseEventNormal)) return MouseMode.upDownScroll;
    if (_mode(TerminalMode.mouseEventX10)) return MouseMode.clickOnly;
    return MouseMode.none;
  }

  /// The mouse report format the program asked for (DEC modes 1005, 1006,
  /// 1015; 1016, SGR with pixels, reads as [MouseReportMode.sgr]).
  @override
  MouseReportMode get mouseReportMode {
    if (_mode(TerminalMode.mouseFormatSgr) ||
        _mode(TerminalMode.mouseFormatSgrPixels)) {
      return MouseReportMode.sgr;
    }
    if (_mode(TerminalMode.mouseFormatUrxvt)) return MouseReportMode.urxvt;
    if (_mode(TerminalMode.mouseFormatUtf8)) return MouseReportMode.utf;
    return MouseReportMode.normal;
  }

  /// Whether the cursor blinks (DEC mode 12).
  @override
  bool get cursorBlinkMode => _mode(TerminalMode.cursorBlinking);

  /// Whether the cursor is visible (DECTCEM, DEC mode 25).
  @override
  bool get cursorVisibleMode => _mode(TerminalMode.cursorVisible);

  /// Whether the keypad is in application mode (DECNKM, DEC mode 66).
  @override
  bool get appKeypadMode => _mode(TerminalMode.keypadKeys);

  /// Whether focus events are reported (DEC mode 1004).
  @override
  bool get reportFocusMode => _mode(TerminalMode.focusEvent);

  /// Whether the wheel sends arrow keys on the alternate screen (DEC mode
  /// 1007).
  @override
  bool get altBufferMouseScrollMode => _mode(TerminalMode.mouseAlternateScroll);

  /// Whether bracketed paste (DEC mode 2004) is set.
  @override
  bool get bracketedPasteMode => _mode(TerminalMode.bracketedPaste);

  /// Current active buffer of the terminal. This is initially [mainBuffer] and
  /// can be switched back and forth from [altBuffer] to [mainBuffer] when
  /// the underlying program requests it.
  Buffer get buffer => isUsingAltBuffer ? _altBuffer : _mainBuffer;

  /// The main buffer, with scrollback. Readable only while it is active:
  /// libghostty-vt 1.0.0 exposes only the active screen, so while the
  /// alternate buffer is in use it reads as blank lines (see [Buffer]).
  Buffer get mainBuffer => _mainBuffer;

  /// The alternate buffer of full-screen programs. Readable only while it
  /// is active (see [mainBuffer]).
  Buffer get altBuffer => _altBuffer;

  /// Whether the alternate buffer is active.
  bool get isUsingAltBuffer => _vt.activeScreen == TerminalScreen.alternate;

  /// Lines of the active buffer.
  IndexAwareCircularBuffer<BufferLine> get lines => buffer.lines;

  /// Whether the terminal performs reflow when the viewport size changes or
  /// simply truncates lines. true by default.
  ///
  /// Applies to [resize] only: a `TerminalView` that resizes the terminal
  /// always reflows. Without reflow, libghostty-vt drops the cells beyond
  /// a narrower width (xterm keeps them for a later, wider resize).
  @override
  bool reflowEnabled;

  /// Writes the data from the underlying program to the terminal. Calling this
  /// updates the states of the terminal and emits events such as [onBell] or
  /// [onTitleChange] when the escape sequences in [data] request it.
  void write(String data) {
    _feed(utf8.encode(data));
    notifyListeners();
  }

  /// Writes [data], bytes from the underlying program, to the terminal: as
  /// [write], without a round trip through a `String`. Not in xterm.
  void writeBytes(Uint8List data) {
    _feed(data);
    notifyListeners();
  }

  /// Sends a key event to the underlying program.
  ///
  /// See also:
  /// - [charInput]
  /// - [textInput]
  /// - [paste]
  bool keyInput(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    final output = inputHandler?.call(
      TerminalKeyboardEvent(
        key: key,
        shift: shift,
        alt: alt,
        ctrl: ctrl,
        state: this,
        altBuffer: isUsingAltBuffer,
        platform: platform,
      ),
    );

    if (output != null) {
      _emit(output);
      return true;
    }

    return false;
  }

  /// Similary to [keyInput], but takes a character as input instead of a
  /// [TerminalKey].
  ///
  /// See also:
  /// - [keyInput]
  /// - [textInput]
  /// - [paste]
  bool charInput(int charCode, {bool alt = false, bool ctrl = false}) {
    if (ctrl) {
      // a(97) ~ z(122)
      if (charCode >= Ascii.a && charCode <= Ascii.z) {
        final output = charCode - Ascii.a + 1;
        _emit(String.fromCharCode(output));
        return true;
      }

      // [(91) ~ _(95)
      if (charCode >= Ascii.openBracket && charCode <= Ascii.underscore) {
        final output = charCode - Ascii.openBracket + 27;
        _emit(String.fromCharCode(output));
        return true;
      }
    }

    if (alt && platform != TerminalTargetPlatform.macos) {
      if (charCode >= Ascii.a && charCode <= Ascii.z) {
        final code = charCode - Ascii.a + 65;
        final input = [0x1b, code];
        _emit(String.fromCharCodes(input));
        return true;
      }
    }

    return false;
  }

  /// Sends regular text input to the underlying program.
  ///
  /// See also:
  /// - [keyInput]
  /// - [charInput]
  /// - [paste]
  void textInput(String text) {
    _emit(text);
  }

  /// Similar to [textInput], except that when the program tells the terminal
  /// that it supports [bracketedPasteMode], the text is wrapped in escape
  /// sequences to indicate that it is a paste operation. Prefer this method
  /// over [textInput] when pasting text.
  ///
  /// See also:
  /// - [textInput]
  void paste(String text) {
    if (bracketedPasteMode) {
      _emit(_emitter.bracketedPaste(text));
    } else {
      textInput(text);
    }
  }

  /// Handle a mouse event and return true if it was handled.
  ///
  /// [position] is a buffer position (row 0 is the oldest scrollback
  /// line), passed to [mouseHandler] unchanged, as in xterm.
  bool mouseInput(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    CellOffset position,
  ) {
    final output = mouseHandler?.call(
      TerminalMouseEvent(
        button: button,
        buttonState: buttonState,
        position: position,
        state: this,
        platform: platform,
      ),
    );
    if (output != null) {
      _emit(output);
      return true;
    }
    return false;
  }

  /// Resize the terminal screen. [newWidth] and [newHeight] should be greater
  /// than 0. Text reflow is currently not implemented and will be avaliable in
  /// the future.
  ///
  /// Calls [onResize] with the arguments first, as xterm does. Both screens
  /// resize; the main screen reflows unless [reflowEnabled] is false.
  /// [pixelWidth] and [pixelHeight] (xterm's view passes the cell size in
  /// logical pixels) also set libghostty-vt's cell size, used in size
  /// reports. Must not be called during a frame's build or layout.
  void resize(
    int newWidth,
    int newHeight, [
    int? pixelWidth,
    int? pixelHeight,
  ]) {
    newWidth = max(newWidth, 1);
    newHeight = max(newHeight, 1);
    final vt = _vt;

    onResize?.call(newWidth, newHeight, pixelWidth ?? 0, pixelHeight ?? 0);

    final ratio = _internals.viewDevicePixelRatio ?? 1;
    int? devicePixels(int? logical) =>
        logical == null || logical <= 0 ? null : (logical * ratio).round();

    // libghostty-vt reflows the main screen only while autowrap is set.
    final suppressReflow =
        !reflowEnabled && vt.isModeEnabled(TerminalMode.wraparound);
    _resizing = true;
    try {
      if (suppressReflow) {
        vt.setMode(TerminalMode.wraparound, enabled: false);
      }
      try {
        _controller.resize(
          newWidth,
          newHeight,
          cellWidthPx: devicePixels(pixelWidth),
          cellHeightPx: devicePixels(pixelHeight),
        );
      } finally {
        if (suppressReflow && !vt.isDisposed) {
          vt.setMode(TerminalMode.wraparound, enabled: true);
        }
      }
    } finally {
      _resizing = false;
    }
    _applyScrollbackLimit();
    _engine.invalidate();
  }

  /// Frees libghostty-vt's terminal and every native object this terminal
  /// created (anchors included). Safe to call more than once. Not in
  /// xterm, whose terminal needs no cleanup; a forgotten terminal is freed
  /// by a finalizer some time after it is garbage collected.
  ///
  /// Afterwards every member that reads or changes the terminal throws
  /// [StateError]. A `TerminalView` never disposes its terminal.
  void dispose() {
    if (_engine.isDisposed) return;
    _engine.isDisposed = true;
    _pending.clear();
    _controller.dispose();
  }

  @override
  String toString() {
    if (_engine.isDisposed) return 'Terminal(#$hashCode, disposed)';
    return 'Terminal(#$hashCode, $viewWidth x $viewHeight, '
        '${buffer.height} lines)';
  }

  /* Handlers */

  /// Writes the character [char] at the cursor. A control character is
  /// dropped (xterm stores it as a glyph).
  void writeChar(int char) {
    if (isControlCharacter(char)) return;
    _seq(String.fromCharCode(char));
  }

  /* SBC */

  /// Calls [onBell], as the program's BEL does.
  void bell() {
    onBell?.call();
  }

  /// Moves the cursor one cell left (BS).
  void backspaceReturn() {
    _seq('\b');
  }

  /// Moves the cursor to the next tab stop (HT).
  void tab() {
    _seq('\t');
  }

  /// Moves the cursor down one line (LF).
  void lineFeed() {
    _seq('\n');
  }

  /// Moves the cursor to the first column (CR).
  void carriageReturn() {
    _seq('\r');
  }

  /// Switches to the G1 character set (SO).
  void shiftOut() {
    _seq('\x0e');
  }

  /// Switches to the G0 character set (SI).
  void shiftIn() {
    _seq('\x0f');
  }

  /// Does nothing, as in xterm (it handles unknown control characters).
  void unknownSBC(int char) {
    // no-op
  }

  /* ANSI sequence */

  /// Saves the cursor position and attributes (DECSC).
  void saveCursor() {
    _seq('\x1b7');
  }

  /// Restores the cursor saved by [saveCursor] (DECRC).
  void restoreCursor() {
    _seq('\x1b8');
  }

  /// Moves the cursor down, scrolling at the bottom margin (IND).
  void index() {
    _seq('\x1bD');
  }

  /// Moves the cursor to the first column of the next line (NEL).
  void nextLine() {
    _seq('\x1bE');
  }

  /// Sets a tab stop at the cursor column (HTS; sic, xterm's name).
  void setTapStop() {
    _seq('\x1bH');
  }

  /// Moves the cursor up, scrolling at the top margin (RI).
  void reverseIndex() {
    _seq('\x1bM');
  }

  /// Designates character set [name] (its final character, such as `B`
  /// or `0`) as G[charset] (0–3).
  void designateCharset(int charset, int name) {
    const intermediates = ['(', ')', '*', '+'];
    if (charset < 0 || charset >= intermediates.length) return;
    if (name < 0x20 || name > 0x7e) return;
    _seq('\x1b${intermediates[charset]}${String.fromCharCode(name)}');
  }

  /// Does nothing, as in xterm (sic, xterm's name).
  void unkownEscape(int char) {
    // no-op
  }

  /* CSI */

  /// Repeats the last printed character [count] times (REP).
  void repeatPreviousCharacter(int count) {
    if (count <= 0) return;
    _seq('\x1b[${count}b');
  }

  /// Moves the cursor to column [x], row [y] (0-based; relative to the
  /// scroll region in origin mode) (CUP).
  void setCursor(int x, int y) {
    _seq('\x1b[${max(y, 0) + 1};${max(x, 0) + 1}H');
  }

  /// Moves the cursor to column [x] (0-based) (CHA).
  void setCursorX(int x) {
    _seq('\x1b[${max(x, 0) + 1}G');
  }

  /// Moves the cursor to row [y] (0-based) (VPA).
  void setCursorY(int y) {
    _seq('\x1b[${max(y, 0) + 1}d');
  }

  /// Moves the cursor [offset] columns right, or left if negative.
  void moveCursorX(int offset) {
    _seq(_moveX(offset));
  }

  /// Moves the cursor [n] rows down, or up if negative.
  void moveCursorY(int n) {
    _seq(_moveY(n));
  }

  /// Clears the tab stop at the cursor column (TBC 0).
  void clearTabStopUnderCursor() {
    _seq('\x1b[0g');
  }

  /// Clears every tab stop (TBC 3).
  void clearAllTabStops() {
    _seq('\x1b[3g');
  }

  /// Sends xterm's primary device attributes reply to [onOutput].
  void sendPrimaryDeviceAttributes() {
    _emit(_emitter.primaryDeviceAttributes());
  }

  /// Sends xterm's secondary device attributes reply to [onOutput].
  void sendSecondaryDeviceAttributes() {
    _emit(_emitter.secondaryDeviceAttributes());
  }

  /// Sends xterm's tertiary device attributes reply to [onOutput].
  void sendTertiaryDeviceAttributes() {
    _emit(_emitter.tertiaryDeviceAttributes());
  }

  /// Sends the "terminal OK" status report to [onOutput].
  void sendOperatingStatus() {
    _emit(_emitter.operatingStatus());
  }

  /// Sends a cursor position report to [onOutput], with the 0-based
  /// position xterm's method sends.
  void sendCursorPosition() {
    _emit(_emitter.cursorPosition(buffer.cursorX, buffer.cursorY));
  }

  /// Sets the scroll region to rows [top] to [bottom] (0-based, inclusive;
  /// the last row by default) (DECSTBM). The cursor stays where it is, as
  /// in xterm.
  void setMargins(int top, [int? bottom]) {
    final vt = _vt;
    final last = vt.rows - 1;
    final a = top.clamp(0, last);
    final b = (bottom ?? last).clamp(0, last);
    final first = min(a, b);
    final x = vt.cursorX;
    final y = vt.cursorY;
    // DECSTBM homes the cursor; move it back (relative to the new region
    // in origin mode).
    final row = originMode ? max(y - first, 0) : y;
    _seq('\x1b[${first + 1};${max(a, b) + 1}r\x1b[${row + 1};${x + 1}H');
  }

  /// Moves the cursor [amount] rows down, to the first column.
  void cursorNextLine(int amount) {
    _seq('${_moveY(amount)}\r');
  }

  /// Moves the cursor [amount] rows up, to the first column.
  void cursorPrecedingLine(int amount) {
    _seq('${_moveY(-amount)}\r');
  }

  /// Erases from the cursor to the end of the screen (ED 0).
  void eraseDisplayBelow() {
    _seq('\x1b[J');
  }

  /// Erases from the start of the screen to the cursor (ED 1).
  void eraseDisplayAbove() {
    _seq('\x1b[1J');
  }

  /// Erases the whole screen (ED 2).
  void eraseDisplay() {
    _seq('\x1b[2J');
  }

  /// Erases the scrollback (ED 3).
  void eraseScrollbackOnly() {
    _seq('\x1b[3J');
  }

  /// Erases from the cursor to the end of the line (EL 0).
  void eraseLineRight() {
    _seq('\x1b[K');
  }

  /// Erases from the start of the line to the cursor (EL 1).
  void eraseLineLeft() {
    _seq('\x1b[1K');
  }

  /// Erases the line (EL 2).
  void eraseLine() {
    _seq('\x1b[2K');
  }

  /// Inserts [amount] blank lines at the cursor (IL).
  void insertLines(int amount) {
    _countSeq(amount, 'L');
  }

  /// Deletes [amount] lines at the cursor (DL).
  void deleteLines(int amount) {
    _countSeq(amount, 'M');
  }

  /// Deletes [amount] cells at the cursor (DCH).
  void deleteChars(int amount) {
    _countSeq(amount, 'P');
  }

  /// Scrolls the scroll region up by [amount] lines (SU).
  void scrollUp(int amount) {
    _countSeq(amount, 'S');
  }

  /// Scrolls the scroll region down by [amount] lines (SD).
  void scrollDown(int amount) {
    _countSeq(amount, 'T');
  }

  /// Erases [amount] cells from the cursor (ECH).
  void eraseChars(int amount) {
    _countSeq(amount, 'X');
  }

  /// Inserts [amount] blank cells at the cursor (ICH).
  void insertBlankChars(int amount) {
    _countSeq(amount, '@');
  }

  /// Sends the text area size report to [onOutput].
  void sendSize() {
    _emit(_emitter.size(viewHeight, viewWidth));
  }

  /// Does nothing, as in xterm (it handles unknown CSI sequences).
  void unknownCSI(int finalByte) {
    // no-op
  }

  /* Modes */

  /// Sets or resets insert mode (IRM).
  void setInsertMode(bool enabled) {
    _seq('\x1b[4${enabled ? 'h' : 'l'}');
  }

  /// Sets or resets line feed mode (LNM).
  void setLineFeedMode(bool enabled) {
    _seq('\x1b[20${enabled ? 'h' : 'l'}');
  }

  /// Does nothing, as in xterm (it handles unknown ANSI modes).
  void setUnknownMode(int mode, bool enabled) {
    // no-op
  }

  /* DEC Private modes */

  /// Sets or resets application cursor keys (DECCKM).
  void setCursorKeysMode(bool enabled) {
    _seq(_decMode(1, enabled));
  }

  /// Sets or resets reverse video (DECSCNM).
  void setReverseDisplayMode(bool enabled) {
    _seq(_decMode(5, enabled));
  }

  /// Sets or resets origin mode (DECOM).
  void setOriginMode(bool enabled) {
    _seq(_decMode(6, enabled));
  }

  /// Does nothing, as in xterm (132-column mode, DECCOLM).
  void setColumnMode(bool enabled) {
    // no-op
  }

  /// Sets or resets autowrap (DECAWM).
  void setAutoWrapMode(bool enabled) {
    _seq(_decMode(7, enabled));
  }

  /// Sets the mouse events reported to the program (DEC modes 9, 1000,
  /// 1002, 1003).
  void setMouseMode(MouseMode mode) {
    final set = switch (mode) {
      MouseMode.none => '',
      MouseMode.clickOnly => _decMode(9, true),
      MouseMode.upDownScroll => _decMode(1000, true),
      MouseMode.upDownScrollDrag => _decMode(1002, true),
      MouseMode.upDownScrollMove => _decMode(1003, true),
    };
    _seq(
      '${_decMode(9, false)}${_decMode(1000, false)}'
      '${_decMode(1002, false)}${_decMode(1003, false)}$set',
    );
  }

  /// Sets or resets cursor blinking (DEC mode 12).
  void setCursorBlinkMode(bool enabled) {
    _seq(_decMode(12, enabled));
  }

  /// Shows or hides the cursor (DECTCEM).
  void setCursorVisibleMode(bool enabled) {
    _seq(_decMode(25, enabled));
  }

  /// Switches to the alternate buffer, without clearing it or saving the
  /// cursor (DEC mode 47).
  void useAltBuffer() {
    _seq(_decMode(47, true));
  }

  /// Switches back to the main buffer (DEC mode 47).
  void useMainBuffer() {
    _seq(_decMode(47, false));
  }

  /// Erases the alternate buffer (ED 2 on it), whichever buffer is active.
  void clearAltBuffer() {
    _seq(
      isUsingAltBuffer
          ? '\x1b[2J'
          : '${_decMode(47, true)}\x1b[2J${_decMode(47, false)}',
    );
  }

  /// Sets or resets the application keypad (DECNKM, DEC mode 66).
  void setAppKeypadMode(bool enabled) {
    _seq(_decMode(66, enabled));
  }

  /// Sets or resets focus event reports (DEC mode 1004).
  void setReportFocusMode(bool enabled) {
    _seq(_decMode(1004, enabled));
  }

  /// Sets the mouse report format (DEC modes 1005, 1006, 1015).
  void setMouseReportMode(MouseReportMode mode) {
    final set = switch (mode) {
      MouseReportMode.normal => '',
      MouseReportMode.utf => _decMode(1005, true),
      MouseReportMode.sgr => _decMode(1006, true),
      MouseReportMode.urxvt => _decMode(1015, true),
    };
    _seq(
      '${_decMode(1005, false)}${_decMode(1006, false)}'
      '${_decMode(1015, false)}${_decMode(1016, false)}$set',
    );
  }

  /// Sets or resets wheel-as-arrows on the alternate screen (DEC mode
  /// 1007).
  void setAltBufferMouseScrollMode(bool enabled) {
    _seq(_decMode(1007, enabled));
  }

  /// Sets or resets bracketed paste (DEC mode 2004).
  void setBracketedPasteMode(bool enabled) {
    _seq(_decMode(2004, enabled));
  }

  /// Does nothing, as in xterm (it handles unknown DEC modes).
  void setUnknownDecMode(int mode, bool enabled) {
    // no-op
  }

  /* Select Graphic Rendition (SGR) */

  /// Resets the text style (SGR 0).
  void resetCursorStyle() {
    _sgr('0');
  }

  /// Sets bold (SGR 1).
  void setCursorBold() {
    _sgr('1');
  }

  /// Sets faint (SGR 2).
  void setCursorFaint() {
    _sgr('2');
  }

  /// Sets italic (SGR 3).
  void setCursorItalic() {
    _sgr('3');
  }

  /// Sets underline (SGR 4).
  void setCursorUnderline() {
    _sgr('4');
  }

  /// Sets blink (SGR 5).
  void setCursorBlink() {
    _sgr('5');
  }

  /// Sets inverse video (SGR 7).
  void setCursorInverse() {
    _sgr('7');
  }

  /// Sets invisible (SGR 8).
  void setCursorInvisible() {
    _sgr('8');
  }

  /// Sets strikethrough (SGR 9).
  void setCursorStrikethrough() {
    _sgr('9');
  }

  /// Unsets bold only (SGR 22, then faint again if it was set).
  void unsetCursorBold() {
    _sgr(_vt.cursorSgrStyle.faint ? '22;2' : '22');
  }

  /// Unsets faint only (SGR 22, then bold again if it was set).
  void unsetCursorFaint() {
    _sgr(_vt.cursorSgrStyle.bold ? '22;1' : '22');
  }

  /// Unsets italic (SGR 23).
  void unsetCursorItalic() {
    _sgr('23');
  }

  /// Unsets underline (SGR 24).
  void unsetCursorUnderline() {
    _sgr('24');
  }

  /// Unsets blink (SGR 25).
  void unsetCursorBlink() {
    _sgr('25');
  }

  /// Unsets inverse video (SGR 27).
  void unsetCursorInverse() {
    _sgr('27');
  }

  /// Unsets invisible (SGR 28).
  void unsetCursorInvisible() {
    _sgr('28');
  }

  /// Unsets strikethrough (SGR 29).
  void unsetCursorStrikethrough() {
    _sgr('29');
  }

  /// Sets the foreground to named colour [color] (0–15).
  void setForegroundColor16(int color) {
    _sgr(_color16(color, normal: 30, bright: 90, extended: 38));
  }

  /// Sets the foreground to palette colour [index] (0–255).
  void setForegroundColor256(int index) {
    if (index < 0 || index > 255) return;
    _sgr('38;5;$index');
  }

  /// Sets the foreground to the RGB colour [r], [g], [b].
  void setForegroundColorRgb(int r, int g, int b) {
    _sgr('38;2;${r & 0xff};${g & 0xff};${b & 0xff}');
  }

  /// Resets the foreground to the default colour (SGR 39).
  void resetForeground() {
    _sgr('39');
  }

  /// Sets the background to named colour [color] (0–15).
  void setBackgroundColor16(int color) {
    _sgr(_color16(color, normal: 40, bright: 100, extended: 48));
  }

  /// Sets the background to palette colour [index] (0–255).
  void setBackgroundColor256(int index) {
    if (index < 0 || index > 255) return;
    _sgr('48;5;$index');
  }

  /// Sets the background to the RGB colour [r], [g], [b].
  void setBackgroundColorRgb(int r, int g, int b) {
    _sgr('48;2;${r & 0xff};${g & 0xff};${b & 0xff}');
  }

  /// Resets the background to the default colour (SGR 49).
  void resetBackground() {
    _sgr('49');
  }

  /// Does nothing, as in xterm (it handles unsupported SGR parameters).
  void unsupportedStyle(int param) {
    // no-op
  }

  /* OSC */

  /// Sets the window title (OSC 2), which calls [onTitleChange]. Control
  /// characters in [name] are dropped.
  void setTitle(String name) {
    _seq('\x1b]2;${printableText(name)}\x1b\\');
  }

  /// Calls [onIconChange] with [name], as xterm does.
  void setIconName(String name) {
    onIconChange?.call(name);
  }

  /// Calls [onPrivateOSC] with [code] and [args], as xterm does.
  void unknownOSC(String code, List<String> args) {
    onPrivateOSC?.call(code, args);
  }

  /* Engine plumbing */

  /// Writes [data] to libghostty-vt, then delivers the events it raised.
  void _feed(Uint8List data) {
    _controller.writeBytes(data);
    _engine.invalidate();
    _drain();
  }

  /// Emulates an xterm handler method with [sequence]; see
  /// [TerminalEngine.writeSequence].
  void _writeSequence(String sequence) {
    if (!_vt.isVtGround) {
      throw StateError(
        "the program's output stopped inside an escape sequence; write the "
        'rest of it before calling this method',
      );
    }
    if (sequence.isEmpty) return;
    _feed(utf8.encode(sequence));
  }

  void _seq(String sequence) => _engine.writeSequence(sequence);

  void _sgr(String parameters) => _seq('\x1b[${parameters}m');

  void _countSeq(int count, String finalByte) {
    if (count <= 0) return;
    _seq('\x1b[$count$finalByte');
  }

  static String _decMode(int mode, bool enabled) =>
      '\x1b[?$mode${enabled ? 'h' : 'l'}';

  static String _moveX(int offset) => offset > 0
      ? '\x1b[${offset}C'
      : offset < 0
      ? '\x1b[${-offset}D'
      : '';

  static String _moveY(int offset) => offset > 0
      ? '\x1b[${offset}B'
      : offset < 0
      ? '\x1b[${-offset}A'
      : '';

  static String _color16(
    int color, {
    required int normal,
    required int bright,
    required int extended,
  }) {
    if (color >= 0 && color < 8) return '${normal + color}';
    if (color >= 8 && color < 16) return '${bright + color - 8}';
    if (color >= 16 && color < 256) return '$extended;5;$color';
    return '';
  }

  int _scrollbackLines(int rows) => max(maxLines - rows, 0);

  void _applyScrollbackLimit() {
    if (_engine.isDisposed) return;
    _vt.scrollbackMaxLines = _scrollbackLines(_vt.rows);
  }

  /// Sends [data], produced in Dart, to the program.
  void _emit(String data) {
    final onOutputBytes = this.onOutputBytes;
    if (onOutputBytes != null) onOutputBytes(utf8.encode(data));
    onOutput?.call(data);
  }

  /// Sends [data], produced by libghostty-vt, to the program.
  void _onEngineOutput(Uint8List data) {
    onOutputBytes?.call(data);
    final onOutput = this.onOutput;
    if (onOutput == null) return;
    String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      text = latin1.decode(data);
    }
    onOutput(text);
  }

  void _onEngineResize(int cols, int rows, int pixelWidth, int pixelHeight) {
    _applyScrollbackLimit();
    _engine.invalidate();
    if (_resizing) return;
    final ratio = _internals.viewDevicePixelRatio;
    int cell(int pixels, int cells) =>
        ratio == null || pixels <= 0 ? 0 : (pixels / cells / ratio).round();
    onResize?.call(cols, rows, cell(pixelWidth, cols), cell(pixelHeight, rows));
  }

  void _onEngineBell() => onBell?.call();

  void _onEngineTitle(String title) => onTitleChange?.call(title);

  void _queueUnknownSequence(UnknownSequence sequence) {
    if (sequence is! UnknownOscSequence) return;
    final parts = sequence.text.split(';');
    _pending.add(() => onPrivateOSC?.call(parts.first, parts.sublist(1)));
  }

  void _queueResizeWindow(ResizeWindowRequest request) {
    _pending.add(() {
      if (_engine.isDisposed) return;
      resize(request.columns ?? viewWidth, request.rows ?? viewHeight);
    });
  }

  /// Delivers the events queued during writes, in order. Events raised by
  /// a callback (one that writes again) are delivered by the same loop.
  void _drain() {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty && !_engine.isDisposed) {
        _pending.removeFirst()();
      }
    } finally {
      _draining = false;
    }
  }
}

final class _TerminalInternals implements TerminalInternals {
  _TerminalInternals(this.vtController);

  @override
  final VtTerminalController vtController;

  @override
  double? viewDevicePixelRatio;
}
