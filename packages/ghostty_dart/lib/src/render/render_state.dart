/// The render state: a per-frame copy of everything a renderer draws.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../terminal/terminal.dart' show VtTerminal;
import 'cell_layout.dart';
import 'render_enums.dart';
import 'render_values.dart';

part 'render_row.dart';

/// A snapshot of a terminal for drawing one frame (`GhosttyRenderState`):
/// rows, cells, styles, cursor, colours and image placements.
///
/// Create one per renderer and keep it: [update] copies only what changed
/// since the last update and reuses its memory, so a frame costs work
/// proportional to the change, not to the screen size. After [update] the
/// state no longer touches the terminal, which can keep receiving output.
///
/// ## Frame loop
///
/// ```dart
/// final state = RenderState();
///
/// void drawFrame(VtTerminal terminal) {
///   state.update(terminal);
///   if (state.dirty == RenderDirtyState.clean) return;   // nothing changed
///   final colors = state.colors;
///   for (final row in state.dirtyRows) {                 // all rows if full
///     for (var x = 0; x < row.length;) {
///       final end = row.styleRunEnd(x);                  // same style: one run
///       final style = row.styleAt(x);
///       final text = StringBuffer();
///       for (var i = x; i < end; i++) {
///         if (row.widthAt(i).isSpacer) continue;         // wide char's tail
///         row.hasTextAt(i) ? row.writeTextTo(i, text) : text.write(' ');
///       }
///       // draw `text` at column x of row.viewportY with `style`, `colors`
///       x = end;
///     }
///   }
///   // draw state.cursor ...
///   state.markClean();                                   // frame done
/// }
/// ```
///
/// ## Borrowed views
///
/// [allRows] and [dirtyRows] yield **one reused [RenderRow] object** that
/// shows the current row of the iteration; do not keep references to it.
/// It throws [StateError] once the iteration has moved past it and ended,
/// another iteration started, or the state was updated or disposed.
/// Use [RenderRow.cellsToList] for an immutable copy.
///
/// ## Threads
///
/// The library splits an update into [beginUpdate] (the only phase that
/// reads the terminal) and [endUpdate] (render-state memory only), so a
/// lock shared with an I/O thread is held as briefly as possible. Within
/// one isolate, prefer [update], which does both in one native call.
///
/// ## Ownership
///
/// The state owns its native memory and is independent of any terminal: it
/// can be updated from any [VtTerminal]. Call [dispose] when done; a
/// finalizer frees it if you forget. After [dispose], every member except
/// [isDisposed] and [dispose] throws [StateError].
final class RenderState implements Finalizable {
  /// Creates an empty render state; call [update] before reading it.
  ///
  /// Throws [GhosttyException] if the library fails to allocate it, and
  /// [IncompatibleLibraryException] if the loaded libghostty-vt is not a
  /// supported 1.x version.
  RenderState() : this._(transcodeCells: !nativeCellLayoutIsCanonical);

