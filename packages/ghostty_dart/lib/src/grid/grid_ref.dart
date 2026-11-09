/// Untracked grid references (`grid_ref.h`, `screen.h`) and the
/// [VtTerminalGrid] extension that creates them.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../render/cell_layout.dart';
import '../terminal/terminal.dart' show VtTerminal;
import '../terminal/terminal_native.dart' show checkNotInCallback, readUint16;
import 'grid_enums.dart';
import 'grid_values.dart';
import 'tracked_grid_ref.dart';

/// Random access to any cell of a [VtTerminal], by [GridPoint], anywhere in
/// the scrollback.
///
/// ```dart
/// final ref = terminal.gridRef(const GridPoint.active(0, 0));
/// if (ref != null) print('${ref.text} ${ref.style}');
/// ```
///
/// Grid references are meant for reading particular cells (hyperlink
/// lookup, word selection, accessibility). They are not fast enough to draw
/// frames: use `RenderState` for that.
///
/// These members are only visible when this extension is imported; the
/// package barrel exports it.
extension VtTerminalGrid on VtTerminal {
  /// Resolves [point] to a [GridRef] for that cell, or returns `null` when
  /// [point] is outside its coordinate space (a column past the right edge
  /// or a row past the bottom).
  ///
  /// libghostty-vt 1.0.0 counts [PointSpace.history] rows like
  /// [PointSpace.screen] rows: history row 0 is the oldest scrollback row,
  /// and history rows past the scrollback resolve into the active area.
  ///
  /// The reference is **borrowed**: it is valid only until the next call
  /// that changes the terminal (see [GridRef]). Use [trackGridRef] to follow
  /// a cell across changes.
  ///
  /// [PointSpace.active] and [PointSpace.viewport] lookups are fast;
  /// [PointSpace.screen] and [PointSpace.history] may walk the whole
  /// scrollback.
  ///
  /// Throws [ArgumentError] for [PointSpace.unknown], [StateError] after
  /// [VtTerminal.dispose] or when called from inside a callback of this
  /// terminal.
  GridRef? gridRef(GridPoint point) {
    final handle = handleOf<GhosttyTerminalImpl>(this);
    checkNotInCallback(handle, 'gridRef');
    return withScratch(_pointBytes + sizeOf<GhosttyGridRef>(), (block) {
      final nativePoint = block.cast<GhosttyPoint>();
      final out = (block + _pointBytes).cast<GhosttyGridRef>();
      gridPointToNative(point, nativePoint.ref);
      final code = checkResultAllowing(
        ghostty_terminal_grid_ref(handle.pointer, nativePoint.ref, out),
        'ghostty_terminal_grid_ref',
        const {GhosttyResultCode.invalidValue},
      );
      return code == GhosttyResultCode.success
          ? gridRefFromNative(handle, out.ref)
          : null;
    });
  }

  /// Starts tracking the cell at [point] with a new, owned
  /// [TrackedGridRef], or returns `null` when [point] is outside its
  /// coordinate space.
  ///
  /// The tracked reference follows its cell through scrolling and
  /// resize/reflow, and has no value once its cell is pruned from the
  /// scrollback. It belongs to the screen (primary or
  /// alternate) that is active now. Dispose it when done; disposing this
  /// terminal disposes it too.
  ///
  /// Throws [ArgumentError] for [PointSpace.unknown], [StateError] after
  /// [VtTerminal.dispose] or when called from inside a callback of this
  /// terminal, and [GhosttyException] if the library runs out of memory.
  TrackedGridRef? trackGridRef(GridPoint point) {
    final handle = handleOf<GhosttyTerminalImpl>(this);
    checkNotInCallback(handle, 'trackGridRef');
    final pointer = withScratch(_pointBytes + sizeOf<Pointer<Void>>(), (block) {
      final nativePoint = block.cast<GhosttyPoint>();
      final out = (block + _pointBytes).cast<GhosttyTrackedGridRef>();
      gridPointToNative(point, nativePoint.ref);
      final code = checkResultAllowing(
        ghostty_terminal_grid_ref_track(handle.pointer, nativePoint.ref, out),
        'ghostty_terminal_grid_ref_track',
        const {GhosttyResultCode.invalidValue},
      );
      return code == GhosttyResultCode.success ? out.value : nullptr;
    });
    return pointer == nullptr ? null : newTrackedGridRef(this, pointer);
  }
}

