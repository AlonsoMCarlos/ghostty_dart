/// The terminal emulator: [VtTerminal], its state, options, viewport
/// scrolling, stoppable writes, continuations, compression and paste.
///
/// This file is also the terminal module barrel.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import 'cursor.dart';
import 'kitty_keyboard_flags.dart';
import 'memory.dart';
import 'memory_native.dart';
import 'mouse_shape.dart';
import 'paste.dart';
import 'paste_native.dart';
import 'terminal_native.dart';
import 'viewport.dart';
import 'viewport_native.dart';
import 'write_stop.dart';
import 'write_stop_native.dart';

export 'cursor.dart' show TerminalCursor;
export 'effects.dart'
    show
        ClipboardContent,
        ClipboardReadReply,
        ClipboardReadRequest,
        ClipboardReadResult,
        ClipboardWriteReply,
        ClipboardWriteRequest,
        ClipboardWriteResult,
        DesktopNotification,
        DeviceAttributes,
        ProgramStatus,
        ProgramStatusKind,
        ProgramStatusState,
        ProgressReport,
        ProgressState,
        PromptKind,
        ResizeWindowRequest,
        SemanticPromptEvent,
        SemanticPromptKind,
        UnknownApcSequence,
        UnknownOscSequence,
        UnknownSequence,
        VtTerminalEffects;
export 'kitty_keyboard_flags.dart' show KittyKeyboardFlags;
export 'memory.dart'
    show
        CompressionMode,
        CompressionResult,
        ScreenMemoryUsage,
        TerminalMemoryUsage;
export 'mouse_shape.dart' show MouseShape;
export 'paste.dart' show ClipboardLocation, PasteResult, PasteSource;
export 'viewport.dart'
    show
        ScrollByPrompts,
        ScrollByRows,
        ScrollToBottom,
        ScrollToRow,
        ScrollToTop,
        ViewportScroll,
        ViewportScrollbar;
export 'write_stop.dart'
    show
        ControlStringEnd,
        ControlStringIntroducer,
        ControlStringKind,
        WriteBoundaries,
        WriteStop;

typedef _Data = GhosttyTerminalData;
typedef _Option = GhosttyTerminalOption;

/// A complete terminal emulator (`GhosttyTerminal`): write VT data into it and
/// it keeps the screen, scrollback, cursor, styles and modes.
///
/// It does not draw and does not talk to a pty; both are up to you.
///
/// ```dart
/// final terminal = VtTerminal(cols: 80, rows: 24);
/// terminal.write(utf8.encode('\x1b]0;my title\x07Hello, \x1b[1mworld\x1b[0m!'));
/// print(terminal.title);    // my title
/// print(terminal.cursorX);  // 13
/// terminal.resize(100, 30);
/// terminal.dispose();
/// ```
///
/// ## State and options
///
/// Getters read the library on every call, so they always reflect the
/// latest [write]. Use [cursor] to read the whole cursor in one native
/// call.
///
/// Options configure the terminal (scrollback limits, default colours,
/// modes, security-sensitive reports, ...); each documents the default it
/// starts with. An option the library can report back is a read/write
/// property (`terminal.scrollbackMaxBytes = null`); a write-only option is
/// a `set…` method (`terminal.setTitleReportEnabled(true)`), as is a keyed
/// one ([setMode]). Callbacks for what programs ask of the terminal (pty
/// replies, bell, title changes, clipboard, ...) are separate.
///
/// ## Ownership
///
/// The terminal owns its native memory. Call [dispose] when done; a
/// finalizer frees it if you forget, but disposing promptly releases the
/// (possibly large) scrollback deterministically. After [dispose], every
/// member except [isDisposed] and [dispose] throws [StateError].
///
/// Objects that borrow a terminal (render states, formatters, searches,
/// ...) keep a reference to it, so it is not garbage collected while they
/// are alive. Disposing the terminal disposes them first.
final class VtTerminal implements Finalizable {
  /// Creates a terminal of [cols] × [rows] cells, each 1–65535.
  ///
  /// Throws [RangeError] for out-of-range sizes, [GhosttyException] if the
  /// library fails to allocate it, and [IncompatibleLibraryException] if the
  /// loaded libghostty-vt is not a supported 1.x version.
  VtTerminal({required int cols, required int rows})
    : _handle = _create(cols, rows) {
    bindHandle(this, _handle);
  }

