// A part of render_state.dart because the view reads the state's private
// native scratch memory and invalidation token on every access.
part of 'render_state.dart';

/// A **borrowed, reused** view of one row of a [RenderState], with
/// allocation-free per-cell accessors.
///
/// **Lifetime:** the view is valid only while its iteration of
/// [RenderState.allRows] or [RenderState.dirtyRows] is on this row. The
/// **same object** is reused for every row, so never keep a reference to it:
/// copy what you need (or call [cellsToList]). Every member throws
/// [StateError] once the iteration has moved on or ended, another iteration
/// has started, or the state was updated or disposed.
///
/// ```dart
/// final lines = [
///   for (final row in state.allRows) row.cellsToList(), // copies: safe
/// ];
/// ```
///
/// Cell accessors take a column `x` in `0 <= x < length` and throw
/// [RangeError] otherwise. Reading the text, width, hyperlink and
/// background of a cell never calls native code: the row's packed cells
/// are read once, in the same native call that moves to the row. [styleAt]
/// and grapheme text call native code only the first time a style id or a
/// multi-codepoint cell is met in the row.
///
/// Wide characters take two cells: [widthAt] is [CellWidth.wide] for the
/// first one, which holds the text, and [CellWidth.spacerTail] for the
/// second, which a renderer skips.
final class RenderRow {
  RenderRow._(this._state);

  final RenderState _state;

  /// The state token this view is valid for.
  int _token = -1;
  int _index = 0;
  int _viewportY = 0;
  bool _dirty = false;
  Uint64List _cells = Uint64List(0);
  int _selectionStart = -1;
  int _selectionEnd = -1;
  bool _rowCellsLoaded = false;
  int _lastStyleId = 0;
  CellStyle _lastStyle = _defaultStyle;
  final _styles = <int, CellStyle>{};

  static const _defaultStyle = CellStyle();

  /// The position of this row in the iteration, counted from the first
  /// captured row (0). Without overscan this is the viewport row.
  int get index {
    _check();
    return _index;
  }

  /// The row's position relative to the top of the viewport: 0 to
  /// `rows - 1` in the viewport, negative for overscan rows above it and
  /// `rows` or more below it. Use it to place the row.
  int get viewportY {
    _check();
    return _viewportY;
  }

  /// The number of cells (the viewport width).
  int get length {
    _check();
    return _cells.length;
  }

  /// Whether the row changed since the last [RenderState.markClean].
  ///
  /// Setting it overrides the flag (`GHOSTTY_RENDER_STATE_ROW_OPT_DIRTY`),
  /// e.g. to keep a row dirty that could not be drawn this frame.
  bool get isDirty {
    _check();
    return _dirty;
  }

  set isDirty(bool value) {
    _check();
    final input = _state._scratch.value.cast<Bool>()..value = value;
    checkResult(
      ghostty_render_state_row_set(
        _state._rowIterator.pointer,
        GhosttyRenderStateRowOption.GHOSTTY_RENDER_STATE_ROW_OPT_DIRTY,
        input.cast(),
      ),
      'ghostty_render_state_row_set',
    );
    _dirty = value;
  }

  /// The row's identity across updates; it stays the same while the row
  /// scrolls. Key per-row caches by it.
  RenderRowId get id {
    _check();
    final bits = _state._scratch.rowId.ref.bits;
    return RenderRowId(bits[0], bits[1]);
  }

  /// The first selected column (inclusive), or `null` if the selection does
  /// not touch this row.
  int? get selectionStart {
    _check();
    return _selectionStart < 0 ? null : _selectionStart;
  }

  /// The last selected column (inclusive), or `null` if the selection does
  /// not touch this row.
  int? get selectionEnd {
    _check();
    return _selectionStart < 0 ? null : _selectionEnd;
  }

  /// Whether column [x] is inside the selection. Renderers that draw spans
  /// may use [selectionStart] and [selectionEnd] directly.
  bool isSelectedAt(int x) {
    RangeError.checkValidIndex(x, _checkedCells(), 'x');
    return x >= _selectionStart && x <= _selectionEnd;
  }

  /// The base codepoint of cell [x], or 0 for an empty cell, a spacer or a
  /// colour-only cell. Multi-codepoint graphemes have more; see
  /// [hasGraphemeAt] and [writeTextTo].
  int codepointAt(int x) => _cell(x).codepoint;

  /// Whether cell [x] has text to draw.
  bool hasTextAt(int x) => codepointAt(x) != 0;

  /// Whether cell [x] holds a grapheme cluster of more than one codepoint
  /// (e.g. an emoji with a skin-tone modifier or a ZWJ sequence).
  bool hasGraphemeAt(int x) => _cell(x).hasGrapheme;

  /// Whether cell [x] is narrow, wide or a spacer.
  CellWidth widthAt(int x) => _cell(x).width;

  /// Whether cell [x] is part of an OSC 8 hyperlink.
  bool hasHyperlinkAt(int x) => _cell(x).hasHyperlink;