  RenderState._({required bool transcodeCells})
    : _handle = NativeHandle(
        createNative<GhosttyRenderStateImpl>(
          'ghostty_render_state_new',
          (out) => ghostty_render_state_new(nullptr, out),
        ),
        typeName: 'RenderState',
        free: (p) => ghostty_render_state_free(p),
        finalizer: _finalizer,
      ),
      _transcoder = transcodeCells ? CellTranscoder() : null {
    bindHandle(this, _handle);
    _rowIterator = NativeHandle(
      createNative<GhosttyRenderStateRowIteratorImpl>(
        'ghostty_render_state_row_iterator_new',
        (out) => ghostty_render_state_row_iterator_new(nullptr, out),
      ),
      typeName: 'RenderState',
      free: (p) => ghostty_render_state_row_iterator_free(p),
      finalizer: _rowIteratorFinalizer,
    );
    _handle.addDependent(_rowIterator);
    _rowCells = NativeHandle(
      createNative<GhosttyRenderStateRowCellsImpl>(
        'ghostty_render_state_row_cells_new',
        (out) => ghostty_render_state_row_cells_new(nullptr, out),
      ),
      typeName: 'RenderState',
      free: (p) => ghostty_render_state_row_cells_free(p),
      finalizer: _rowCellsFinalizer,
    );
    _handle.addDependent(_rowCells);
    _handle
      ..addCleanup(_scratch.dispose)
      ..addCleanup(_graphemes.dispose);
    final transcoder = _transcoder;
    if (transcoder != null) _handle.addCleanup(transcoder.dispose);
    _row = RenderRow._(this);
    _refresh();
  }

  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyRenderState)>>(
      ghostty_render_state_free,
    ).cast(),
  );

  static final _rowIteratorFinalizer = NativeFinalizer(
    Native.addressOf<
          NativeFunction<Void Function(GhosttyRenderStateRowIterator)>
        >(ghostty_render_state_row_iterator_free)
        .cast(),
  );

  static final _rowCellsFinalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyRenderStateRowCells)>>(
      ghostty_render_state_row_cells_free,
    ).cast(),
  );

  static final _imageIteratorFinalizer = NativeFinalizer(
    Native.addressOf<
          NativeFunction<Void Function(GhosttyRenderStateImageIterator)>
        >(ghostty_render_state_image_iterator_free)
        .cast(),
  );

  final NativeHandle<GhosttyRenderStateImpl> _handle;
  late final NativeHandle<GhosttyRenderStateRowIteratorImpl> _rowIterator;
  late final NativeHandle<GhosttyRenderStateRowCellsImpl> _rowCells;
  NativeHandle<GhosttyRenderStateImageIteratorImpl>? _imageIterator;
  final _scratch = _Scratch();
  final _graphemes = GrowableNativeBuffer(16 * sizeOf<Uint32>());

  /// Non-null when the loaded library packs cells in a layout other than
  /// the canonical one; rows are then transcoded into [_transcoded].
  final CellTranscoder? _transcoder;
  Uint64List _transcoded = Uint64List(0);
  late final RenderRow _row;

  /// Bumped whenever borrowed views must stop working: update, a new row
  /// iteration, the end of an iteration, dispose.
  int _token = 0;
  bool _updatePending = false;

  int _cols = 0;
  int _rows = 0;
  RenderDirtyState _dirty = RenderDirtyState.clean;
  RenderCursor? _cursor;
  RenderColors? _colors;

  /// The last decoded colours and their defining bytes, so an update that
  /// leaves the colours unchanged returns the same instance.
  RenderColors? _lastColors;
  final _colorsBytes = Uint8List(_colorsCompareLength);

  /// Styles decoded so far, keyed by the 16 raw bytes of `GhosttyStyle`, so
  /// equal styles share one [CellStyle] across rows and frames.
  final _styleCache = <(int, int), CellStyle>{};
  static const _styleCacheLimit = 4096;

  /// Whether [dispose] has been called.
  bool get isDisposed => _handle.isDisposed;

  /// Copies the current state of [terminal] into this render state
  /// (`ghostty_render_state_update`).
  ///
  /// Consumes the terminal's dirty tracking. An update only *raises* the
  /// dirty state, so [dirty] and the per-row [RenderRow.isDirty] describe
  /// what changed since the last [markClean], not just since the previous
  /// update (a frame that was skipped is not lost). Invalidates every
  /// [RenderRow] view.
  ///
  /// Throws [StateError] if this state or [terminal] is disposed, or if
  /// called from inside a callback of [terminal] (its state is
  /// mid-update), and [GhosttyException] if an allocation fails.
  void update(VtTerminal terminal) {
    final state = _handle.pointer;
    final source = _terminalPointer(terminal);
    _token++;
    _updatePending = false;
    checkResult(
      ghostty_render_state_update(state, source),
      'ghostty_render_state_update',
    );
    _refresh();
  }

  /// The first phase of a two-phase update
  /// (`ghostty_render_state_begin_update`): the only part that reads
  /// [terminal]. Must be followed by [endUpdate] before the state is read;
  /// until then every getter throws [StateError].
  ///
  /// See [update] for the errors.
  void beginUpdate(VtTerminal terminal) {
    final state = _handle.pointer;
    final source = _terminalPointer(terminal);
    _token++;
    _updatePending = true;
    checkResult(
      ghostty_render_state_begin_update(state, source),
      'ghostty_render_state_begin_update',
    );
  }

  /// Completes a [beginUpdate] (`ghostty_render_state_end_update`). It only
  /// touches render-state memory, so the terminal may already be changing.
  /// Without a prior [beginUpdate] it is a no-op.
  ///
  /// Throws [StateError] after [dispose].
  void endUpdate() {
    checkResult(
      ghostty_render_state_end_update(_handle.pointer),
      'ghostty_render_state_end_update',
    );
    if (!_updatePending) return;
    _updatePending = false;
    _refresh();
  }

  /// Marks the frame as drawn (`ghostty_render_state_clean`): [dirty]
  /// becomes [RenderDirtyState.clean] and every row's dirty flag is cleared.
  ///
  /// Call it only after a complete frame was drawn. A renderer that drew
  /// only part of a frame sets [dirty] and [RenderRow.isDirty] instead.
  /// Does not affect the terminal or cell contents.
  void markClean() {
    _checkReadable();
    checkResult(
      ghostty_render_state_clean(_handle.pointer),
      'ghostty_render_state_clean',
    );
    _dirty = RenderDirtyState.clean;
    _row._dirty = false;
  }

  /// How much changed since the last [markClean]; see [RenderDirtyState].
  /// Updates never lower it (a forced value survives an update without
  /// changes).
  ///
  /// Setting it overrides the value (`GHOSTTY_RENDER_STATE_OPT_DIRTY`), for
  /// renderers that consume a frame in several passes. Setting
  /// [RenderDirtyState.unknown] throws [ArgumentError].
  RenderDirtyState get dirty {
    _checkReadable();
    return _dirty;
  }

  set dirty(RenderDirtyState value) {
    _checkReadable();
    final raw = renderDirtyStateCodec.encode(value);
    final input = _scratch.value.cast<UnsignedInt>()..value = raw;
    checkResult(
      ghostty_render_state_set(
        _handle.pointer,
        GhosttyRenderStateOption.GHOSTTY_RENDER_STATE_OPT_DIRTY,
        input.cast(),
      ),
      'ghostty_render_state_set',
    );
    _dirty = value;
  }

  /// The viewport width in cells at the last update (0 before the first).
  int get cols {
    _checkReadable();
    return _cols;
  }

  /// The viewport height in cells at the last update (0 before the first),
  /// not counting overscan rows.
  int get rows {
    _checkReadable();
    return _rows;
  }

  /// The cursor of the last update. Unchanged values return the same
  /// instance, so `identical` is a cheap "did the cursor change" test.
  RenderCursor get cursor {
    _checkReadable();
    return _cursor ??= _readCursor();
  }

  /// The colours of the last update: defaults, cursor colour and palette.
  ///
  /// Read lazily (one native call on first access after an update).
  /// Unchanged colours return the same instance.
  RenderColors get colors {
    _checkReadable();
    return _colors ??= _readColors();
  }

  /// How many overscan rows the last update actually captured
  /// (`GHOSTTY_RENDER_STATE_DATA_OVERSCAN`). Never more than
  /// [overscanRequest]; fewer near the top of the scrollback, and `below`
  /// is 0 while the viewport is at the bottom.
  RenderOverscan get overscan =>
      _readOverscan(GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_OVERSCAN);

  /// The overscan rows the next update captures above and below the
  /// viewport (`GHOSTTY_RENDER_STATE_OPT_OVERSCAN`). [RenderOverscan.none]
  /// by default; setting `null` restores it.
  ///
  /// With overscan, [allRows] starts at the highest captured row, and
  /// [RenderRow.viewportY] is negative above the viewport. Expect a full
  /// redraw on the update after a change.
  RenderOverscan get overscanRequest => _readOverscan(
    GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_OVERSCAN_REQUEST,
  );

  set overscanRequest(RenderOverscan? value) {
    _checkReadable();
    Pointer<Void> input = nullptr;
    if (value != null) {
      final overscan = _scratch.value.cast<GhosttyRenderStateOverscan>();
      overscan.ref
        ..above = RangeError.checkValueInInterval(
          value.above,
          0,
          0xFFFF,
          'above',
        )
        ..below = RangeError.checkValueInInterval(
          value.below,
          0,
          0xFFFF,
          'below',
        );
      input = overscan.cast();
    }
    checkResult(
      ghostty_render_state_set(
        _handle.pointer,
        GhosttyRenderStateOption.GHOSTTY_RENDER_STATE_OPT_OVERSCAN,
        input,
      ),
      'ghostty_render_state_set',
    );
  }

  /// Every row the last update captured, top to bottom: the viewport plus
  /// any overscan rows.
  ///
  /// Yields one reused [RenderRow]; see the class docs. Starting an
  /// iteration invalidates any other one. Throws [StateError] after
  /// [dispose] or between [beginUpdate] and [endUpdate].
  Iterable<RenderRow> get allRows => _RowIterable(this, dirtyOnly: false);

  /// The rows that need a redraw, top to bottom
  /// (`ghostty_render_state_row_iterator_next_dirty`).
  ///
  /// Nothing when [dirty] is [RenderDirtyState.clean], only the dirty rows
  /// when it is [RenderDirtyState.partial], and every row when it is
  /// [RenderDirtyState.full]. Does not clear any dirty flag; call
  /// [markClean] after drawing. Same reuse rules as [allRows].
  Iterable<RenderRow> get dirtyRows => _RowIterable(this, dirtyOnly: true);

  /// A value that changes whenever an update changes [imagePlacements]
  /// (`GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION`). If it equals
  /// the value from the last read, the placements are the same. Only
  /// compare it for equality; always 0 without Kitty graphics.
  int get imagePlacementsGeneration {
    _checkReadable();
    if (!_hasImages) return 0;
    final out = _scratch.value.cast<Uint64>()..value = 0;
    checkResult(
      ghostty_render_state_get(
        _handle.pointer,
        GhosttyRenderStateData
            .GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION,
        out.cast(),
      ),
      'ghostty_render_state_get',
    );
    return out.value;
  }

  /// The image placements of the last update, in iterator order (not draw
  /// order: sort by [RenderImagePlacement.layer], then
  /// [RenderImagePlacement.z]).
  ///
  /// Allocates a list; check [imagePlacementsGeneration] first to skip it
  /// when nothing changed. Empty when the library is built without Kitty
  /// graphics ([VtFeature.kittyGraphics]).
  List<RenderImagePlacement> imagePlacements() {
    _checkReadable();
    if (!_hasImages) return const [];
    final iterator = _imageIterator ??= _newImageIterator();
    _scratch.handleSlot.value = iterator.pointer.cast();
    checkResult(
      ghostty_render_state_get(
        _handle.pointer,
        GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR,
        _scratch.handleSlot.cast(),
      ),
      'ghostty_render_state_get',
    );
    final placements = <RenderImagePlacement>[];
    final reader = _ImageReader(_scratch);
    while (ghostty_render_state_image_iterator_next(iterator.pointer)) {
      placements.add(reader.read(iterator.pointer));
    }
    return placements;
  }

  /// Frees the render state and its iterators. Safe to call more than once.
  /// Every [RenderRow] view becomes invalid.
  void dispose() {
    _token++;
    _handle.dispose();
  }

  static final bool _hasImages = libghosttyVtBuildInfo.supports(
    VtFeature.kittyGraphics,
  );

  NativeHandle<GhosttyRenderStateImageIteratorImpl> _newImageIterator() {
    final iterator = NativeHandle(
      createNative<GhosttyRenderStateImageIteratorImpl>(
        'ghostty_render_state_image_iterator_new',
        (out) => ghostty_render_state_image_iterator_new(nullptr, out),
      ),
      typeName: 'RenderState',
      free: (p) => ghostty_render_state_image_iterator_free(p),
      finalizer: _imageIteratorFinalizer,
    );
    _handle.addDependent(iterator);
    return iterator;
  }

  static Pointer<GhosttyTerminalImpl> _terminalPointer(VtTerminal terminal) {
    final handle = handleOf<GhosttyTerminalImpl>(terminal);
    if (handle.isInUse) {
      throw StateError(
        'RenderState.update must not be called from inside a callback of '
        'the terminal it reads',
      );
    }
    return handle.pointer;
  }

  void _checkReadable() {
    _handle.checkNotDisposed();
    if (_updatePending) {
      throw StateError(
        'RenderState is between beginUpdate and endUpdate; call endUpdate '
        'before reading it',
      );
    }
  }

  /// Reads the per-frame scalars (size, dirty, cursor) in one native call.
  void _refresh() {
    final s = _scratch;
    s.cursor.initSized(sizeOf<GhosttyRenderStateCursor>());
    checkResult(
      ghostty_render_state_get_multi(
        _handle.pointer,
        _Scratch.stateKeyCount,
        s.stateKeys,
        s.stateValues,
        nullptr,
      ),
      'ghostty_render_state_get_multi',
    );
    _cols = s.cols.value;
    _rows = s.rows.value;
    _dirty = renderDirtyStateCodec.decode(s.dirty.value);
    final previous = _cursor;
    final cursor = _readCursor();
    _cursor = cursor == previous ? previous : cursor;
    _colors = null;
  }

  RenderCursor _readCursor() {
    final c = _scratch.cursor.ref;
    final inViewport = c.viewport_has_value;
    return RenderCursor(
      style: vtCursorStyleCodec.decode(c.visual_style),
      isVisible: c.visible,
      isBlinking: c.blinking,
      isPasswordInput: c.password_input,
      position: inViewport
          ? GridPoint.viewport(c.viewport_x, c.viewport_y)
          : null,
      isOnWideTail: inViewport && c.wide_tail,
    );
  }

  /// Bytes of `GhosttyRenderStateColors` after `size` that define it:
  /// three colours, the cursor flag and the palette.
  static const _colorsCompareLength = 3 * 3 + 1 + 256 * 3;

  RenderColors _readColors() {
    final out = _scratch.colors;
    final size = sizeOf<GhosttyRenderStateColors>();
    // Zeroing (sized init) also clears the undefined cursor bytes, so
    // unchanged colours compare equal byte for byte.
    out.initSized(size);
    checkResult(
      ghostty_render_state_get(
        _handle.pointer,
        GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLORS,
        out.cast(),
      ),
      'ghostty_render_state_get',
    );
    final c = out.ref;
    final previous = _lastColors;
    final bytes = (out.cast<Uint8>() + sizeOf<Size>()).asTypedList(
      _colorsCompareLength,
    );
    if (previous != null && _sameBytes(bytes, _colorsBytes)) return previous;
    _colorsBytes.setAll(0, bytes);
    final colors = RenderColors(
      background: rgbFromNative(c.background),
      foreground: rgbFromNative(c.foreground),
      cursor: c.cursor_has_value ? rgbFromNative(c.cursor) : null,
      palette: List.generate(256, (i) => rgbFromNative(c.palette[i])),
    );
    _lastColors = colors;
    return colors;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  RenderOverscan _readOverscan(int key) {
    _checkReadable();
    final out = _scratch.value.cast<GhosttyRenderStateOverscan>();
    _scratch.value.cast<Uint32>().value = 0; // both uint16_t fields
    checkResult(
      ghostty_render_state_get(_handle.pointer, key, out.cast()),
      'ghostty_render_state_get',
    );
    final o = out.ref;
    return o.above == 0 && o.below == 0
        ? RenderOverscan.none
        : RenderOverscan(above: o.above, below: o.below);
  }

  /// Decodes the style in [_Scratch.style] (just filled by the library),
  /// sharing one instance per distinct style.
  CellStyle _cachedStyle() {
    final words = _scratch.style.cast<Uint64>();
    final key = (words[0], words[1]);
    final cached = _styleCache[key];
    if (cached != null) return cached;
    if (_styleCache.length >= _styleCacheLimit) _styleCache.clear();
    return _styleCache[key] = cellStyleFromNative(_scratch.style.ref);
  }
}

