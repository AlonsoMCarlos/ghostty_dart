// Ported from package:xterm 4.0.0 (lib/src/core/buffer/buffer.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.
// Changed: a view of a libghostty-vt screen instead of xterm's line store
// (ADR 0013). Lines are read from the terminal on demand; the mutators
// write the equivalent escape sequence to the terminal (active buffer
// only); getWordBoundary, getText and toString are xterm's code.

import 'dart:math' show max;

import '../../terminal.dart';
import '../../utils/circular_buffer.dart';
import '../state.dart';
import 'buffer_lines.dart';
import 'cell_offset.dart';
import 'line.dart';
import 'range.dart';
import 'range_line.dart';
import 'terminal_engine.dart';

/// One screen of a [Terminal]: the main buffer (with scrollback) or the
/// alternate buffer used by full-screen programs.
///
/// A buffer reads its screen from libghostty-vt: [lines] are snapshots made
/// on first access and reused until the terminal changes. Only the
/// terminal's active screen can be read: while the other screen is active
/// (`Terminal.isUsingAltBuffer`), this buffer reads as [viewHeight] blank
/// lines with the cursor at 0, 0, and its mutators throw [StateError].
///
/// The mutators ([setCursor], [clear], [eraseDisplay], [insertLines], …)
/// write the equivalent escape sequence to the terminal, so they follow
/// libghostty-vt's rules (scroll margins, origin mode). Like the
/// `Terminal` methods of the same names, they throw [StateError] while the
/// program's output has stopped in the middle of an escape sequence.
class Buffer {
  /// The terminal this buffer belongs to.
  final TerminalState terminal;

  /// The most lines (scrollback plus screen) the terminal keeps.
  final int maxLines;

  /// Whether this is the alternate buffer.
  final bool isAltBuffer;

  /// Characters that break selection when calling [getWordBoundary]. If null,
  /// defaults to [defaultWordSeparators].
  final Set<int>? wordSeparators;

  /// Creates the main or alternate ([isAltBuffer]) buffer of [terminal].
  ///
  /// `Terminal` creates its two buffers itself. A buffer created for any
  /// other [TerminalState] has no screen to read: it holds
  /// [TerminalState.viewHeight] blank lines.
  Buffer(
    this.terminal, {
    required this.maxLines,
    required this.isAltBuffer,
    this.wordSeparators,
  });

  late final _lines = BufferLines(this);

  /// Width of the viewport in columns. Also the index of the last column.
  int get viewWidth => terminal.viewWidth;

  /// Height of the viewport in rows. Also the index of the last line.
  int get viewHeight => terminal.viewHeight;

  /// lines of the buffer. the length of [lines] should always be equal or
  /// greater than [viewHeight].
  late final lines = IndexAwareCircularBuffer<BufferLine>(_lines);

  /// Total number of lines in the buffer. Always equal or greater than
  /// [viewHeight].
  int get height => lines.length;