/// A **borrowed** reference to one cell of a terminal (`GhosttyGridRef`).
///
/// Get one from [VtTerminalGrid.gridRef] or [TrackedGridRef.snapshot].
///
/// **Lifetime:** a grid reference is an untracked snapshot of where the
/// cell lives in the terminal's memory. It is valid only until the next
/// call that changes the terminal (`write`, `resize`, `reset`, scrolling
/// the viewport, setting an option, ...), and it cannot be used from
/// inside a callback of the terminal. After that every member throws
/// [StateError]; check [isValid] first if unsure. Values read from it
/// ([cell], [row], [style], [text], ...) are copies and stay valid. To
/// follow a cell across changes, use a [TrackedGridRef].
///
/// Each member makes one native call (two for [background]); there is no
/// per-reference native memory to free.
final class GridRef implements Finalizable {
  GridRef._(this._terminal, this._node, this._x, this._y)
    : _epoch = _terminal.epoch;

  /// The terminal's handle; also keeps the native terminal alive.
  final NativeHandle<GhosttyTerminalImpl> _terminal;
  final int _epoch;

  // The opaque `GhosttyGridRef` fields, copied out of the library's value
  // (a page address and an in-page position). They are not dereferenced in
  // Dart; [_checkValid] guarantees they are only passed back while current.
  final int _node;
  final int _x;
  final int _y;

  /// Whether this reference can still be used: its terminal is not
  /// disposed, has not changed since the reference was made, and is not
  /// running a callback.
  bool get isValid =>
      !_terminal.isDisposed && _terminal.epoch == _epoch && !_terminal.isInUse;

  /// The cell's packed data: codepoint, width, flags and the colour of a
  /// colour-only cell.
  GridCell get cell => _withNativeRef(sizeOf<Uint64>(), (ref, out) {
    final cell = out.cast<Uint64>();
    checkResult(ghostty_grid_ref_cell(ref, cell), 'ghostty_grid_ref_cell');
    return _decodeCell(cell);
  });

  /// The flags of the cell's row (wrap, prompt, dirty, ...), read in one
  /// native call.
  GridRow get row => _withNativeRef(_RowKeys.bytes, (ref, out) {
    final row = out.cast<Uint64>();
    checkResult(ghostty_grid_ref_row(ref, row), 'ghostty_grid_ref_row');
    return _RowKeys.read(row.value, out + sizeOf<Uint64>());
  });

  /// The cell's style (colours and attributes). [CellStyle.isDefault] for
  /// an unstyled cell.
  CellStyle get style => _withNativeRef(sizeOf<GhosttyStyle>(), (ref, out) {
    final style = out.cast<GhosttyStyle>();
    checkResult(ghostty_grid_ref_style(ref, style), 'ghostty_grid_ref_style');
    return cellStyleFromNative(style.ref);
  });

  /// The cell's background: the colour of a colour-only cell
  /// ([GridCell.backgroundColor]), else its style's background.
  /// [DefaultColor] means the terminal default background. Inverse video is
  /// not applied.
  ColorRef get background => cell.backgroundColor ?? style.background;

  /// The codepoints of the cell's full grapheme cluster (the base codepoint
  /// followed by any combining ones), or an empty list for an empty cell,
  /// a colour-only cell or a spacer. A new, unmodifiable list.
  List<int> get codepoints => _withNativeRef(0, (ref, _) {
    final bytes = tryCallWithSizeQuery('ghostty_grid_ref_graphemes', (
      buffer,
      capacity,
      outLength,
    ) {
      final raw = ghostty_grid_ref_graphemes(
        ref,
        buffer.cast(),
        capacity ~/ sizeOf<Uint32>(),
        outLength,
      );
      // The library counts codepoints; the helper counts bytes.
      outLength.value *= sizeOf<Uint32>();
      return raw;
    }, initialCapacity: _graphemeCapacity * sizeOf<Uint32>())!;
    return bytes.buffer.asUint32List().asUnmodifiableView();
  });

  /// The cell's text: its full grapheme cluster as a string, or `''` for an
  /// empty cell, a colour-only cell or a spacer.
  String get text => String.fromCharCodes(codepoints);