/// Creates a render state that always transcodes cells with
/// `ghostty_cell_get_multi`, as it would for a library with an unknown cell
/// layout. Internal, for tests of that path; not exported.
RenderState newTranscodingRenderStateForTesting() =>
    RenderState._(transcodeCells: true);

/// Fixed native memory of one [RenderState]: out-parameters, key/value
/// arrays for the `get_multi` calls and sized structs, laid out once in a
/// single block so a frame never allocates.
///
/// The pointers stay valid until [dispose]; the owning state only uses them
/// while its own handle is live.
final class _Scratch {
  _Scratch() : _memory = GrowableNativeBuffer(_size) {
    final base = _memory.pointer;
    base.asTypedList(_size).fillRange(0, _size, 0);
    var offset = 0;
    Pointer<Uint8> take(int bytes) {
      final p = base + offset;
      offset += (bytes + 15) & ~15;
      if (offset > _size) throw StateError('RenderState scratch overflow');
      return p;
    }

    handleSlot = take(sizeOf<Pointer<Void>>()).cast();
    value = take(16);
    written = take(sizeOf<Size>()).cast();
    outY = take(sizeOf<Uint16>()).cast();

    stateKeys = take(stateKeyCount * sizeOf<UnsignedInt>()).cast();
    stateValues = take(stateKeyCount * sizeOf<Pointer<Void>>()).cast();
    cols = take(sizeOf<Uint16>()).cast();
    rows = take(sizeOf<Uint16>()).cast();
    dirty = take(sizeOf<UnsignedInt>()).cast();
    cursor = take(sizeOf<GhosttyRenderStateCursor>()).cast();
    colors = take(sizeOf<GhosttyRenderStateColors>()).cast();
    _fill(stateKeys, stateValues, [
      (GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLS, cols.cast()),
      (GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROWS, rows.cast()),
      (GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_DIRTY, dirty.cast()),
      (GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR, cursor.cast()),
    ]);

    rowKeys = take(rowKeyCount * sizeOf<UnsignedInt>()).cast();
    rowValues = take(rowKeyCount * sizeOf<Pointer<Void>>()).cast();
    viewportY = take(sizeOf<Int32>()).cast();
    rowId = take(sizeOf<GhosttyRenderStateRowId>()).cast();
    rowDirty = take(sizeOf<Bool>()).cast();
    cellsView = take(sizeOf<GhosttyCellsView>()).cast();
    selection = take(sizeOf<GhosttyRenderStateRowSelection>()).cast();
    // Initialised once: the library writes only start_x / end_x.
    selection.initSized(sizeOf<GhosttyRenderStateRowSelection>());
    _fill(rowKeys, rowValues, [
      (
        GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y,
        viewportY.cast(),
      ),
      (
        GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_ID,
        rowId.cast(),
      ),
      (
        GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
        rowDirty.cast(),
      ),
      (
        GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW,
        cellsView.cast(),
      ),
      // Last, because it is the only key that can return NO_VALUE and
      // get_multi stops at the first failing key.
      (
        GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION,
        selection.cast(),
      ),
    ]);

    style = take(sizeOf<GhosttyStyle>()).cast();
    codepoints = take(sizeOf<GhosttyCodepointBuffer>()).cast();
    imageKeys = take(_ImageReader.keyCount * sizeOf<UnsignedInt>()).cast();
    imageValues = take(_ImageReader.keyCount * sizeOf<Pointer<Void>>()).cast();
    imageSlots = take(_ImageReader.keyCount * _ImageReader.slotSize);
  }

