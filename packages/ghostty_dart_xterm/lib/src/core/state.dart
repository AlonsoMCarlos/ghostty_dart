// Ported from package:xterm 4.0.0 (lib/src/core/state.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'cursor.dart';
import 'mouse/mode.dart';

/// The modes and size of a terminal, as the input and mouse handlers see
/// it. `Terminal` implements it.
abstract class TerminalState {
  /// The number of columns.
  int get viewWidth;

  /// The number of rows.
  int get viewHeight;

  /// The current text style (the SGR pen) new text is written with.
  CursorStyle get cursor;

  /// Whether lines are re-wrapped when the width changes.
  bool get reflowEnabled;

  /* Modes */

  /// Insert mode (IRM, ANSI mode 4).
  bool get insertMode;

  /// Line feed / new line mode (LNM, ANSI mode 20).
  bool get lineFeedMode;

  /* DEC Private modes */

  /// Application cursor keys (DECCKM, DEC mode 1).
  bool get cursorKeysMode;

  /// Reverse video (DECSCNM, DEC mode 5).
  bool get reverseDisplayMode;

  /// Origin mode (DECOM, DEC mode 6).
  bool get originMode;

  /// Auto-wrap mode (DECAWM, DEC mode 7).
  bool get autoWrapMode;

  /// Which mouse events the program asked to receive.
  MouseMode get mouseMode;

  /// How mouse events are encoded.
  MouseReportMode get mouseReportMode;

  /// Whether the cursor blinks (DEC mode 12).
  bool get cursorBlinkMode;

  /// Whether the cursor is visible (DECTCEM, DEC mode 25).
  bool get cursorVisibleMode;

  /// Application keypad mode (DECKPAM / DECKPNM).
  bool get appKeypadMode;

  /// Whether focus changes are reported (DEC mode 1004).
  bool get reportFocusMode;

  /// Whether the wheel sends cursor keys on the alternate screen (DEC mode
  /// 1007).
  bool get altBufferMouseScrollMode;

  /// Whether pastes are bracketed (DEC mode 2004).
  bool get bracketedPasteMode;
}
