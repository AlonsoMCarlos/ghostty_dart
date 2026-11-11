// Ported from package:xterm 4.0.0 (lib/src/core/buffer/line.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.
// Changed: a line read from a terminal is a snapshot of libghostty-vt's
// row (its setters change the snapshot only), and createAnchor on such a
// line returns an anchor that libghostty-vt tracks (ADR 0013). dispose()
// iterates over a copy of the anchors (xterm's threw a concurrent
// modification error for a line with anchors).

import 'dart:math' show min;
import 'dart:typed_data';

import '../../utils/circular_buffer.dart';
import '../../utils/unicode_v11.dart';
import '../cell.dart';
import '../cursor.dart';
import 'cell_offset.dart';
import 'tracked_anchor.dart';

const _cellSize = 4;

const _cellForeground = 0;

const _cellBackground = 1;

const _cellAttributes = 2;

const _cellContent = 3;

/// One line of cells, four 32-bit words per cell: foreground, background,
/// attributes ([CellAttr]) and content (code point and width, see
/// [CellContent]); colours are packed as [CellColor] describes.
///
/// `Terminal.buffer.lines[i]` returns a snapshot of a terminal row, made
/// when it is first read and valid until the terminal changes: it is then
/// no longer [attached], and reading the line again returns a fresh one.
/// The setters change the snapshot only, never the terminal. A line built
/// with the constructor is a standalone, writable line, as in xterm.
class BufferLine with IndexedItem {
  /// Creates an empty line of [_length] cells.
  BufferLine(this._length, {this.isWrapped = false})
    : _data = Uint32List(_calcCapacity(_length) * _cellSize);

  int _length;

  Uint32List _data;

  /// The raw cell storage, four words per cell (see [BufferLine]).
  Uint32List get data => _data;

  /// Whether this line continues the previous one (a soft wrap).
  bool isWrapped = false;

  /// The number of cells.
  int get length => _length;

  final _anchors = <CellAnchor>[];

  /// The anchors created on this line with [createAnchor].
  List<CellAnchor> get anchors => _anchors;

  /// The packed foreground colour of cell [index].
  int getForeground(int index) {
    return _data[index * _cellSize + _cellForeground];
  }

  /// The packed background colour of cell [index].
  int getBackground(int index) {
    return _data[index * _cellSize + _cellBackground];
  }

  /// The [CellAttr] bits of cell [index].
  int getAttributes(int index) {
    return _data[index * _cellSize + _cellAttributes];
  }

  /// The packed content (code point and width) of cell [index].
  int getContent(int index) {
    return _data[index * _cellSize + _cellContent];
  }

  /// The code point of cell [index]; 0 for an empty cell and for the
  /// second cell of a wide character.
  int getCodePoint(int index) {
    return _data[index * _cellSize + _cellContent] & CellContent.codepointMask;
  }

  /// The width of cell [index]: 1, 2 for a wide character, 0 when empty.
  int getWidth(int index) {
    return _data[index * _cellSize + _cellContent] >> CellContent.widthShift;
  }

  /// Copies cell [index] into [cellData].
  void getCellData(int index, CellData cellData) {
    final offset = index * _cellSize;
    cellData.foreground = _data[offset + _cellForeground];
    cellData.background = _data[offset + _cellBackground];
    cellData.flags = _data[offset + _cellAttributes];
    cellData.content = _data[offset + _cellContent];
  }

  /// Resets cell [index] and returns an empty [CellData], as xterm does.
  CellData createCellData(int index) {
    final cellData = CellData.empty();
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = cellData.foreground;
    _data[offset + _cellBackground] = cellData.background;
    _data[offset + _cellAttributes] = cellData.flags;
    _data[offset + _cellContent] = cellData.content;
    return cellData;
  }

  /// Sets the packed foreground colour of cell [index].
  void setForeground(int index, int value) {
    _data[index * _cellSize + _cellForeground] = value;
  }

  /// Sets the packed background colour of cell [index].
  void setBackground(int index, int value) {
    _data[index * _cellSize + _cellBackground] = value;
  }

  /// Sets the [CellAttr] bits of cell [index].
  void setAttributes(int index, int value) {
    _data[index * _cellSize + _cellAttributes] = value;
  }

  /// Sets the packed content of cell [index].
  void setContent(int index, int value) {
    _data[index * _cellSize + _cellContent] = value;
  }

  /// Sets cell [index] to [char], with its Unicode 11 width.
  void setCodePoint(int index, int char) {
    final width = unicodeV11.wcwidth(char);
    setContent(index, char | (width << CellContent.widthShift));
  }