  static const _size = 2048;

  /// Keys of the per-update read: cols, rows, dirty, cursor.
  static const stateKeyCount = 4;

  /// Keys of the per-row read: viewport y, id, dirty, raw cells, selection.
  static const rowKeyCount = 5;

  /// Index of the selection key in the per-row read.
  static const rowSelectionIndex = 4;

  final GrowableNativeBuffer _memory;

  late final Pointer<Pointer<Void>> handleSlot;
  late final Pointer<Uint8> value;
  late final Pointer<Size> written;
  late final Pointer<Uint16> outY;

  late final Pointer<UnsignedInt> stateKeys;
  late final Pointer<Pointer<Void>> stateValues;
  late final Pointer<Uint16> cols;
  late final Pointer<Uint16> rows;
  late final Pointer<UnsignedInt> dirty;
  late final Pointer<GhosttyRenderStateCursor> cursor;
  late final Pointer<GhosttyRenderStateColors> colors;

  late final Pointer<UnsignedInt> rowKeys;
  late final Pointer<Pointer<Void>> rowValues;
  late final Pointer<Int32> viewportY;
  late final Pointer<GhosttyRenderStateRowId> rowId;
  late final Pointer<Bool> rowDirty;
  late final Pointer<GhosttyCellsView> cellsView;
  late final Pointer<GhosttyRenderStateRowSelection> selection;

