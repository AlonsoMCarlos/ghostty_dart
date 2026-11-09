/// Immutable values read from a render state: cursor, colours, overscan,
/// row identity, cell snapshots and image placements.
///
/// Pure Dart (no `dart:ffi`), so a future web backend can reuse them.
library;

import '../core/color.dart';
import '../core/list_equality.dart';
import '../core/point.dart';
import '../core/style.dart';
import '../core/terminal_enums.dart';
import 'render_enums.dart';

/// Everything a renderer needs to draw the cursor for one frame
/// (`GhosttyRenderStateCursor`).
///
/// Read it from `RenderState.cursor` after an update. It is a copy: it
/// stays valid after later updates.
final class RenderCursor {
  /// Creates a cursor description. Mostly for tests; renderers get one from
  /// `RenderState.cursor`.
  const RenderCursor({
    required this.style,
    required this.isVisible,
    required this.isBlinking,
    required this.isPasswordInput,
    this.position,
    this.isOnWideTail = false,
  });

  /// The shape to draw (DECSCUSR).
  final VtCursorStyle style;

  /// Whether the terminal modes make the cursor visible (DECTCEM). Even
  /// when `true`, draw it only if [position] is not `null`.
  final bool isVisible;

  /// Whether the terminal modes ask the cursor to blink.
  final bool isBlinking;

  /// Whether the cursor is at a password prompt, for renderers that show a
  /// lock or similar hint.
  final bool isPasswordInput;

  /// The cursor cell in viewport coordinates ([PointSpace.viewport]), or
  /// `null` when the cursor is outside the viewport (e.g. the user
  /// scrolled back).
  final GridPoint? position;

  /// Whether the cursor sits on the second (spacer) column of a wide
  /// character; draw it over the whole wide character at `position.x - 1`.
  /// Always `false` when [position] is `null`.
  final bool isOnWideTail;

  @override
  bool operator ==(Object other) =>
      other is RenderCursor &&
      other.style == style &&
      other.isVisible == isVisible &&
      other.isBlinking == isBlinking &&
      other.isPasswordInput == isPasswordInput &&
      other.position == position &&
      other.isOnWideTail == isOnWideTail;

  @override
  int get hashCode => Object.hash(
    style,
    isVisible,
    isBlinking,
    isPasswordInput,
    position,
    isOnWideTail,
  );

  @override
  String toString() =>
      'RenderCursor($style, visible: $isVisible, blinking: $isBlinking, '
      'position: $position${isOnWideTail ? ', wide tail' : ''}'
      '${isPasswordInput ? ', password input' : ''})';
}

/// The colours of one frame: default foreground and background, the
/// explicit cursor colour and the 256-colour palette
/// (`GhosttyRenderStateColors`).
///
/// Read it from `RenderState.colors`. It is a copy and stays valid after
/// later updates. Use [resolve] to turn a cell's [ColorRef] into a colour
/// to draw.
final class RenderColors {
  /// Creates a colour set. [palette] must have 256 entries; it is copied
  /// into an unmodifiable list.
  RenderColors({
    required this.background,
    required this.foreground,
    required List<RgbColor> palette,
    this.cursor,
  }) : palette = List.unmodifiable(palette) {
    if (palette.length != 256) {
      throw ArgumentError.value(
        palette.length,
        'palette.length',
        'must be 256',
      );
    }
  }

  /// The default background colour (OSC 11 can change it).
  final RgbColor background;

  /// The default foreground colour (OSC 10 can change it).
  final RgbColor foreground;

  /// The cursor colour set by the terminal (OSC 12), or `null` when none is
  /// set and the renderer picks its own.
  final RgbColor? cursor;

  /// The active 256-colour palette (OSC 4 can change entries). Unmodifiable.
  final List<RgbColor> palette;

  /// The concrete colour of [color]: a palette entry is looked up in
  /// [palette], an [RgbColor] is returned as is, and [DefaultColor] returns
  /// `null` (draw the default [foreground] or [background]).
  RgbColor? resolve(ColorRef color) => switch (color) {
    DefaultColor() => null,
    PaletteColor(:final index) => palette[index],
    RgbColor() => color,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RenderColors &&
        other.background == background &&
        other.foreground == foreground &&
        other.cursor == cursor &&
        listEquals(other.palette, palette);
  }

  @override
  int get hashCode =>
      Object.hash(background, foreground, cursor, Object.hashAll(palette));