  /// Sets cell [index] to [char] of width [witdh] (sic, xterm's name) in
  /// [style].
  void setCell(int index, int char, int witdh, CursorStyle style) {
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = style.foreground;
    _data[offset + _cellBackground] = style.background;
    _data[offset + _cellAttributes] = style.attrs;
    _data[offset + _cellContent] = char | (witdh << CellContent.widthShift);
  }

  /// Sets cell [index] from [cellData].
  void setCellData(int index, CellData cellData) {
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = cellData.foreground;
    _data[offset + _cellBackground] = cellData.background;
    _data[offset + _cellAttributes] = cellData.flags;
    _data[offset + _cellContent] = cellData.content;
  }

  /// Empties cell [index], keeping [style]'s colours and attributes.
  void eraseCell(int index, CursorStyle style) {
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = style.foreground;
    _data[offset + _cellBackground] = style.background;
    _data[offset + _cellAttributes] = style.attrs;
    _data[offset + _cellContent] = 0;
  }

  /// Resets cell [index] to an empty, unstyled cell.
  void resetCell(int index) {
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = 0;
    _data[offset + _cellBackground] = 0;
    _data[offset + _cellAttributes] = 0;
    _data[offset + _cellContent] = 0;
  }

  /// Erase cells whose index satisfies [start] <= index < [end]. Erased cells
  /// are filled with [style].
  void eraseRange(int start, int end, CursorStyle style) {
    // reset cell one to the left if start is second cell of a wide char
    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }

    // reset cell one to the right if end is second cell of a wide char
    if (end < _length && getWidth(end - 1) == 2) {
      eraseCell(end - 1, style);
    }

    end = min(end, _length);
    for (var i = start; i < end; i++) {
      eraseCell(i, style);
    }
  }

  /// Remove [count] cells starting at [start]. Cells that are empty after the
  /// removal are filled with [style].
  void removeCells(int start, int count, [CursorStyle? style]) {
    assert(start >= 0 && start < _length);
    assert(count >= 0 && start + count <= _length);

    style ??= CursorStyle.empty;

    if (start + count < _length) {
      final moveStart = start * _cellSize;
      final moveEnd = (_length - count) * _cellSize;
      final moveOffset = count * _cellSize;
      for (var i = moveStart; i < moveEnd; i++) {
        _data[i] = _data[i + moveOffset];
      }
    }

    for (var i = _length - count; i < _length; i++) {
      eraseCell(i, style);
    }

    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }

    // Update anchors, remove anchors that are inside the removed range.
    for (var i = 0; i < _anchors.length; i++) {
      final anchor = _anchors[i];
      if (anchor.x >= start) {
        if (anchor.x < start + count) {
          anchor.dispose();
        } else {
          anchor.reposition(anchor.x - count);
        }
      }
    }
  }

  /// Inserts [count] cells at [start]. New cells are initialized with [style].
  void insertCells(int start, int count, [CursorStyle? style]) {
    style ??= CursorStyle.empty;

    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }

    if (start + count < _length) {
      final moveStart = start * _cellSize;
      final moveEnd = (_length - count) * _cellSize;
      final moveOffset = count * _cellSize;
      for (var i = moveEnd - 1; i >= moveStart; i--) {
        _data[i + moveOffset] = _data[i];
      }
    }

    final end = min(start + count, _length);
    for (var i = start; i < end; i++) {
      eraseCell(i, style);
    }

    if (getWidth(_length - 1) == 2) {
      eraseCell(_length - 1, style);
    }

    // Update anchors, move anchors that are after the inserted range.
    for (var i = 0; i < _anchors.length; i++) {
      final anchor = _anchors[i];
      if (anchor.x >= start + count) {
        anchor.reposition(anchor.x + count);

        // Remove anchors that are now outside the buffer.
        if (anchor.x >= _length) {
          anchor.dispose();
        }
      }
    }
  }

  /// Changes the number of cells to [length], keeping the existing cells.
  void resize(int length) {
    assert(length >= 0);

    if (length == _length) {
      return;
    }

    if (length > _length) {
      final newBufferSize = _calcCapacity(length) * _cellSize;

      if (newBufferSize > _data.length) {
        final newBuffer = Uint32List(newBufferSize);
        newBuffer.setRange(0, _data.length, _data);
        _data = newBuffer;
      }
    }

    _length = length;

    for (var i = 0; i < _anchors.length; i++) {
      final anchor = _anchors[i];
      if (anchor.x > _length) {
        anchor.reposition(_length);
      }
    }
  }

  /// Returns the offset of the last cell that has content from the start of
  /// the line.
  int getTrimmedLength([int? cols]) {
    final maxCols = _data.length ~/ _cellSize;

    if (cols == null || cols > maxCols) {
      cols = maxCols;
    }

    if (cols <= 0) {
      return 0;
    }

    for (var i = cols - 1; i >= 0; i--) {
      final codePoint = getCodePoint(i);

      if (codePoint != 0) {
        // we are at the last cell in this line that has content.
        // the length of this line is the index of this cell + 1
        // the only exception is that if that last cell is wider
        // than 1 then we have to add the diff
        final lastCellWidth = getWidth(i);
        return i + lastCellWidth;
      }
    }
    return 0;
  }

  /// Copies [len] cells from [src] starting at [srcCol] to [dstCol] at this
  /// line.
  void copyFrom(BufferLine src, int srcCol, int dstCol, int len) {
    resize(dstCol + len);

    var srcOffset = srcCol * _cellSize;
    var dstOffset = dstCol * _cellSize;

    for (var i = 0; i < len * _cellSize; i++) {
      _data[dstOffset++] = src._data[srcOffset++];
    }
  }

  static int _calcCapacity(int length) {
    assert(length >= 0);

    var capacity = 64;

    if (length < 256) {
      while (capacity < length) {
        capacity *= 2;
      }
    } else {
      capacity = 256;
      while (capacity < length) {
        capacity += 32;
      }
    }

    return capacity;
  }

  /// The text of cells [from] (inclusive) to [to] (exclusive), the whole
  /// line by default. Empty cells are skipped, as in xterm.
  String getText([int? from, int? to]) {
    if (from == null || from < 0) {
      from = 0;
    }

    if (to == null || to > _length) {
      to = _length;
    }

    final builder = StringBuffer();
    for (var i = from; i < to; i++) {
      final codePoint = getCodePoint(i);
      final width = getWidth(i);
      if (codePoint != 0 && i + width <= to) {
        builder.writeCharCode(codePoint);
      }
    }

    return builder.toString();
  }

  /// Creates an anchor at cell [offset] of this line.
  ///
  /// On a line read from a terminal (while [attached]), the anchor follows
  /// its cell as the terminal scrolls and reflows (libghostty-vt tracks
  /// it) until the cell leaves the scrollback; call [CellAnchor.dispose]
  /// when done. On any other line it is xterm's plain anchor.
  CellAnchor createAnchor(int offset) {
    final anchor =
        createTrackedAnchor(this, offset) ?? CellAnchor(offset, owner: this);
    _anchors.add(anchor);
    return anchor;
  }

  /// Disposes every anchor of this line.
  void dispose() {
    for (final anchor in List.of(_anchors)) {
      anchor.dispose();
    }
  }

  @override
  String toString() {
    return getText();
  }
}