  /// Takes ownership of a terminal the library created elsewhere (a
  /// decoded snapshot), with the same handle and finalizer as [VtTerminal.new].
  /// Reached through [adoptNativeTerminal] (contratos.md §9b).
  VtTerminal._adopt(Pointer<GhosttyTerminalImpl> pointer)
    : _handle = NativeHandle(
        pointer,
        typeName: 'VtTerminal',
        free: (p) => ghostty_terminal_free(p),
        finalizer: _finalizer,
      ) {
    bindHandle(this, _handle);
  }

  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyTerminal)>>(
      ghostty_terminal_free,
    ).cast(),
  );

  static NativeHandle<GhosttyTerminalImpl> _create(int cols, int rows) {
    _checkCells(cols, 'cols');
    _checkCells(rows, 'rows');
    final pointer = createNative<GhosttyTerminalImpl>(
      'ghostty_terminal_new',
      (out) => ghostty_terminal_new(nullptr, out, cols, rows),
    );
    return NativeHandle(
      pointer,
      typeName: 'VtTerminal',
      free: (p) => ghostty_terminal_free(p),
      finalizer: _finalizer,
    );
  }

  static void _checkCells(int value, String name) =>
      RangeError.checkValueInInterval(value, 1, 0xFFFF, name);

  /// The scrollback byte limit a new terminal starts with
  /// ([scrollbackMaxBytes]).
  static const defaultScrollbackMaxBytes = 10000;

  /// The Kitty image storage limit a new terminal starts with
  /// ([kittyImageStorageLimit]), 10 MB.
  static const defaultKittyImageStorageLimit = 10000000;

  /// The Kitty clipboard write limit a new terminal starts with
  /// ([clipboardWriteMaxBytes]), 64 MiB.
  static const defaultClipboardWriteMaxBytes = 64 * 1024 * 1024;

  /// The longest terminfo name [setTerminfoName] accepts, in UTF-8 bytes.
  static const maxTerminfoNameBytes = 128;

  final NativeHandle<GhosttyTerminalImpl> _handle;

  /// The cell size last passed to `ghostty_terminal_resize`, or `null`
  /// before the first [resize] (then derived from the library, see
  /// [_currentCellSize]). Kept in Dart because the library only stores the
  /// total pixel size, and DECCOLM changes the column count without
  /// updating it, so total ÷ cols would no longer give the cell width.
  int? _cellWidthPx;
  int? _cellHeightPx;

  /// Whether [dispose] has been called.
  bool get isDisposed => _handle.isDisposed;

  // Members live on the class, not in extensions, so `show VtTerminal`
  // imports and dartdoc see them all. Bodies longer than a few lines live in
  // the internal `*_native.dart` file of their concern (memory, viewport,
  // write_stop, paste); typed get/set plumbing is in `terminal_native.dart`.
  // Later tasks add members through extensions (contratos.md §9).

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Feeds raw VT-encoded [bytes] (usually pty output) to the terminal.
  ///
  /// Never fails on malformed input: the library treats the stream as
  /// untrusted and keeps the terminal consistent. Sequences can span calls.
  /// Terminal callbacks run synchronously inside this call.
  ///
  /// To pause at control-string boundaries or at a safe insertion point,
  /// use [writeUntil] or [writeWithStops] instead.
  ///
  /// Throws [StateError] if called from inside a callback of this same
  /// terminal (the library is not reentrant), or after [dispose].
  void write(Uint8List bytes) {
    checkNotInCallback(_handle, 'write');
    if (bytes.isEmpty) {
      _handle.checkNotDisposed();
      return;
    }
    _handle.use((terminal) {
      withNativeBytes(bytes, (data, length) {
        ghostty_terminal_vt_write(terminal, data, length);
      });
    });
    _handle.bumpEpoch();
  }

  /// Resizes the terminal to [cols] × [rows] cells (each 1–65535).
  ///
  /// [cellWidthPx] and [cellHeightPx] set the size of one cell in pixels,
  /// used by image protocols and size reports; when omitted, the current
  /// cell size is kept (0 × 0 for a new terminal). The primary screen
  /// reflows when wraparound is on; the alternate screen does not.
  /// Synchronized output is turned off and, if mode 2048 is on, an in-band
  /// size report is sent. See [setResizePullScrollback] for how growing
  /// interacts with scrollback.
  ///
  /// Throws [RangeError] for out-of-range values and [GhosttyException] if
  /// the library fails.
  void resize(int cols, int rows, {int? cellWidthPx, int? cellHeightPx}) {
    _checkCells(cols, 'cols');
    _checkCells(rows, 'rows');
    if (cellWidthPx != null) _checkPixels(cellWidthPx, 'cellWidthPx');
    if (cellHeightPx != null) _checkPixels(cellHeightPx, 'cellHeightPx');
    final width =
        cellWidthPx ?? _cellWidthPx ?? _currentCellSize(horizontal: true);
    final height =
        cellHeightPx ?? _cellHeightPx ?? _currentCellSize(horizontal: false);
    // Record the cell size before the native call: a callback fired inside
    // it (render hold, in-band size report) may resize again, and the
    // innermost resize is the one the library keeps.
    final (previousWidth, previousHeight) = (_cellWidthPx, _cellHeightPx);
    _cellWidthPx = width;
    _cellHeightPx = height;
    final result = _handle.use(
      (terminal) =>
          ghostty_terminal_resize(terminal, cols, rows, width, height),
    );
    _handle.bumpEpoch();
    if (decodeResult(result).isError) {
      _cellWidthPx = previousWidth;
      _cellHeightPx = previousHeight;
    }
    checkResult(result, 'ghostty_terminal_resize');
  }

  /// Performs a full reset (RIS): modes, scrollback, scrolling region,
  /// screen contents, title and working directory return to their initial
  /// state. The size, the cell pixel size and options set with the setters
  /// of this class (e.g. [setResizePullScrollback], mode defaults from
  /// [setModeDefault]) are kept.
  ///
  /// Terminal callbacks may run inside this call (e.g. a render hold
  /// ending). Throws [StateError] after [dispose].
  void reset() {
    _handle.use(ghostty_terminal_reset);
    _handle.bumpEpoch();
  }

  /// Frees the terminal. Safe to call more than once.
  ///
  /// If called from inside a terminal callback, the terminal is marked
  /// disposed at once and freed when the native call returns.
  void dispose() => _handle.dispose();

  // -------------------------------------------------------------------------
  // Size
  // -------------------------------------------------------------------------

  /// The width of the terminal in cells.
  ///
  /// Read from the library on every call: programs can change it (e.g. with
  /// DECCOLM), not only [resize].
  int get cols => readUint16(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_COLS);

  /// The height of the terminal in cells.
  int get rows => readUint16(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_ROWS);

  /// The total width in pixels: [cols] × the cell width given to [resize]
  /// (0 until a cell size is set).
  int get widthPx =>
      readUint32(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_WIDTH_PX);

  /// The total height in pixels: [rows] × the cell height given to
  /// [resize] (0 until a cell size is set).
  int get heightPx =>
      readUint32(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_HEIGHT_PX);

  // -------------------------------------------------------------------------
  // Cursor
  // -------------------------------------------------------------------------

  /// The cursor column, 0-based. See also [cursor].
  int get cursorX =>
      readUint16(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_CURSOR_X);

  /// The cursor row within the active area, 0-based. See also [cursor].
  int get cursorY =>
      readUint16(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_CURSOR_Y);

  /// Whether the cursor is visible (DEC mode 25, DECTCEM).
  bool get isCursorVisible =>
      readBool(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE);

  /// Whether the next printed character soft-wraps first (the cursor is
  /// past the last column).
  bool get hasCursorPendingWrap => readBool(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP,
  );

  /// The SGR style (bold, colours, ...) applied to newly printed
  /// characters. Not the cursor's shape.
  CellStyle get cursorSgrStyle => readData(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_CURSOR_SGR_STYLE,
    sizeOf<GhosttyStyle>(),
    (out) => cellStyleFromNative(out.cast<GhosttyStyle>().ref),
  );

  /// Whether the cursor is at a shell prompt or its input area, according
  /// to semantic prompt markers (OSC 133). `false` without markers or on
  /// the alternate screen.
  bool get isCursorAtPrompt =>
      readBool(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT);

  /// The whole cursor ([cursorX], [cursorY], [isCursorVisible],
  /// [hasCursorPendingWrap], [cursorSgrStyle]) in one native call.
  TerminalCursor get cursor => readMulti(
    _handle.pointer,
    [
      (key: _Data.GHOSTTY_TERMINAL_DATA_CURSOR_X, size: sizeOf<Uint16>()),
      (key: _Data.GHOSTTY_TERMINAL_DATA_CURSOR_Y, size: sizeOf<Uint16>()),
      (key: _Data.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, size: sizeOf<Bool>()),
      (
        key: _Data.GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP,
        size: sizeOf<Bool>(),
      ),
      (
        key: _Data.GHOSTTY_TERMINAL_DATA_CURSOR_SGR_STYLE,
        size: sizeOf<GhosttyStyle>(),
      ),
    ],
    (out) => TerminalCursor(
      x: out[0].cast<Uint16>().value,
      y: out[1].cast<Uint16>().value,
      isVisible: out[2].cast<Bool>().value,
      hasPendingWrap: out[3].cast<Bool>().value,
      style: cellStyleFromNative(out[4].cast<GhosttyStyle>().ref),
    ),
  );

  /// Sets the cursor shape that DECSCUSR reset (`CSI 0 q`) goes back to;
  /// `null` restores the built-in [VtCursorStyle.block].
  ///
  /// Throws [ArgumentError] for [VtCursorStyle.unknown].
  void setDefaultCursorStyle(VtCursorStyle? style) => setEnumOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE,
    style == null ? null : vtCursorStyleCodec.encode(style),
  );

  /// Sets whether the cursor blinks after DECSCUSR reset (`CSI 0 q`);
  /// `null` restores the built-in default (not blinking).
  void setDefaultCursorBlink(bool? blink) => setBoolOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK,
    blink,
  );

  // -------------------------------------------------------------------------
  // Screen, title, working directory
  // -------------------------------------------------------------------------

  /// Which screen is active: the primary one or the alternate one used by
  /// full-screen programs (`CSI ? 1049 h`).
  TerminalScreen get activeScreen => terminalScreenCodec.decode(
    readEnum(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN),
  );

  /// The window title set by programs (OSC 0/2) or by this setter; `''`
  /// when none has been set.
  ///
  /// Setting it copies the string into the terminal; `''` clears it.
  String get title =>
      readString(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_TITLE);

  set title(String value) =>
      setStringOption(_handle, _Option.GHOSTTY_TERMINAL_OPT_TITLE, value);

  /// The working directory reported by programs (OSC 7, ...) or set here;
  /// `''` when none has been set.
  ///
  /// Setting it copies the string into the terminal; `''` clears it.
  String get pwd =>
      readString(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_PWD);

  set pwd(String value) =>
      setStringOption(_handle, _Option.GHOSTTY_TERMINAL_OPT_PWD, value);

  /// Whether VT processing hit an error it could not handle gracefully,
  /// which may have dropped a state update. Informational only; it is never
  /// cleared, not even by [reset]. Malformed or unsupported input does not
  /// set it.
  bool get hasVtProcessingError => readBool(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR,
  );

  /// Whether the VT stream is at ground: not inside any escape sequence or
  /// partial UTF-8 character. A safe point to [write] your own sequences.
  bool get isVtGround =>
      readBool(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_VT_GROUND);

  // -------------------------------------------------------------------------
  // Modes
  // -------------------------------------------------------------------------

  /// Whether [mode] is currently set.
  ///
  /// Throws [GhosttyException] ([GhosttyResultCode.invalidValue]) for a
  /// mode the library does not know, and [RangeError] if
  /// [TerminalMode.value] is outside 0–32767.
  bool isModeEnabled(TerminalMode mode) =>
      readMode(_handle.pointer, _rawMode(mode));

  /// Sets or resets [mode] now, as `CSI ? n h` / `CSI ? n l` would. A
  /// later [reset] (or DECSTR) restores its reset default.
  ///
  /// Throws [GhosttyException] for a mode the library does not know, and
  /// [RangeError] if [TerminalMode.value] is outside 0–32767.
  void setMode(TerminalMode mode, {required bool enabled}) => setModeOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_MODE,
    _rawMode(mode),
    enabled,
  );

  /// Sets both the current value of [mode] and the value a reset restores
  /// (RIS restores every mode; DECSTR only some).
  ///
  /// Throws [GhosttyException] ([GhosttyResultCode.invalidValue]) for an
  /// unknown mode or one that cannot have a reset default (modes that are
  /// transitions or mirror other state, e.g. the alternate screen), and
  /// [RangeError] if [TerminalMode.value] is outside 0–32767.
  void setModeDefault(TerminalMode mode, {required bool enabled}) =>
      setModeOption(
        _handle,
        _Option.GHOSTTY_TERMINAL_OPT_MODE_DEFAULT,
        _rawMode(mode),
        enabled,
      );

  /// Whether any mouse tracking mode (X10 9, normal 1000, button 1002 or
  /// any-event 1003) is on, i.e. mouse events should go to the program.
  bool get isMouseTracking =>
      readBool(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING);

  /// The mouse pointer shape the program asked for with OSC 22;
  /// [MouseShape.text] initially.
  MouseShape get mouseShape => mouseShapeCodec.decode(
    readEnum(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE),
  );

  /// The Kitty keyboard protocol flags currently pushed by the program
  /// (`CSI > flags u`); [KittyKeyboardFlags.disabled] for legacy encoding.
  KittyKeyboardFlags get kittyKeyboardFlags => KittyKeyboardFlags.fromValue(
    readUint8(
      _handle.pointer,
      _Data.GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS,
    ),
  );

  // -------------------------------------------------------------------------
  // Colours
  // -------------------------------------------------------------------------

  /// The effective default foreground colour: a program's OSC 10 override,
  /// else [colorForegroundDefault]. `null` if neither is set.
  RgbColor? get colorForeground =>
      tryReadRgb(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND);

  /// The effective default background colour: a program's OSC 11 override,
  /// else [colorBackgroundDefault]. `null` if neither is set.
  RgbColor? get colorBackground =>
      tryReadRgb(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND);

  /// The effective cursor colour: a program's OSC 12 override, else
  /// [colorCursorDefault]. `null` if neither is set.
  RgbColor? get colorCursor =>
      tryReadRgb(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_COLOR_CURSOR);

  /// The effective 256-colour palette, including programs' OSC 4
  /// overrides. Unmodifiable, 256 entries.
  List<RgbColor> get colorPalette =>
      readPalette(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE);

  /// Your default foreground colour, ignoring program overrides; `null`
  /// (the initial value) when unset. Setting `null` unsets it.
  ///
  /// Throws [RangeError] when setting a colour component outside 0–255.
  RgbColor? get colorForegroundDefault => tryReadRgb(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT,
  );

  set colorForegroundDefault(RgbColor? color) => setRgbOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
    color,
  );

  /// Your default background colour, ignoring program overrides; `null`
  /// (the initial value) when unset. Setting `null` unsets it.
  ///
  /// Throws [RangeError] when setting a colour component outside 0–255.
  RgbColor? get colorBackgroundDefault => tryReadRgb(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT,
  );

  set colorBackgroundDefault(RgbColor? color) => setRgbOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
    color,
  );

  /// Your default cursor colour, ignoring program overrides; `null` (the
  /// initial value) when unset. Setting `null` unsets it.
  ///
  /// Throws [RangeError] when setting a colour component outside 0–255.
  RgbColor? get colorCursorDefault => tryReadRgb(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT,
  );

  set colorCursorDefault(RgbColor? color) =>
      setRgbOption(_handle, _Option.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, color);

  /// Your default 256-colour palette, ignoring program overrides.
  /// Unmodifiable, 256 entries; the built-in palette initially.
  ///
  /// Setting it copies the list, which must have exactly 256 entries
  /// ([ArgumentError] otherwise); `null` restores the built-in palette.
  List<RgbColor> get colorPaletteDefault => readPalette(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,
  );

  set colorPaletteDefault(List<RgbColor>? palette) => setPaletteOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,
    palette,
  );

  // -------------------------------------------------------------------------
  // Scrollback and viewport
  // -------------------------------------------------------------------------

  /// The number of rows of the active screen, scrollback included.
  int get totalRows =>
      readSize(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);

  /// The number of scrollback rows ([totalRows] minus [rows]).
  int get scrollbackRows =>
      readSize(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS);

  /// The state a scrollbar needs. Cheap (amortized O(1)); poll it once per
  /// frame and compare with `==`, as there is no change notification.
  ViewportScrollbar get scrollbar => readScrollbar(_handle.pointer);

  /// Whether the viewport follows the active area (`false` once scrolled
  /// into history).
  bool get isViewportActive =>
      readBool(_handle.pointer, _Data.GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE);

  /// Moves the viewport, e.g. `ViewportScroll.delta(-5)` for 5 rows up.
  /// See [ViewportScroll] for the targets.
  ///
  /// Throws [RangeError] for a negative [ScrollToRow.row].
  void scrollViewport(ViewportScroll target) =>
      scrollViewportTo(_handle, target);

  /// The scrollback byte limit, or `null` for no limit;
  /// [defaultScrollbackMaxBytes] initially. Always the primary screen's
  /// limit, even while the alternate screen is active.
  ///
  /// The limit is approximate: history is kept in whole pages (~400 KB),
  /// so the default rounds up to one page. When both this and
  /// [scrollbackMaxLines] are set, the first one reached applies. Lowering
  /// it drops eligible history at once; `0` disables scrollback and erases
  /// it. Setting `null` removes the limit. Throws [RangeError] for a
  /// negative value.
  int? get scrollbackMaxBytes => tryReadSize(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES,
  );

  set scrollbackMaxBytes(int? bytes) => setSizeOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
    _sizeOrUnlimited(bytes, 'bytes'),
  );

  /// The scrollback line limit, or `null` for no limit (the initial
  /// value). Always the primary screen's limit.
  ///
  /// Approximate: lines are pruned in whole pages, so usually dozens to
  /// about a hundred more lines are kept. When both this and
  /// [scrollbackMaxBytes] are set, the first one reached applies. Lowering
  /// it drops eligible history at once. Setting `null` removes the limit.
  /// Throws [RangeError] for a negative value.
  int? get scrollbackMaxLines => tryReadSize(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES,
  );

  set scrollbackMaxLines(int? lines) => setSizeOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
    _sizeOrUnlimited(lines, 'lines'),
  );

  /// Sets whether [resize] may pull rows from scrollback back into the
  /// active area (the default, `true`).
  ///
  /// When `false`, growing always appends blank rows and a reflow keeps
  /// the top of the active area on the same content. Use `false` when the
  /// pty keeps its own screen without scrollback (Windows ConPTY). Kept
  /// across [reset].
  void setResizePullScrollback(bool enabled) => setBoolOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK,
    enabled,
  );

  // -------------------------------------------------------------------------
  // Memory and compression
  // -------------------------------------------------------------------------

  /// How much memory the terminal holds, per screen.
  ///
  /// Looks at every page (without decompressing), so avoid reading it after
  /// every write.
  TerminalMemoryUsage get memoryUsage => readMemoryUsage(_handle.pointer);

  /// An opaque token that changes whenever new compression work may be
  /// possible. Only `==` is meaningful (it may wrap).
  ///
  /// Cache it and restart your idle delay before [compress] whenever it
  /// changes.
  int get compressionActivity => readCompressionActivity(_handle.pointer);

  /// Compresses eligible scrollback to save memory, and says what to do
  /// next.
  ///
  /// [CompressionMode.incremental] does bounded work for an idle callback:
  /// repeat while the result is [CompressionResult.pending]. After
  /// [CompressionResult.complete], wait until [compressionActivity]
  /// changes. Only the storage changes, never the contents; compressed
  /// history is restored transparently when read.
  CompressionResult compress([
    CompressionMode mode = CompressionMode.incremental,
  ]) => compressTerminal(_handle, mode);

  // -------------------------------------------------------------------------
  // Stoppable writes and continuations
  // -------------------------------------------------------------------------

  /// Writes `bytes[start..end)` like [write], but stops right after the
  /// first byte that reaches one of [boundaries], and reports where.
  ///
  /// Only the consumed bytes are processed (and only their callbacks run);
  /// pass the rest, from `start + stop.consumed`, in your next call. Every
  /// byte eventually consumed leaves the terminal as [write] would.
  ///
  /// Typical use: wait for a safe point before inserting your own
  /// sequences:
  ///
  /// ```dart
  /// final stop = terminal.writeUntil(chunk, WriteBoundaries.ground);
  /// terminal.write(myOwnSequence);           // stream is at ground now
  /// terminal.write(Uint8List.sublistView(chunk, stop.consumed));
  /// ```
  ///
  /// With [WriteBoundaries.ground], a stream already at ground stops at
  /// once with [WriteStop.consumed] 0. To find every control string in a
  /// chunk, prefer [writeWithStops], which copies the input once.
  ///
  /// Throws [ArgumentError] if [boundaries] is empty or has unknown flags,
  /// [RangeError] for an invalid range, and [StateError] from inside a
  /// callback of this terminal or after [dispose].
  WriteStop writeUntil(
    Uint8List bytes,
    WriteBoundaries boundaries, {
    int start = 0,
    int? end,
  }) => writeUntilInto(_handle, bytes, boundaries, start: start, end: end);

  /// Writes all of [bytes] like [write], calling [onStop] each time a byte
  /// reaches one of [boundaries], with the stop and the offset in [bytes]
  /// just after the stopping byte.
  ///
  /// [onStop] runs between native calls, so it may [write] (e.g. a reply
  /// or a rewritten string). Return `false` to stop early; the method then
  /// returns the offset where it stopped, and the bytes from there on have
  /// not been written. Otherwise it returns `bytes.length`. If [onStop]
  /// disposes the terminal, the method stops there.
  ///
  /// ```dart
  /// terminal.writeWithStops(chunk, WriteBoundaries.oscStart |
  ///     WriteBoundaries.oscEnd, (stop, offset) {
  ///   print('${stop.reached} at $offset');
  ///   return true;
  /// });
  /// ```
  ///
  /// [WriteBoundaries.ground] is not accepted here, because ground is a
  /// state that holds after almost every byte of plain text; use
  /// [writeUntil] to wait for it.
  ///
  /// Throws [ArgumentError] if [boundaries] is empty, has unknown flags or
  /// includes [WriteBoundaries.ground], and [StateError] from inside a
  /// callback of this terminal or after [dispose].
  int writeWithStops(
    Uint8List bytes,
    WriteBoundaries boundaries,
    bool Function(WriteStop stop, int offset) onStop,
  ) => writeWithStopsInto(_handle, bytes, boundaries, onStop);

  /// The bytes needed to rebuild the parser state left unfinished by the
  /// last write (an escape sequence or UTF-8 character cut in the middle),
  /// so an equivalent terminal can continue the stream. Empty at ground.
  ///
  /// `null` when continuation tracking is off (see [continuationMaxBytes])
  /// or the current continuation is unavailable (tracking started, or its
  /// limit was lowered, mid-sequence; it recovers after a later write
  /// reaches ground or starts a fresh sequence).
  ///
  /// Throws [StateError] from inside a callback of this terminal or after
  /// [dispose].
  Uint8List? get continuation => readContinuation(_handle);

  /// The most bytes of unfinished sequence kept for [continuation]; 0 (the
  /// initial value) disables tracking.
  ///
  /// Set it before writing the input you want to capture. Lowering it below
  /// the retained continuation, or enabling it mid-sequence, makes the
  /// current continuation unavailable until the stream recovers. Throws
  /// [RangeError] for a negative value.
  int get continuationMaxBytes => readSize(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_CONTINUATION_MAX_BYTES,
  );

  set continuationMaxBytes(int bytes) => setSizeOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
    RangeError.checkNotNegative(bytes, 'bytes'),
  );

  // -------------------------------------------------------------------------
  // Paste
  // -------------------------------------------------------------------------

  /// Pastes clipboard content into the program, according to the
  /// terminal's modes: as a Kitty clipboard paste event if mode 5522 is on
  /// and a clipboard-read callback is installed, otherwise as text framed
  /// for bracketed paste (mode 2004) or not.
  ///
  /// [mimeTypes] lists the available representations, preferred first. A
  /// text paste asks [read] for exactly one of them (the first text type,
  /// e.g. `text/plain`); a paste event reads none. [read] returns the bytes,
  /// or `null` if they cannot be read (the paste then fails with a
  /// [GhosttyException], [GhosttyResultCode.ioError]). Exceptions thrown
  /// by [read] are rethrown. The output goes to the pty through the
  /// write-pty callback; the viewport is not scrolled.
  ///
  /// Returns [PasteResult.rejected] when the text could inject commands
  /// and [allowUnsafe] is `false`: confirm with the user, then paste again
  /// with `allowUnsafe: true`. [location] is reported to the program on a
  /// paste event; [source] says why the paste happened.
  ///
  /// Throws [GhosttyException] ([GhosttyResultCode.invalidValue]) if no
  /// write-pty callback is installed, [ArgumentError] for
  /// [ClipboardLocation.unknown], and [StateError] from inside a callback of
  /// this terminal or after [dispose].
  PasteResult paste({
    required List<String> mimeTypes,
    required Uint8List? Function(String mimeType) read,
    ClipboardLocation location = ClipboardLocation.standard,
    PasteSource source = PasteSource.clipboard,
    bool allowUnsafe = false,
  }) {
    checkNotInCallback(_handle, 'paste');
    return pasteInto(
      _handle,
      mimeTypes: mimeTypes,
      read: read,
      location: location,
      source: source,
      allowUnsafe: allowUnsafe,
    );
  }

  /// Pastes [text] as `text/plain`. Same rules and results as [paste].
  PasteResult pasteText(
    String text, {
    ClipboardLocation location = ClipboardLocation.standard,
    PasteSource source = PasteSource.clipboard,
    bool allowUnsafe = false,
  }) => paste(
    mimeTypes: const ['text/plain'],
    read: (_) => utf8.encode(text),
    location: location,
    source: source,
    allowUnsafe: allowUnsafe,
  );

  // -------------------------------------------------------------------------
  // Protocol limits and security-sensitive reports
  // -------------------------------------------------------------------------

  /// Sets the most bytes buffered for any APC sequence (protection against
  /// unbounded memory from malicious input); `null` removes every APC
  /// override, including [setKittyApcMaxBytes]. Throws [RangeError] for a
  /// negative value.
  void setApcMaxBytes(int? bytes) => setSizeOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES,
    bytes == null ? null : RangeError.checkNotNegative(bytes, 'bytes'),
  );

  /// Sets the most bytes buffered for a Kitty graphics APC sequence; `null`
  /// restores the built-in limit. Throws [RangeError] for a negative value.
  void setKittyApcMaxBytes(int? bytes) => setSizeOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY,
    bytes == null ? null : RangeError.checkNotNegative(bytes, 'bytes'),
  );

  /// Sets the most bytes of each unsupported OSC/APC sequence kept for the
  /// unknown-sequence callback; 0 (the initial value) turns reporting off.
  ///
  /// Longer sequences are still reported, truncated. Up to 2048 bytes adds
  /// no allocation for OSC. Throws [RangeError] for a negative value.
  void setUnknownSequenceMaxBytes(int bytes) => setSizeOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES,
    RangeError.checkNotNegative(bytes, 'bytes'),
  );

  /// The most decoded bytes one Kitty clipboard (OSC 5522) write may
  /// buffer, or `null` for no limit; [defaultClipboardWriteMaxBytes]
  /// initially. Larger writes fail as a whole. Does not apply to OSC 52.
  ///
  /// A write in flight keeps the limit it started with. Setting `null`
  /// removes the limit. Throws [RangeError] for a negative value.
  int? get clipboardWriteMaxBytes {
    final value = readSize(
      _handle.pointer,
      _Data.GHOSTTY_TERMINAL_DATA_CLIPBOARD_WRITE_MAX_BYTES,
    );
    return value == sizeMax ? null : value;
  }

  set clipboardWriteMaxBytes(int? bytes) => setSizeOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES,
    _sizeOrUnlimited(bytes, 'bytes'),
  );

  /// Sets whether the terminal answers window title queries (`CSI 21 t`).
  ///
  /// Off by default: a program could set a title and read it back into the
  /// pty input, injecting commands.
  void setTitleReportEnabled(bool enabled) => setBoolOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_TITLE_REPORT,
    enabled,
  );

  /// Sets whether the terminal answers screen checksum requests (DECRQCRA,
  /// `CSI … * y`); while off, XTCHECKSUM is ignored too.
  ///
  /// Off by default: a program could checksum one cell at a time and so
  /// read everything on the screen, including other programs' output.
  void setXtChecksumReportEnabled(bool enabled) => setBoolOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_XT_CHECKSUM_REPORT,
    enabled,
  );

  /// Sets how DECRQCRA checksums are calculated, now and after a reset, as
  /// XTCHECKSUM bits (0–31): 1 don't negate, 2 don't add video attributes,
  /// 4 don't omit blanks, 8 count unwritten cells as spaces, 16 use full
  /// codepoints. 0 (the initial value) is a real DEC terminal.
  ///
  /// Throws [RangeError] outside 0–31.
  void setXtChecksumExtension(int bits) => setUint8Option(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_XT_CHECKSUM_EXTENSION,
    RangeError.checkValueInInterval(bits, 0, 31, 'bits'),
  );

  /// Sets the terminfo name reported for an XTGETTCAP `TN` query (e.g.
  /// `xterm-256color`); `null` or `''` clears it, and nothing is reported.
  ///
  /// Throws [ArgumentError] if longer than [maxTerminfoNameBytes] UTF-8
  /// bytes.
  void setTerminfoName(String? name) {
    if (name != null && utf8.encode(name).length > maxTerminfoNameBytes) {
      throw ArgumentError.value(
        name,
        'name',
        'must be at most $maxTerminfoNameBytes UTF-8 bytes',
      );
    }
    setStringOption(_handle, _Option.GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, name);
  }

  /// Sets whether the Glyph Protocol APC sequences are handled. Off by
  /// default (registered glyphs change what the terminal draws); turning it
  /// off also clears the session's registered glyphs.
  void setGlyphProtocolEnabled(bool enabled) => setBoolOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_GLYPH_PROTOCOL,
    enabled,
  );

  // -------------------------------------------------------------------------
  // Kitty graphics storage and media
  // -------------------------------------------------------------------------

  /// The Kitty image storage limit of the active screen in bytes;
  /// [defaultKittyImageStorageLimit] initially. 0 means the Kitty graphics
  /// protocol is disabled.
  ///
  /// Setting it applies to both screens; 0 disables the protocol and
  /// deletes every stored image. Throws [RangeError] for a negative value,
  /// and [UnsupportedError] if the library was built without Kitty graphics
  /// (see `libghosttyVtBuildInfo`).
  int get kittyImageStorageLimit => readUint64(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT,
  );

  set kittyImageStorageLimit(int bytes) => setUint64Option(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
    RangeError.checkNotNegative(bytes, 'bytes'),
  );

  /// Whether Kitty images may be loaded from files (off by default).
  ///
  /// Throws [UnsupportedError] if the library was built without Kitty
  /// graphics.
  bool get isKittyImageFileMediumEnabled => readBool(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_FILE,
  );

  set isKittyImageFileMediumEnabled(bool enabled) => setBoolOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,
    enabled,
  );

  /// The only directory Kitty images may be loaded from as temporary files,
  /// or `null` when that medium is disabled (the default). Setting `null`
  /// or `''` disables it.
  ///
  /// Throws [UnsupportedError] if the library was built without Kitty
  /// graphics.
  String? get kittyImageTempFileDirectory {
    final directory = readString(
      _handle.pointer,
      _Data.GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_TEMP_FILE,
    );
    return directory.isEmpty ? null : directory;
  }

  set kittyImageTempFileDirectory(String? directory) => setStringOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
    directory == null || directory.isEmpty ? null : directory,
  );

  /// Whether Kitty images may be loaded from shared memory (off by
  /// default).
  ///
  /// Throws [UnsupportedError] if the library was built without Kitty
  /// graphics.
  bool get isKittyImageSharedMemoryMediumEnabled => readBool(
    _handle.pointer,
    _Data.GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_SHARED_MEM,
  );

  set isKittyImageSharedMemoryMediumEnabled(bool enabled) => setBoolOption(
    _handle,
    _Option.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM,
    enabled,
  );

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  static void _checkPixels(int value, String name) =>
      RangeError.checkValueInInterval(value, 0, 0xFFFFFFFF, name);

  static int _rawMode(TerminalMode mode) {
    RangeError.checkValueInInterval(mode.value, 0, 0x7FFF, 'mode.value');
    return terminalModeToRaw(mode);
  }

  /// Maps a nullable limit to `size_t`: `null` is `SIZE_MAX` (no limit).
  static int _sizeOrUnlimited(int? value, String name) =>
      value == null ? sizeMax : RangeError.checkNotNegative(value, name);

  /// The cell size in pixels derived from the total pixel size (which
  /// `ghostty_terminal_resize` sets to cells × cell size). Only exact until
  /// the column count changes without a resize, so used only before the
  /// first [resize].
  int _currentCellSize({required bool horizontal}) {
    final total = horizontal ? widthPx : heightPx;
    final cells = horizontal ? cols : rows;
    return total ~/ cells;
  }
}

/// Wraps [pointer], a terminal the library created and the caller owns
/// (e.g. from `ghostty_snapshot_decoder_decode`), in a [VtTerminal] that now
/// owns it. Internal: the package barrel hides it (contratos.md §9b).
VtTerminal adoptNativeTerminal(Pointer<GhosttyTerminalImpl> pointer) =>
    VtTerminal._adopt(pointer);