  /// Horizontal position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorX {
    final vt = _lines.activeVt;
    return vt == null ? 0 : vt.cursorX.clamp(0, vt.cols - 1);
  }

  /// Vertical position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorY => _lines.activeVt?.cursorY ?? 0;

  /// Index of the first line in the scroll region. Always 0: libghostty-vt
  /// 1.0.0 does not expose the scroll margins (DECSTBM).
  int get marginTop => 0;

  /// Index of the last line in the scroll region. Always [viewHeight] - 1:
  /// libghostty-vt 1.0.0 does not expose the scroll margins (DECSTBM).
  int get marginBottom => viewHeight - 1;

  /// The number of lines above the viewport.
  int get scrollBack => height - viewHeight;

  /// Vertical position of the cursor relative to the top of the buffer,
  /// starting from 0.
  int get absoluteCursorY => cursorY + scrollBack;

  /// Absolute index of the first line in the scroll region.
  int get absoluteMarginTop => marginTop + scrollBack;

  /// Absolute index of the last line in the scroll region.
  int get absoluteMarginBottom => marginBottom + scrollBack;

  /// Writes [text] at the cursor as printable characters: control
  /// characters in it are dropped, so no escape sequence is interpreted.
  ///
  /// See also: [Terminal.write]
  void write(String text) {
    terminalEngineOf(_active)!.writeSequence(printableText(text));
  }

  /// Writes the character [codePoint] at the cursor; a control character
  /// is dropped.
  ///
  /// See also: [Terminal.writeChar]
  void writeChar(int codePoint) {
    _active.writeChar(codePoint);
  }

  /// The line at the current cursor position.
  BufferLine get currentLine {
    return lines[absoluteCursorY];
  }

  /// Moves the cursor one cell left (BS).
  void backspace() {
    _active.backspaceReturn();
  }

  /// Erases the viewport from the cursor position to the end of the buffer,
  /// including the cursor position.
  void eraseDisplayFromCursor() {
    _active.eraseDisplayBelow();
  }

  /// Erases the viewport from the top-left corner to the cursor, including the
  /// cursor.
  void eraseDisplayToCursor() {
    _active.eraseDisplayAbove();
  }

  /// Erases the whole viewport.
  void eraseDisplay() {
    _active.eraseDisplay();
  }

  /// Erases the line from the cursor to the end of the line, including the
  /// cursor position.
  void eraseLineFromCursor() {
    _active.eraseLineRight();
  }

  /// Erases the line from the start of the line to the cursor, including the
  /// cursor.
  void eraseLineToCursor() {
    _active.eraseLineLeft();
  }

  /// Erases the line at the current cursor position.
  void eraseLine() {
    _active.eraseLine();
  }

  /// Erases [count] cells starting at the cursor position.
  void eraseChars(int count) {
    _active.eraseChars(count);
  }

  /// Scrolls the scroll region down by [lines] lines (SD).
  void scrollDown(int lines) {
    _active.scrollDown(lines);
  }

  /// Scrolls the scroll region up by [lines] lines (SU).
  void scrollUp(int lines) {
    _active.scrollUp(lines);
  }

  /// https://vt100.net/docs/vt100-ug/chapter3.html#IND IND – Index
  ///
  /// ESC D
  ///
  /// [index] causes the active position to move downward one line without
  /// changing the column position. If the active position is at the bottom
  /// margin, a scroll up is performed.
  void index() {
    _active.index();
  }

  /// Moves the cursor down one line, scrolling at the bottom margin (LF);
  /// also to the first column in line feed mode.
  void lineFeed() {
    _active.lineFeed();
  }

  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  void reverseIndex() {
    _active.reverseIndex();
  }

  /// Moves the cursor one cell right (CUF), stopping at the last column.
  void cursorGoForward() {
    _active.moveCursorX(1);
  }

  /// Moves the cursor to column [cursorX].
  void setCursorX(int cursorX) {
    _active.setCursorX(cursorX);
  }

  /// Moves the cursor to row [cursorY] of the screen.
  void setCursorY(int cursorY) {
    _active.setCursorY(cursorY);
  }

  /// Moves the cursor [offset] columns right (left if negative).
  void moveCursorX(int offset) {
    _active.moveCursorX(offset);
  }

  /// Moves the cursor [offset] rows down (up if negative).
  void moveCursorY(int offset) {
    _active.moveCursorY(offset);
  }

  /// Moves the cursor to column [cursorX], row [cursorY] of the screen
  /// (of the scroll region in origin mode).
  void setCursor(int cursorX, int cursorY) {
    _active.setCursor(cursorX, cursorY);
  }

  /// Moves the cursor by [offsetX] columns and [offsetY] rows.
  void moveCursor(int offsetX, int offsetY) {
    final terminal = _active;
    terminal.moveCursorX(offsetX);
    terminal.moveCursorY(offsetY);
  }

  /// Save cursor position, charmap and text attributes.
  void saveCursor() {
    _active.saveCursor();
  }

  /// Restore cursor position, charmap and text attributes.
  void restoreCursor() {
    _active.restoreCursor();
  }

  /// Sets the vertical scrolling margin to [top] and [bottom].
  /// Both values must be between 0 and [viewHeight] - 1.
  void setVerticalMargins(int top, int bottom) {
    _active.setMargins(top, bottom);
  }

  /// Whether the cursor is inside the scroll region (the whole screen, as
  /// far as this buffer can tell; see [marginTop]).
  bool get isInVerticalMargin {
    return cursorY >= marginTop && cursorY <= marginBottom;
  }

  /// Resets the scroll region to the whole screen.
  void resetVerticalMargins() {
    _active.setMargins(0);
  }

  /// Deletes [count] cells at the cursor, shifting the rest left (DCH).
  void deleteChars(int count) {
    _active.deleteChars(count);
  }

  /// Remove all lines above the top of the viewport.
  void clearScrollback() {
    _active.eraseScrollbackOnly();
  }

  /// Clears the viewport and scrollback buffer. Then fill with empty lines.
  ///
  /// Writes ED 2 and ED 3; the cursor does not move. Anchors created in
  /// this buffer are no longer attached afterwards, as in xterm.
  void clear() {
    final terminal = _active;
    terminal.eraseDisplay();
    terminal.eraseScrollbackOnly();
    _lines.detachAnchors();
  }

  /// Inserts [count] blank cells at the cursor (ICH).
  void insertBlankChars(int count) {
    _active.insertBlankChars(count);
  }

  /// Inserts [count] blank lines at the cursor, inside the scroll region
  /// (IL).
  void insertLines(int count) {
    _active.insertLines(count);
  }

  /// Remove [count] lines starting at the current cursor position. Lines below
  /// the removed lines are shifted up. This only affects the scrollable region.
  /// Lines outside the scrollable region are not affected.
  void deleteLines(int count) {
    _active.deleteLines(count);
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchor(int x, int y) {
    return lines[y].createAnchor(x);
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchorFromOffset(CellOffset offset) {
    return lines[offset.y].createAnchor(offset.x);
  }

  /// Creates a new [CellAnchor] at the cursor.
  CellAnchor createAnchorFromCursor() {
    return createAnchor(cursorX, absoluteCursorY);
  }

  /// The terminal, for a mutator; throws [StateError] when this buffer is
  /// not the active one (or was not created by a [Terminal]).
  Terminal get _active {
    final terminal = this.terminal;
    if (terminal is! Terminal || !_lines.isActive) {
      throw StateError(
        'only the active buffer of a Terminal can be changed '
        '(isAltBuffer: $isAltBuffer)',
      );
    }
    return terminal;
  }

  /// The characters [getWordBoundary] stops at when [wordSeparators] is
  /// not set.
  static final defaultWordSeparators = <int>{
    0,
    r' '.codeUnitAt(0),
    r'.'.codeUnitAt(0),
    r':'.codeUnitAt(0),
    r'-'.codeUnitAt(0),
    r'\'.codeUnitAt(0),
    r'"'.codeUnitAt(0),
    r'*'.codeUnitAt(0),
    r'+'.codeUnitAt(0),
    r'/'.codeUnitAt(0),
    r'\'.codeUnitAt(0),
  };

  /// The word around [position], from its first cell (inclusive) to the
  /// cell after its last (exclusive), or `null` on a separator.
  BufferRangeLine? getWordBoundary(CellOffset position) {
    final separators = wordSeparators ?? defaultWordSeparators;
    if (position.y >= lines.length) {
      return null;
    }

    final line = lines[position.y];
    var start = position.x;
    var end = position.x;

    do {
      if (start == 0) {
        break;
      }
      final char = line.getCodePoint(start - 1);
      if (separators.contains(char)) {
        break;
      }
      start--;
    } while (true);

    do {
      if (end >= viewWidth) {
        break;
      }
      final char = line.getCodePoint(end);
      if (separators.contains(char)) {
        break;
      }
      end++;
    } while (true);

    if (start == end) {
      return null;
    }

    return BufferRangeLine(
      CellOffset(start, position.y),
      CellOffset(end, position.y),
    );
  }

  /// Get the plain text content of the buffer including the scrollback.
  /// Accepts an optional [range] to get a specific part of the buffer.
  ///
  /// Reads (and caches) every line in the range: for large ranges over
  /// deep scrollback this costs about as much as reading the lines one by
  /// one (see `COMPATIBILITY.md`).
  String getText([BufferRange? range]) {
    range ??= BufferRangeLine(
      const CellOffset(0, 0),
      CellOffset(viewWidth - 1, height - 1),
    );

    range = range.normalized;

    final builder = StringBuffer();
    final lineCount = height;

    for (final segment in range.toSegments()) {
      if (segment.line < 0 || segment.line >= lineCount) {
        continue;
      }
      final line = lines[segment.line];
      if (!(segment.line == range.begin.y ||
          segment.line == 0 ||
          line.isWrapped)) {
        builder.write('\n');
      }
      builder.write(line.getText(segment.start, segment.end));
    }

    return builder.toString();
  }

  /// Returns a debug representation of the buffer.
  @override
  String toString() {
    final builder = StringBuffer();
    final lineNumberLength = max(lines.length.toString().length, 1);

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      builder.write('${i.toString().padLeft(lineNumberLength)}: |$line|');

      if (line.isWrapped) {
        builder.write(' (⏎)');
      }

      builder.write('\n');
    }

    return builder.toString();
  }
}
