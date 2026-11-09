/// Terminal modes (`modes.h`): a mode number plus whether it is an ANSI mode
/// or a DEC private mode.
library;

/// A terminal mode: a mode [value] and whether it is an ANSI mode
/// ([isAnsi]) or a DEC private mode (`?`-prefixed).
///
/// The number alone is ambiguous: ANSI mode 4 is insert mode, DEC private
/// mode 4 is slow scroll. Use the named constants (e.g. [cursorKeys]) or
/// build any mode with [TerminalMode.dec] / [TerminalMode.ansi].
///
/// Mirrors the packed 16-bit `GhosttyMode` and the inline
/// `ghostty_mode_new` / `ghostty_mode_value` / `ghostty_mode_ansi` helpers.
final class TerminalMode {
  /// The DEC private mode [value] (`CSI ? value h`), 0–32767.
  const TerminalMode.dec(this.value)
    : isAnsi = false,
      assert(value >= 0 && value <= 0x7FFF, 'mode value must be 0-32767');

  /// The ANSI mode [value] (`CSI value h`), 0–32767.
  const TerminalMode.ansi(this.value)
    : isAnsi = true,
      assert(value >= 0 && value <= 0x7FFF, 'mode value must be 0-32767');

  /// The mode number, 0–32767.
  final int value;

  /// Whether this is an ANSI mode (`true`) or a DEC private mode (`false`).
  final bool isAnsi;

  /// ANSI 2: keyboard action (keyboard disabled).
  static const disableKeyboard = TerminalMode.ansi(2);

  /// ANSI 4: insert mode (IRM).
  static const insert = TerminalMode.ansi(4);

  /// ANSI 12: send/receive mode (SRM).
  static const sendReceive = TerminalMode.ansi(12);

  /// ANSI 20: linefeed/new line mode (LNM).
  static const linefeed = TerminalMode.ansi(20);

  /// DEC 1: application cursor keys (DECCKM).
  static const cursorKeys = TerminalMode.dec(1);

  /// DEC 3: 132/80 column mode (DECCOLM).
  static const column132 = TerminalMode.dec(3);

  /// DEC 4: slow scroll (DECSCLM).
  static const slowScroll = TerminalMode.dec(4);

  /// DEC 5: reverse video (DECSCNM).
  static const reverseColors = TerminalMode.dec(5);

  /// DEC 6: origin mode (DECOM).
  static const origin = TerminalMode.dec(6);

  /// DEC 7: auto-wrap (DECAWM).
  static const wraparound = TerminalMode.dec(7);

  /// DEC 8: auto-repeat keys (DECARM).
  static const autorepeat = TerminalMode.dec(8);

  /// DEC 9: X10 mouse reporting.
  static const mouseEventX10 = TerminalMode.dec(9);

  /// DEC 12: cursor blinking.
  static const cursorBlinking = TerminalMode.dec(12);

  /// DEC 25: cursor visible (DECTCEM).
  static const cursorVisible = TerminalMode.dec(25);

  /// DEC 40: allow 132 column mode.
  static const enableMode3 = TerminalMode.dec(40);

  /// DEC 45: reverse wrap.
  static const reverseWrap = TerminalMode.dec(45);

  /// DEC 47: alternate screen (legacy).
  static const altScreenLegacy = TerminalMode.dec(47);

  /// DEC 66: application keypad (DECNKM).
  static const keypadKeys = TerminalMode.dec(66);

  /// DEC 67: backarrow key mode (DECBKM).
  static const backarrowKey = TerminalMode.dec(67);

  /// DEC 69: left/right margin mode (DECLRMM).
  static const enableLeftAndRightMargin = TerminalMode.dec(69);

  /// DEC 1000: normal mouse tracking.
  static const mouseEventNormal = TerminalMode.dec(1000);

  /// DEC 1002: button-event mouse tracking.
  static const mouseEventButton = TerminalMode.dec(1002);

  /// DEC 1003: any-event mouse tracking.
  static const mouseEventAny = TerminalMode.dec(1003);

  /// DEC 1004: focus in/out events.
  static const focusEvent = TerminalMode.dec(1004);

  /// DEC 1005: UTF-8 mouse format.
  static const mouseFormatUtf8 = TerminalMode.dec(1005);