  @override
  String toString() =>
      'RenderColors(background: $background, foreground: $foreground, '
      'cursor: $cursor)';
}

/// A number of rows above and below the viewport
/// (`GhosttyRenderStateOverscan`).
///
/// Used to request extra rows with `RenderState.overscanRequest` (useful for
/// smooth scrolling) and to report what an update captured with
/// `RenderState.overscan`.
final class RenderOverscan {
  /// Rows [above] and [below] the viewport, each 0–65535.
  const RenderOverscan({this.above = 0, this.below = 0})
    : assert(above >= 0 && above <= 0xFFFF, 'above must be 0-65535'),
      assert(below >= 0 && below <= 0xFFFF, 'below must be 0-65535');

  /// No overscan: only the viewport. The default.
  static const none = RenderOverscan();

  /// Rows above the top of the viewport.
  final int above;

  /// Rows below the bottom of the viewport.
  final int below;

  @override
  bool operator ==(Object other) =>
      other is RenderOverscan && other.above == above && other.below == below;

  @override
  int get hashCode => Object.hash(RenderOverscan, above, below);

  @override
  String toString() => 'RenderOverscan(above: $above, below: $below)';
}

/// The identity of a row across render state updates
/// (`GhosttyRenderStateRowId`).
///
/// Opaque: only equality is meaningful. A row keeps its id while it scrolls,
/// so a renderer can key per-row caches (laid-out paragraphs, textures) by
/// it and reuse them when the row merely moved.
final class RenderRowId {
  /// Wraps the two opaque words of a native row id.
  const RenderRowId(this._high, this._low);

  final int _high;
  final int _low;

  @override
  bool operator ==(Object other) =>
      other is RenderRowId && other._high == _high && other._low == _low;

  @override
  int get hashCode => Object.hash(_high, _low);

  @override
  String toString() => 'RenderRowId(${_hex64(_high)}:${_hex64(_low)})';

  static String _hex64(int value) =>
      '${(value >>> 32).toRadixString(16).padLeft(8, '0')}'
      '${(value & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';
}

/// An immutable snapshot of one cell, from `RenderRow.cellsToList`.
///
/// Convenient for tests, accessibility and other cold paths. Renderers
/// should use the allocation-free `RenderRow` accessors instead.
final class RenderCell {
  /// Creates a cell snapshot.
  const RenderCell({
    required this.x,
    required this.text,
    required this.width,
    required this.style,
    required this.background,
    this.hasHyperlink = false,
    this.isProtected = false,
    this.isSelected = false,
    this.semanticContent = CellSemanticContent.output,
  });

  /// The column, 0-based.
  final int x;

  /// The cell's full grapheme cluster, or `''` for an empty cell or a
  /// spacer.
  final String text;

  /// Whether the cell is narrow, wide or a spacer to skip.
  final CellWidth width;

  /// The cell's style.
  final CellStyle style;

  /// The cell's own background: a colour set on a text-less cell (e.g. by
  /// erasing with a background colour) or else the style's background.
  /// [DefaultColor] means the terminal default.
  final ColorRef background;

  /// Whether the cell is part of an OSC 8 hyperlink.
  final bool hasHyperlink;

  /// Whether the cell is protected from erasing (DECSCA / SPA).
  final bool isProtected;

  /// Whether the cell is inside the current selection.
  final bool isSelected;

  /// The shell content kind (OSC 133).
  final CellSemanticContent semanticContent;

  @override
  bool operator ==(Object other) =>
      other is RenderCell &&
      other.x == x &&
      other.text == text &&
      other.width == width &&
      other.style == style &&
      other.background == background &&
      other.hasHyperlink == hasHyperlink &&
      other.isProtected == isProtected &&
      other.isSelected == isSelected &&
      other.semanticContent == semanticContent;

  @override
  int get hashCode => Object.hash(
    x,
    text,
    width,
    style,
    background,
    hasHyperlink,
    isProtected,
    isSelected,
    semanticContent,
  );

  @override
  String toString() =>
      'RenderCell($x, ${text.isEmpty ? 'empty' : '"$text"'}, $width'
      '${style.isDefault ? '' : ', $style'}'
      '${background is DefaultColor ? '' : ', background: $background'}'
      '${hasHyperlink ? ', hyperlink' : ''}${isSelected ? ', selected' : ''})';
}

