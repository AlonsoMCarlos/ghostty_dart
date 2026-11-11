import 'package:ghostty_dart/ghostty_dart.dart';

import '../../utils/circular_buffer.dart';
import '../cell.dart';
import 'buffer.dart';
import 'line.dart';
import 'terminal_engine.dart';
import 'tracked_anchor.dart';

/// The lines of one [Buffer], read from libghostty-vt on demand. Never
/// exported.
///
/// A line is materialised (copied into a [BufferLine]) the first time it is
/// read and cached until the terminal changes ([TerminalEngine.epoch]).
/// Only the active screen can be read (libghostty-vt 1.0.0): a buffer
/// whose screen is not active, or a buffer not created by a `Terminal`,
/// reads as [Buffer.viewHeight] blank lines.
final class BufferLines
    implements IndexedItemSource<BufferLine>, IndexedItemOwner {
  /// Creates the lines of [buffer].
  BufferLines(this.buffer) : engine = terminalEngineOf(buffer.terminal);

  /// The buffer these lines belong to.
  final Buffer buffer;

  /// The terminal's engine, or `null` for a buffer not created by a
  /// `Terminal`.
  final TerminalEngine? engine;

  final _cache = <int, BufferLine>{};
  int _cacheEpoch = -1;

  /// The tracked anchors created in this buffer, weakly: [Buffer.clear]
  /// detaches them, as xterm's does.
  final _anchors = <WeakReference<TrackedCellAnchor>>[];

  int get _epoch => engine?.epoch ?? 0;

  /// Whether this buffer's screen is the terminal's active screen.
  bool get isActive {
    final engine = this.engine;
    if (engine == null) return false;
    final alternate = engine.vt.activeScreen == TerminalScreen.alternate;
    return alternate == buffer.isAltBuffer;
  }

  /// The active terminal, or `null` when this buffer is not active.
  VtTerminal? get activeVt => isActive ? engine!.vt : null;

  @override
  int get maxLength => buffer.maxLines;

  @override
  int get length => activeVt?.totalRows ?? buffer.viewHeight;

  @override
  BufferLine itemAt(int index) {
    final epoch = _epoch;
    if (epoch != _cacheEpoch) {
      _cache.clear();
      _cacheEpoch = epoch;
    }
    return _cache[index] ??= _load(index, epoch);
  }

  BufferLine _load(int y, int epoch) {
    final vt = activeVt;
    final line = vt == null
        ? BufferLine(buffer.viewWidth)
        : materializeLine(vt, y, cols: vt.cols, scrollback: vt.scrollbackRows);
    attachIndexedItem(line, this, y, epoch);
    return line;
  }

  @override
  bool isCurrent(int epoch) =>
      !(engine?.isDisposed ?? false) && epoch == _epoch;

  /// A tracked anchor at cell [offset] of [line], or `null` when [line] is
  /// not a current line of this (active) buffer or [offset] is outside the
  /// grid.
  CellAnchor? track(BufferLine line, int offset) {
    if (!line.attached || offset < 0) return null;
    final vt = activeVt;
    if (vt == null) return null;
    final ref = vt.trackGridRef(GridPoint.screen(offset, line.index));
    if (ref == null) return null;
    final anchor = TrackedCellAnchor(
      offset,
      owner: line,
      ref: ref,
      lines: this,
    );
    if (_anchors.length >= 64) {
      _anchors.removeWhere((weak) => weak.target?.ref.isDisposed ?? true);
    }
    _anchors.add(WeakReference(anchor));
    return anchor;
  }

  /// Stops tracking every anchor created in this buffer: they are no
  /// longer attached ([Buffer.clear] replaces every line in xterm).
  void detachAnchors() {
    for (final weak in _anchors) {
      final ref = weak.target?.ref;
      if (ref != null && !ref.isDisposed) ref.dispose();
    }
    _anchors.clear();
  }
}

/// Copies screen row [y] of [vt] (0 is the oldest scrollback row) into a
/// new [BufferLine] in xterm's cell format.
///
/// One `gridRef` and one `cell` read per cell, plus one `style` read per
/// styled cell: libghostty-vt 1.0.0 has no batched read of an arbitrary
/// scrollback row that leaves the view's render state alone (a second
/// `RenderState` would consume the terminal's dirty tracking). Rows of
/// the active area are addressed in [PointSpace.active], which resolves
/// without walking the scrollback.
BufferLine materializeLine(
  VtTerminal vt,
  int y, {
  required int cols,
  required int scrollback,
}) {
  final line = BufferLine(cols);
  final inActive = y >= scrollback;
  final activeY = y - scrollback;
  final styles = <CellStyle, _PackedStyle>{};
  for (var x = 0; x < cols; x++) {
    final ref = vt.gridRef(
      inActive ? GridPoint.active(x, activeY) : GridPoint.screen(x, y),
    );
    if (ref == null) break;
    if (x == 0) line.isWrapped = ref.row.isWrapContinuation;
    final cell = ref.cell;
    final codepoint = cell.codepoint;
    if (codepoint != 0) {
      final width = switch (cell.width) {
        CellWidth.wide => 2,
        CellWidth.spacerTail || CellWidth.spacerHead => 0,
        CellWidth.narrow || CellWidth.unknown => 1,
      };
      line.setContent(x, codepoint | (width << CellContent.widthShift));
    }
    if (cell.hasStyling) {
      final style = ref.style;
      final packed = styles[style] ??= _PackedStyle.of(style);
      line
        ..setForeground(x, packed.foreground)
        ..setBackground(x, packed.background)
        ..setAttributes(x, packed.attributes);
    }
    final background = cell.backgroundColor;
    if (background != null) {
      line.setBackground(x, packColor(background));
    }
  }
  return line;
}

/// [color] in xterm's packed format ([CellColor]): the default colour is
/// 0, palette entries below 16 are named colours, the rest palette
/// colours (libghostty-vt does not tell SGR 31 from SGR 38;5;1).
int packColor(ColorRef color) => switch (color) {
  DefaultColor() => CellColor.normal,
  PaletteColor(:final index) when index < 16 => CellColor.named | index,
  PaletteColor(:final index) => CellColor.palette | index,
  RgbColor(:final r, :final g, :final b) =>
    CellColor.rgb | (r << 16) | (g << 8) | b,
};

/// [style]'s attributes as [CellAttr] bits. Any underline style counts as
/// underline; overline has no xterm bit.
int packAttributes(CellStyle style) {
  var attrs = 0;
  if (style.bold) attrs |= CellAttr.bold;
  if (style.faint) attrs |= CellAttr.faint;
  if (style.italic) attrs |= CellAttr.italic;
  if (style.underline != UnderlineStyle.none) attrs |= CellAttr.underline;
  if (style.blink) attrs |= CellAttr.blink;
  if (style.inverse) attrs |= CellAttr.inverse;
  if (style.invisible) attrs |= CellAttr.invisible;
  if (style.strikethrough) attrs |= CellAttr.strikethrough;
  return attrs;
}

final class _PackedStyle {
  _PackedStyle.of(CellStyle style)
    : foreground = packColor(style.foreground),
      background = packColor(style.background),
      attributes = packAttributes(style);

  final int foreground;
  final int background;
  final int attributes;
}