  late final Pointer<GhosttyStyle> style;
  late final Pointer<GhosttyCodepointBuffer> codepoints;
  late final Pointer<UnsignedInt> imageKeys;
  late final Pointer<Pointer<Void>> imageValues;
  late final Pointer<Uint8> imageSlots;

  static void _fill(
    Pointer<UnsignedInt> keys,
    Pointer<Pointer<Void>> values,
    List<(int, Pointer<Void>)> entries,
  ) {
    for (var i = 0; i < entries.length; i++) {
      keys[i] = entries[i].$1;
      values[i] = entries[i].$2;
    }
  }

  void dispose() => _memory.dispose();
}

/// Reads every field of the current image placement with one
/// `ghostty_render_state_image_get_multi` call into 8-byte slots of
/// [_Scratch.imageSlots].
final class _ImageReader {
  _ImageReader(this._scratch) : assert(_keys.length == keyCount) {
    for (var i = 0; i < keyCount; i++) {
      _scratch.imageKeys[i] = _keys[i];
      _scratch.imageValues[i] = (_scratch.imageSlots + i * slotSize).cast();
    }
  }

  final _Scratch _scratch;

  /// Kitty-only keys come last: for another protocol they return NO_VALUE,
  /// and `get_multi` stops at the first failing key.
  static const _keys = [
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID,
    GhosttyRenderStateImageData
        .GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_Z,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_COLS,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_ROWS,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT,
    GhosttyRenderStateImageData
        .GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_PLACEMENT_ID,
    GhosttyRenderStateImageData.GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_KIND,
  ];