/// Where and how to draw one image placement of a frame (one entry of the
/// render state's image iterator).
///
/// Read them with `RenderState.imagePlacements`. Pixel values use the cell
/// size passed to `VtTerminal.resize`. Fetch the image pixels from the
/// protocol's storage by [protocol] and [imageId] (the kitty graphics API),
/// and cache textures by `(protocol, imageId, imageGeneration)`.
final class RenderImagePlacement {
  /// Creates a placement description. Renderers get them from
  /// `RenderState.imagePlacements`.
  const RenderImagePlacement({
    required this.protocol,
    required this.imageId,
    required this.imageGeneration,
    required this.layer,
    required this.z,
    required this.viewportCol,
    required this.viewportRow,
    required this.gridCols,
    required this.gridRows,
    required this.cellOffsetX,
    required this.cellOffsetY,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.sourceX,
    required this.sourceY,
    required this.sourceWidth,
    required this.sourceHeight,
    this.kittyPlacementId,
    this.kittyKind,
  });

  /// The protocol the image came from; skip [ImageProtocol.unknown].
  final ImageProtocol protocol;

  /// The image id, unique only within [protocol].
  final int imageId;

  /// Changes whenever the image's pixels change (including animation
  /// frames). Only compare it for equality.
  final int imageGeneration;

  /// The layer to draw in.
  final ImageLayer layer;

  /// The z-index; lower values are drawn first within a [layer].
  final int z;

  /// The column of the top-left cell; 0 is the leftmost viewport column. It
  /// can be negative for fixed or relative placements, which are reported
  /// at full size and may need clipping.
  final int viewportCol;

  /// The row of the top-left cell; 0 is the top viewport row. Negative
  /// for rows above the viewport (overscan or clipped placements).
  final int viewportRow;

  /// The number of cell columns the placement covers.
  final int gridCols;

  /// The number of cell rows the placement covers.
  final int gridRows;

  /// Pixels from the left edge of the top-left cell to the image.
  final int cellOffsetX;

  /// Pixels from the top edge of the top-left cell to the image.
  final int cellOffsetY;

  /// The width to draw the image at, in pixels.
  final int pixelWidth;

  /// The height to draw the image at, in pixels.
  final int pixelHeight;

  /// The left edge of the source rectangle, in image pixels.
  final int sourceX;

  /// The top edge of the source rectangle, in image pixels.
  final int sourceY;

  /// The width of the source rectangle in image pixels; scale it to
  /// [pixelWidth].
  final int sourceWidth;

  /// The height of the source rectangle in image pixels; scale it to
  /// [pixelHeight].
  final int sourceHeight;

  /// Kitty only: the placement id (0 if the program gave none), or `null`
  /// for other protocols.
  final int? kittyPlacementId;

  /// Kitty only: the kind of placement, or `null` for other protocols.
  final KittyPlacementKind? kittyKind;

  @override
  bool operator ==(Object other) =>
      other is RenderImagePlacement &&
      other.protocol == protocol &&
      other.imageId == imageId &&
      other.imageGeneration == imageGeneration &&
      other.layer == layer &&
      other.z == z &&
      other.viewportCol == viewportCol &&
      other.viewportRow == viewportRow &&
      other.gridCols == gridCols &&
      other.gridRows == gridRows &&
      other.cellOffsetX == cellOffsetX &&
      other.cellOffsetY == cellOffsetY &&
      other.pixelWidth == pixelWidth &&
      other.pixelHeight == pixelHeight &&
      other.sourceX == sourceX &&
      other.sourceY == sourceY &&
      other.sourceWidth == sourceWidth &&
      other.sourceHeight == sourceHeight &&
      other.kittyPlacementId == kittyPlacementId &&
      other.kittyKind == kittyKind;

  @override
  int get hashCode => Object.hashAll([
    protocol,
    imageId,
    imageGeneration,
    layer,
    z,
    viewportCol,
    viewportRow,
    gridCols,
    gridRows,
    cellOffsetX,
    cellOffsetY,
    pixelWidth,
    pixelHeight,
    sourceX,
    sourceY,
    sourceWidth,
    sourceHeight,
    kittyPlacementId,
    kittyKind,
  ]);

  @override
  String toString() =>
      'RenderImagePlacement($protocol #$imageId, $layer z=$z, '
      'cell ($viewportCol, $viewportRow) ${gridCols}x$gridRows, '
      '${pixelWidth}x${pixelHeight}px)';
}