  /// The URI of the OSC 8 hyperlink the cell belongs to, or `null` if it has
  /// none. Malformed UTF-8 is replaced with U+FFFD.
  String? get hyperlinkUri => _withNativeRef(0, (ref, _) {
    final bytes = tryCallWithSizeQuery(
      'ghostty_grid_ref_hyperlink_uri',
      (buffer, capacity, outLength) =>
          ghostty_grid_ref_hyperlink_uri(ref, buffer, capacity, outLength),
      initialCapacity: _uriCapacity,
    )!;
    return bytes.isEmpty ? null : utf8.decode(bytes, allowMalformed: true);
  });

  /// The cell's position in [space], or `null` when the cell cannot be
  /// expressed there (e.g. a scrollback cell has no [PointSpace.active]
  /// position, and a cell scrolled out of view has no
  /// [PointSpace.viewport] position).
  ///
  /// Throws [ArgumentError] for [PointSpace.unknown].
  GridPoint? pointIn(PointSpace space) {
    final tag = pointSpaceCodec.encode(space);
    return _withNativeRef(
      sizeOf<GhosttyPointCoordinate>(),
      (ref, out) => readPointCoordinate(
        _terminal,
        space,
        out,
        (coordinate) => ghostty_terminal_point_from_grid_ref(
          _terminal.pointer,
          ref,
          tag,
          coordinate,
        ),
        'ghostty_terminal_point_from_grid_ref',
      ),
    );
  }

  @override
  String toString() => 'GridRef(${isValid ? 'valid' : 'stale'})';

  void _checkValid() {
    if (_terminal.isDisposed) {
      throw StateError(
        'GridRef is no longer valid: the terminal has been disposed',
      );
    }
    if (_terminal.epoch != _epoch || _terminal.isInUse) {
      throw StateError('GridRef is no longer valid: the terminal changed');
    }
  }

  /// Runs [action] with a native copy of this reference and [extra] bytes
  /// of zeroed, 8-byte aligned scratch memory after it.
  R _withNativeRef<R>(
    int extra,
    R Function(Pointer<GhosttyGridRef> ref, Pointer<Uint8> out) action,
  ) {
    _checkValid();
    return withScratch(_refBytes + extra, (block) {
      final ref = block.cast<GhosttyGridRef>();
      ref.ref
        ..node = Pointer.fromAddress(_node)
        ..x = _x
        ..y = _y;
      return action(ref, block + _refBytes);
    });
  }

  /// Most clusters are one codepoint; eight covers nearly all emoji
  /// sequences in one call.
  static const _graphemeCapacity = 8;

  /// Covers typical URLs in one call; longer ones take a second call.
  static const _uriCapacity = 256;
}

/// Wraps a native `GhosttyGridRef` value made by the library for the
/// terminal behind [terminal]. The reference is valid for the terminal's
/// current epoch.
GridRef gridRefFromNative(
  NativeHandle<GhosttyTerminalImpl> terminal,
  GhosttyGridRef ref,
) => GridRef._(terminal, ref.node.address, ref.x, ref.y);

/// Calls [query] with a `GhosttyPointCoordinate` out-parameter at [out] and
/// returns the coordinate as a [GridPoint] in [space], or `null` for
/// `GHOSTTY_NO_VALUE`. Other errors throw.
///
/// libghostty-vt 1.0.0 only rejects cells *above* the viewport: a cell below
/// a scrolled-up viewport comes back with a row past its bottom. The header
/// promises "no value" for any cell off the visible area, so such rows of
/// [terminal] (the terminal that owns the reference) also give `null`.
GridPoint? readPointCoordinate(
  NativeHandle<GhosttyTerminalImpl> terminal,
  PointSpace space,
  Pointer<Uint8> out,
  int Function(Pointer<GhosttyPointCoordinate> coordinate) query,
  String operation,
) {
  final coordinate = out.cast<GhosttyPointCoordinate>();
  if (!checkResultHasValue(query(coordinate), operation)) return null;
  final x = coordinate.ref.x;
  final y = coordinate.ref.y;
  if (space == PointSpace.viewport &&
      y >=
          readUint16(
            terminal.pointer,
            GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ROWS,
          )) {
    return null;
  }
  return GridPoint(space, x, y);
}