  /// Whether cell [x] is protected from erasing (DECSCA / SPA).
  bool isProtectedAt(int x) => _cell(x).isProtected;

  /// The shell content kind of cell [x] (OSC 133).
  CellSemanticContent semanticContentAt(int x) => _cell(x).semanticContent;

  /// Whether cell [x] has a style other than the default; when `false`,
  /// [styleAt] is the default style without any native call.
  bool hasStylingAt(int x) => _cell(x).styleId != 0;

  /// The style of cell [x].
  ///
  /// Equal styles share one [CellStyle] instance within a state, so
  /// `identical` is a cheap first comparison. The first cell of each
  /// distinct style in a row costs one native read; the rest are cached.
  CellStyle styleAt(int x) {
    final id = _cell(x).styleId;
    if (id == 0) return _defaultStyle;
    if (id == _lastStyleId) return _lastStyle;
    final style = _styles[id] ??= _readStyle(x);
    _lastStyleId = id;
    _lastStyle = style;
    return style;
  }

  /// The end (exclusive) of the run of cells starting at [start] that share
  /// the style of cell [start]. Returns [length] at most.
  ///
  /// Pure Dart: compares the cells' style ids, which are only meaningful
  /// within one row. Use it to draw style runs instead of single cells.
  int styleRunEnd(int start) {
    final cells = _checkedCells();
    final id = PackedCell(cells[start]).styleId;
    var end = start + 1;
    while (end < cells.length && PackedCell(cells[end]).styleId == id) {
      end++;
    }
    return end;
  }

  /// The background of cell [x] as a colour reference: the colour of a
  /// text-less cell erased with a background colour, else the style's
  /// background. [DefaultColor] means the terminal default.
  ColorRef backgroundAt(int x) {
    final cell = _cell(x);
    // Text cells (the common case) skip the colour decoding entirely.
    return cell.hasCodepoint
        ? styleAt(x).background
        : cell.backgroundColor ?? styleAt(x).background;
  }

  /// The concrete background colour of cell [x], with palette entries
  /// resolved through [RenderState.colors]; `null` means the default
  /// background. Inverse video is not applied.
  RgbColor? backgroundRgbAt(int x) => _state.colors.resolve(backgroundAt(x));

  /// The concrete foreground colour of cell [x] (the style's
  /// [CellStyle.foreground]), with palette entries resolved through
  /// [RenderState.colors]; `null` means the default foreground.
  /// Bold-as-bright and inverse video are not applied.
  RgbColor? foregroundRgbAt(int x) =>
      _state.colors.resolve(styleAt(x).foreground);

  /// Appends the full text of cell [x] (all grapheme codepoints) to [sink].
  /// Appends nothing for an empty cell or a spacer.
  ///
  /// Allocation-free for single-codepoint cells; use it to build the text
  /// of a style run.
  void writeTextTo(int x, StringSink sink) {
    final cell = _cell(x);
    if (cell.hasGrapheme) {
      final count = _readGrapheme(x);
      final codepoints = _state._graphemes.pointer.cast<Uint32>();
      for (var i = 0; i < count; i++) {
        sink.writeCharCode(codepoints[i]);
      }
    } else {
      final codepoint = cell.codepoint;
      if (codepoint != 0) sink.writeCharCode(codepoint);
    }
  }

  /// The full text of cell [x] (all grapheme codepoints), or `''` for an
  /// empty cell or a spacer. Allocates; prefer [writeTextTo] in hot loops.
  String textAt(int x) {
    if (hasGraphemeAt(x)) return String.fromCharCodes(codepointsAt(x));
    final codepoint = codepointAt(x);
    return codepoint == 0 ? '' : String.fromCharCode(codepoint);
  }

  /// The codepoints of cell [x]: the base codepoint followed by any extra
  /// grapheme codepoints; empty for an empty cell. Allocates.
  List<int> codepointsAt(int x) {
    if (!hasGraphemeAt(x)) {
      final codepoint = codepointAt(x);
      return codepoint == 0 ? const [] : [codepoint];
    }
    final count = _readGrapheme(x);
    return Uint32List.fromList(
      _state._graphemes.pointer.cast<Uint32>().asTypedList(count),
    );
  }

  /// An immutable snapshot of every cell of this row. Allocates one object
  /// per cell: for tests and cold paths, not for per-frame rendering.
  List<RenderCell> cellsToList() => List.generate(
    _checkedCells().length,
    (x) => RenderCell(
      x: x,
      text: textAt(x),
      width: widthAt(x),
      style: styleAt(x),
      background: backgroundAt(x),
      hasHyperlink: hasHyperlinkAt(x),
      isProtected: isProtectedAt(x),
      isSelected: isSelectedAt(x),
      semanticContent: semanticContentAt(x),
    ),
    growable: false,
  );

  @override
  String toString() => _token == _state._token
      ? 'RenderRow($_index, viewportY: $_viewportY, length: ${_cells.length}'
            '${_dirty ? ', dirty' : ''})'
      : 'RenderRow(invalid)';