  /// DEC 1006: SGR mouse format.
  static const mouseFormatSgr = TerminalMode.dec(1006);

  /// DEC 1007: alternate scroll mode.
  static const mouseAlternateScroll = TerminalMode.dec(1007);

  /// DEC 1015: URxvt mouse format.
  static const mouseFormatUrxvt = TerminalMode.dec(1015);

  /// DEC 1016: SGR-pixels mouse format.
  static const mouseFormatSgrPixels = TerminalMode.dec(1016);

  /// DEC 1035: ignore keypad with Num Lock.
  static const ignoreKeypadWithNumLock = TerminalMode.dec(1035);

  /// DEC 1036: Alt key sends an ESC prefix.
  static const altEscPrefix = TerminalMode.dec(1036);

  /// DEC 1039: Alt sends escape.
  static const altSendsEscape = TerminalMode.dec(1039);

  /// DEC 1045: extended reverse wrap.
  static const reverseWrapExtended = TerminalMode.dec(1045);

  /// DEC 1047: alternate screen.
  static const altScreen = TerminalMode.dec(1047);

  /// DEC 1048: save cursor (DECSC).
  static const saveCursor = TerminalMode.dec(1048);

  /// DEC 1049: alternate screen, save cursor and clear on enter.
  static const altScreenSaveCursorClearEnter = TerminalMode.dec(1049);

  /// DEC 2004: bracketed paste.
  static const bracketedPaste = TerminalMode.dec(2004);

  /// DEC 2026: synchronized output.
  static const synchronizedOutput = TerminalMode.dec(2026);

  /// DEC 2027: grapheme cluster mode.
  static const graphemeCluster = TerminalMode.dec(2027);

  /// DEC 2031: report colour scheme changes.
  static const reportColorScheme = TerminalMode.dec(2031);

  /// DEC 2033: report terminal visibility.
  static const reportVisibility = TerminalMode.dec(2033);

  /// DEC 2048: in-band size reports.
  static const inBandSizeReports = TerminalMode.dec(2048);

  /// DEC 5522: Kitty clipboard protocol paste events.
  static const kittyPasteEvents = TerminalMode.dec(5522);

  /// Every mode named in `modes.h`, in header order.
  static const List<TerminalMode> named = [
    disableKeyboard,
    insert,
    sendReceive,
    linefeed,
    cursorKeys,
    column132,
    slowScroll,
    reverseColors,
    origin,
    wraparound,
    autorepeat,
    mouseEventX10,
    cursorBlinking,
    cursorVisible,
    enableMode3,
    reverseWrap,
    altScreenLegacy,
    keypadKeys,
    backarrowKey,
    enableLeftAndRightMargin,
    mouseEventNormal,
    mouseEventButton,
    mouseEventAny,
    focusEvent,
    mouseFormatUtf8,
    mouseFormatSgr,
    mouseAlternateScroll,
    mouseFormatUrxvt,
    mouseFormatSgrPixels,
    ignoreKeypadWithNumLock,
    altEscPrefix,
    altSendsEscape,
    reverseWrapExtended,
    altScreen,
    saveCursor,
    altScreenSaveCursorClearEnter,
    bracketedPaste,
    synchronizedOutput,
    graphemeCluster,
    reportColorScheme,
    reportVisibility,
    inBandSizeReports,
    kittyPasteEvents,
  ];

  @override
  bool operator ==(Object other) =>
      other is TerminalMode && other.value == value && other.isAnsi == isAnsi;

  @override
  int get hashCode => Object.hash(value, isAnsi);

  @override
  String toString() => 'TerminalMode.${isAnsi ? 'ansi' : 'dec'}($value)';
}

/// Packs [mode] into a raw `GhosttyMode` (`ghostty_mode_new`): the value in
/// bits 0–14 and the ANSI flag in bit 15.
int terminalModeToRaw(TerminalMode mode) =>
    (mode.value & 0x7FFF) | (mode.isAnsi ? 0x8000 : 0);

/// Unpacks a raw `GhosttyMode` (`ghostty_mode_value` / `ghostty_mode_ansi`).
TerminalMode terminalModeFromRaw(int raw) => (raw & 0x8000) != 0
    ? TerminalMode.ansi(raw & 0x7FFF)
    : TerminalMode.dec(raw & 0x7FFF);