/// A handle to a cell in a [BufferLine] that can be used to track the location
/// of the cell. Anchors are guaranteed to be stable, retaining their relative
/// position to each other after mutations to the buffer.
///
/// Anchors created by `Buffer.createAnchor` (or [BufferLine.createAnchor]
/// on a line read from a terminal) are tracked by libghostty-vt: they
/// follow their cell through scrolling and reflow, and are no longer
/// [attached] once the cell leaves the scrollback. They hold native
/// memory: [dispose] them when done (disposing the terminal frees them).
class CellAnchor {
  /// Creates an anchor at cell [offset] of [owner].
  CellAnchor(int offset, {BufferLine? owner})
    : _offset = offset,
      _owner = owner;

  int _offset;

  /// The column of the anchored cell.
  int get x {
    return _offset;
  }

  /// The buffer row of the anchored cell (0 is the oldest scrollback
  /// line). Only valid while [attached].
  int get y {
    assert(attached);
    return _owner!.index;
  }

  /// The position of the anchored cell. Only valid while [attached].
  CellOffset get offset {
    assert(attached);
    return CellOffset(_offset, _owner!.index);
  }

  BufferLine? _owner;

  /// The line the anchored cell is on.
  BufferLine? get line => _owner;

  /// Whether the anchor still points at a cell of a buffer.
  bool get attached => _owner?.attached ?? false;

  /// Moves the anchor to cell [offset] of [owner].
  void reparent(BufferLine owner, int offset) {
    _owner?._anchors.remove(this);
    _owner = owner;
    _owner?._anchors.add(this);
    _offset = offset;
  }

  /// Moves the anchor to cell [offset] of its line.
  void reposition(int offset) {
    _offset = offset;
  }

  /// Detaches the anchor from its line (and frees its tracking, if any).
  void dispose() {
    _owner?._anchors.remove(this);
    _owner = null;
  }

  @override
  String toString() {
    if (attached) {
      return 'CellAnchor($x, $y)';
    } else {
      return 'CellAnchor($x, detached)';
    }
  }
}