  /// Moves this view to the native iterator's current row: one
  /// `row_get_multi` reads its position, id, dirty flag, packed cells and
  /// selection.
  void _load(int token, int index) {
    final state = _state;
    final s = state._scratch;
    s.written.value = 0;
    final code = checkResultAllowing(
      ghostty_render_state_row_get_multi(
        state._rowIterator.pointer,
        _Scratch.rowKeyCount,
        s.rowKeys,
        s.rowValues,
        s.written,
      ),
      'ghostty_render_state_row_get_multi',
      const {GhosttyResultCode.noValue},
    );
    final hasSelection = code == GhosttyResultCode.success;
    if (!hasSelection && s.written.value != _Scratch.rowSelectionIndex) {
      throw GhosttyException(
        'ghostty_render_state_row_get_multi',
        resultCodec.encode(code),
      );
    }
    _token = token;
    _index = index;
    _viewportY = s.viewportY.value;
    _dirty = s.rowDirty.value;
    _selectionStart = hasSelection ? s.selection.ref.start_x : -1;
    _selectionEnd = hasSelection ? s.selection.ref.end_x : -1;
    _cells = _readCells(s.cellsView.ref);
    _rowCellsLoaded = false;
    _lastStyleId = 0;
    _lastStyle = _defaultStyle;
    if (_styles.isNotEmpty) _styles.clear();
  }

  Uint64List _readCells(GhosttyCellsView view) {
    final length = view.len;
    if (length == 0 || view.ptr == nullptr) return Uint64List(0);
    final transcoder = _state._transcoder;
    if (transcoder == null) return view.ptr.asTypedList(length);
    if (_state._transcoded.length < length) {
      _state._transcoded = Uint64List(length);
    }
    transcoder.transcode(view.ptr, length, _state._transcoded);
    return Uint64List.sublistView(_state._transcoded, 0, length);
  }

  void _check() {
    if (_token != _state._token) _throwInvalid();
  }

  Uint64List _checkedCells() {
    _check();
    return _cells;
  }

  /// The packed cell at [x] (canonical layout), after the validity check.
  /// [_check] is inlined by hand: this runs for every cell accessor.
  PackedCell _cell(int x) {
    if (_token != _state._token) _throwInvalid();
    return PackedCell(_cells[x]);
  }

  Never _throwInvalid() {
    _state._handle.checkNotDisposed();
    throw StateError(
      'RenderRow is no longer valid: the render state was updated or its '
      'row iteration moved on',
    );
  }

  /// Positions the native row-cells iterator on cell [x], populating it
  /// for this row on first use.
  Pointer<GhosttyRenderStateRowCellsImpl> _selectCell(int x) {
    final state = _state;
    final cells = state._rowCells.pointer;
    if (!_rowCellsLoaded) {
      state._scratch.handleSlot.value = cells.cast();
      checkResult(
        ghostty_render_state_row_get(
          state._rowIterator.pointer,
          GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
          state._scratch.handleSlot.cast(),
        ),
        'ghostty_render_state_row_get',
      );
      _rowCellsLoaded = true;
    }
    checkResult(
      ghostty_render_state_row_cells_select(cells, x),
      'ghostty_render_state_row_cells_select',
    );
    return cells;
  }

  CellStyle _readStyle(int x) {
    final cells = _selectCell(x);
    final out = _state._scratch.style;
    out.cast<Uint64>()
      ..[0] = 0
      ..[1] = 0;
    checkResult(
      ghostty_render_state_row_cells_get(
        cells,
        GhosttyRenderStateRowCellsData
            .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
        out.cast(),
      ),
      'ghostty_render_state_row_cells_get',
    );
    return _state._cachedStyle();
  }

  /// Copies the codepoints of cell [x] into the state's grapheme buffer and
  /// returns how many there are, growing the buffer on `OUT_OF_SPACE`.
  int _readGrapheme(int x) {
    const operation = 'ghostty_render_state_row_cells_get';
    final cells = _selectCell(x);
    final buffer = _state._graphemes;
    final descriptor = _state._scratch.codepoints;
    for (var attempt = 0; attempt < 2; attempt++) {
      descriptor.ref
        ..ptr = buffer.pointer.cast()
        ..cap = buffer.capacity ~/ sizeOf<Uint32>()
        ..len = 0;
      final code = checkResultAllowing(
        ghostty_render_state_row_cells_get(
          cells,
          GhosttyRenderStateRowCellsData
              .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
          descriptor.cast(),
        ),
        operation,
        const {GhosttyResultCode.outOfSpace},
      );
      final length = descriptor.ref.len;
      if (code == GhosttyResultCode.success) return length;
      buffer.ensureCapacity(length * sizeOf<Uint32>());
    }
    throw GhosttyException(
      operation,
      resultCodec.encode(GhosttyResultCode.outOfSpace),
    );
  }
}