final int _pointBytes = _align8(sizeOf<GhosttyPoint>());
final int _refBytes = _align8(sizeOf<GhosttyGridRef>());

int _align8(int bytes) => (bytes + 7) & ~7;

/// Decodes the packed cell at [cell], transcoding it first when the loaded
/// library does not use the canonical layout (see `cell_layout.dart`).
GridCell _decodeCell(Pointer<Uint64> cell) {
  final int bits;
  if (nativeCellLayoutIsCanonical) {
    bits = cell.value;
  } else {
    _transcoder.transcode(cell, 1, _transcoded);
    bits = _transcoded[0];
  }
  final packed = PackedCell(bits);
  return GridCell(
    codepoint: packed.codepoint,
    hasGrapheme: packed.hasGrapheme,
    width: packed.width,
    hasStyling: packed.styleId != 0,
    hasHyperlink: packed.hasHyperlink,
    isProtected: packed.isProtected,
    semanticContent: packed.semanticContent,
    backgroundColor: packed.backgroundColor,
  );
}

/// Only used for libraries with a non-canonical cell layout; created on
/// first use and kept for the isolate (it owns a small native block).
final _transcoder = CellTranscoder();
final _transcoded = Uint64List(1);

/// The `ghostty_row_get_multi` batch behind [GridRef.row]: the keys, their
/// value slots and the decoding.
abstract final class _RowKeys {
  // Slot of each key in [_keys] and in the value block.
  static const _wrap = 0;
  static const _wrapContinuation = 1;
  static const _grapheme = 2;
  static const _styled = 3;
  static const _hyperlink = 4;
  static const _semanticPrompt = 5;
  static const _kittyVirtualPlaceholder = 6;
  static const _dirty = 7;
  static const _count = 8;

  /// The keys, in slot order.
  static const _keys = [
    GhosttyRowData.GHOSTTY_ROW_DATA_WRAP,
    GhosttyRowData.GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
    GhosttyRowData.GHOSTTY_ROW_DATA_GRAPHEME,
    GhosttyRowData.GHOSTTY_ROW_DATA_STYLED,
    GhosttyRowData.GHOSTTY_ROW_DATA_HYPERLINK,
    GhosttyRowData.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT,
    GhosttyRowData.GHOSTTY_ROW_DATA_KITTY_VIRTUAL_PLACEHOLDER,
    GhosttyRowData.GHOSTTY_ROW_DATA_DIRTY,
  ];

  /// Every slot is 8 bytes; each holds a 1-byte `bool` or a 4-byte enum.
  static const _slotSize = 8;

  /// The row value, the value-pointer array, the key array and the slots.
  static final int bytes =
      sizeOf<Uint64>() +
      _count * sizeOf<Pointer<Void>>() +
      _align8(_count * sizeOf<UnsignedInt>()) +
      _count * _slotSize;

  /// Reads every key of [row] in one call, using the memory at [block].
  static GridRow read(int row, Pointer<Uint8> block) {
    assert(_keys.length == _count);
    final values = block.cast<Pointer<Void>>();
    final keys = (block + _count * sizeOf<Pointer<Void>>()).cast<UnsignedInt>();
    final slots =
        block +
        _count * sizeOf<Pointer<Void>>() +
        _align8(_count * sizeOf<UnsignedInt>());
    for (var i = 0; i < _count; i++) {
      keys[i] = _keys[i];
      values[i] = (slots + i * _slotSize).cast();
    }
    checkResult(
      ghostty_row_get_multi(row, _count, keys, values, nullptr),
      'ghostty_row_get_multi',
    );
    bool flag(int slot) => slots[slot * _slotSize] != 0;
    return GridRow(
      isWrapped: flag(_wrap),
      isWrapContinuation: flag(_wrapContinuation),
      hasGraphemes: flag(_grapheme),
      hasStyling: flag(_styled),
      hasHyperlinks: flag(_hyperlink),
      semanticPrompt: rowSemanticPromptCodec.decode(
        (slots + _semanticPrompt * _slotSize).cast<UnsignedInt>().value,
      ),
      hasKittyVirtualPlaceholder: flag(_kittyVirtualPlaceholder),
      isDirty: flag(_dirty),
    );
  }
}