  /// Number of keys read per placement.
  static const keyCount = 19;

  /// Bytes per value slot: room for the widest value (`uint64_t`).
  static const slotSize = 8;

  /// Index of the first Kitty-only key in [_keys].
  static const _firstKittyKey = 17;

  RenderImagePlacement read(
    Pointer<GhosttyRenderStateImageIteratorImpl> iterator,
  ) {
    final slots = _scratch.imageSlots;
    slots.asTypedList(keyCount * slotSize).fillRange(0, keyCount * slotSize, 0);
    _scratch.written.value = 0;
    final code = checkResultAllowing(
      ghostty_render_state_image_get_multi(
        iterator,
        keyCount,
        _scratch.imageKeys,
        _scratch.imageValues,
        _scratch.written,
      ),
      'ghostty_render_state_image_get_multi',
      const {GhosttyResultCode.noValue},
    );
    final hasKitty = code == GhosttyResultCode.success;
    if (!hasKitty && _scratch.written.value != _firstKittyKey) {
      throw GhosttyException(
        'ghostty_render_state_image_get_multi',
        resultCodec.encode(code),
      );
    }
    int u32(int i) => (slots + i * slotSize).cast<Uint32>().value;
    int i32(int i) => (slots + i * slotSize).cast<Int32>().value;
    return RenderImagePlacement(
      protocol: imageProtocolCodec.decode(u32(0)),
      imageId: u32(1),
      imageGeneration: (slots + 2 * slotSize).cast<Uint64>().value,
      layer: imageLayerCodec.decode(u32(3)),
      z: i32(4),
      viewportCol: i32(5),
      viewportRow: i32(6),
      gridCols: u32(7),
      gridRows: u32(8),
      cellOffsetX: u32(9),
      cellOffsetY: u32(10),
      pixelWidth: u32(11),
      pixelHeight: u32(12),
      sourceX: u32(13),
      sourceY: u32(14),
      sourceWidth: u32(15),
      sourceHeight: u32(16),
      kittyPlacementId: hasKitty ? u32(17) : null,
      kittyKind: hasKitty ? kittyPlacementKindCodec.decode(u32(18)) : null,
    );
  }
}

/// The iterable behind [RenderState.allRows] and [RenderState.dirtyRows]:
/// each `iterator` starts a new native row iteration.
final class _RowIterable extends Iterable<RenderRow> {
  _RowIterable(this._state, {required bool dirtyOnly}) : _dirtyOnly = dirtyOnly;

  final RenderState _state;
  final bool _dirtyOnly;

  @override
  Iterator<RenderRow> get iterator => _RowIterator(_state, _dirtyOnly);
}

final class _RowIterator implements Iterator<RenderRow> {
  _RowIterator(this._state, this._dirtyOnly);

  final RenderState _state;
  final bool _dirtyOnly;

  /// The state token of this iteration; `null` before the first
  /// [moveNext], -1 once finished.
  int? _token;
  int _index = 0;

  @override
  RenderRow get current {
    final token = _token;
    if (token == null || token < 0) {
      throw StateError('No current row: call moveNext() first');
    }
    return _state._row;
  }

  @override
  bool moveNext() {
    final state = _state;
    var token = _token;
    if (token == null) {
      token = _token = _start();
    } else if (token < 0) {
      return false;
    } else if (token != state._token) {
      throw StateError(
        'RenderState changed during row iteration (it was updated, disposed '
        'or another iteration started)',
      );
    }
    final iterator = state._rowIterator.pointer;
    final int index;
    if (_dirtyOnly) {
      if (!ghostty_render_state_row_iterator_next_dirty(
        iterator,
        state._scratch.outY,
      )) {
        return _finish();
      }
      index = state._scratch.outY.value;
    } else {
      if (!ghostty_render_state_row_iterator_next(iterator)) return _finish();
      index = _index++;
    }
    state._row._load(token, index);
    return true;
  }

  int _start() {
    final state = _state.._checkReadable();
    final token = ++state._token;
    state._scratch.handleSlot.value = state._rowIterator.pointer.cast();
    checkResult(
      ghostty_render_state_get(
        state._handle.pointer,
        GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
        state._scratch.handleSlot.cast(),
      ),
      'ghostty_render_state_get',
    );
    return token;
  }

  bool _finish() {
    // The reused row view must not outlive the iteration.
    if (_token == _state._token) _state._token++;
    _token = -1;
    return false;
  }
}
