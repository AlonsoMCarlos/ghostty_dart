/// Pure Dart value types of the Kitty graphics image storage
/// (`kitty_graphics.h`).
library;

import '../core/enum_codec.dart';
import '../core/point.dart';

/// The pixel format of a stored Kitty graphics image
/// (`GhosttyKittyImageFormat`).
///
/// Stored images are always decoded: [png] is never reported for a stored
/// image, because PNG payloads become [rgba] when they arrive.
enum KittyImageFormat {
  /// Three bytes per pixel: red, green, blue.
  rgb(0),

  /// Four bytes per pixel: red, green, blue, alpha.
  rgba(1),

  /// A PNG file. Only exists at the protocol level; never stored.
  png(2),

  /// Two bytes per pixel: gray, alpha.
  grayAlpha(3),

  /// One byte per pixel: gray.
  gray(4),

  /// A format added by a later libghostty-vt release.
  unknown(null);

  const KittyImageFormat(this._raw);

  final int? _raw;

  /// The bytes of one pixel, or `null` for [png] and [unknown], which have
  /// no fixed pixel size.
  int? get bytesPerPixel => switch (this) {
    rgb => 3,
    rgba => 4,
    grayAlpha => 2,
    gray => 1,
    png || unknown => null,
  };
}

/// Converts raw `GhosttyKittyImageFormat` values to [KittyImageFormat] and
/// back.
final kittyImageFormatCodec = RawEnumCodec<KittyImageFormat>(
  KittyImageFormat.values,
  raw: (format) => format._raw,
  unknown: KittyImageFormat.unknown,
);

/// The compression of a stored Kitty graphics image
/// (`GhosttyKittyImageCompression`).
///
/// Stored images are always inflated, so a stored image reports [none];
/// renderers never need to decompress anything.
enum KittyImageCompression {
  /// Uncompressed pixels.
  none(0),

  /// zlib/deflate. Only exists at the protocol level; never stored.
  zlibDeflate(1),

  /// A compression added by a later libghostty-vt release.
  unknown(null);

  const KittyImageCompression(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyKittyImageCompression` values to
/// [KittyImageCompression] and back.
final kittyImageCompressionCodec = RawEnumCodec<KittyImageCompression>(
  KittyImageCompression.values,
  raw: (compression) => compression._raw,
  unknown: KittyImageCompression.unknown,
);

/// What the image storage knows about one Kitty graphics image, copied out
/// of the terminal (`GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_*`).
///
/// A plain value: it stays valid after the terminal changes, but it does
/// not follow the image. Read the pixels with
/// `VtTerminal.kittyImagePixels`, and re-read them only when [generation]
/// changes.
final class KittyImage {
  /// Creates an image description. Programs get them from
  /// `VtTerminal.kittyImage`.
  const KittyImage({
    required this.id,
    required this.number,
    required this.width,
    required this.height,
    required this.format,
    required this.compression,
    required this.pixelByteLength,
    required this.generation,
    required this.hasPixels,
  });

  /// The image id (`i=`), unique within one screen's storage.
  final int id;

  /// The image number (`I=`) the program sent it with, or 0 if it used an
  /// id.
  final int number;

  /// The width in pixels.
  final int width;

  /// The height in pixels.
  final int height;

  /// The pixel format of the stored pixels; never [KittyImageFormat.png].
  final KittyImageFormat format;

  /// The compression of the stored pixels; always
  /// [KittyImageCompression.none] for a stored image.
  final KittyImageCompression compression;

  /// The size of the pixel data in bytes: `width * height *
  /// format.bytesPerPixel`. Known even while [hasPixels] is `false`, and
  /// already counted against the storage limit.
  final int pixelByteLength;

  /// Changes whenever the image's pixels may have changed: a new
  /// transmission under the same id, or an animation moving to another
  /// frame. Never 0 and never reused, so it is a safe texture cache key
  /// (together with the terminal). Compare it for equality only.
  ///
  /// It does *not* change when pixels that were still on the way arrive
  /// (for example while a snapshot is restored); watch [hasPixels] or
  /// `VtTerminal.kittyGraphicsGeneration` for that.
  final int generation;

  /// Whether the pixels have arrived. `false` while a restored snapshot is
  /// still delivering them; `VtTerminal.kittyImagePixels` then returns
  /// `null`.
  final bool hasPixels;

  @override
  bool operator ==(Object other) =>
      other is KittyImage &&
      other.id == id &&
      other.number == number &&
      other.width == width &&
      other.height == height &&
      other.format == format &&
      other.compression == compression &&
      other.pixelByteLength == pixelByteLength &&
      other.generation == generation &&
      other.hasPixels == hasPixels;

  @override
  int get hashCode => Object.hash(
    id,
    number,
    width,
    height,
    format,
    compression,
    pixelByteLength,
    generation,
    hasPixels,
  );

  @override
  String toString() =>
      'KittyImage(#$id ${width}x$height ${format.name}, '
      'generation $generation${hasPixels ? '' : ', pixels pending'})';
}

/// One placement in the Kitty graphics image storage, copied out of the
/// terminal (`GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_*`).
///
/// This describes what the program asked for. For drawing, use the
/// `RenderImagePlacement`s of `RenderState.imagePlacements` instead: they
/// position every visible image, including virtual placements, and drawing
/// from both lists draws images twice. Both share the image id, z-index and
/// resolved pixel and source geometry; this storage view adds the request
/// (`p=`, `c=`/`r=`, the screen rectangle) and suits inspection, debugging
/// and tooling.
final class KittyPlacement {
  /// Creates a placement description. Programs get them from
  /// `VtTerminal.kittyPlacements`.
  const KittyPlacement({
    required this.imageId,
    required this.placementId,
    required this.isVirtual,
    required this.cellOffsetX,
    required this.cellOffsetY,
    required this.sourceX,
    required this.sourceY,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.columns,
    required this.rows,
    required this.z,
    required this.geometry,
  });

  /// The id of the image this placement shows.
  final int imageId;

  /// The placement id (`p=`), or 0 if the program gave none.
  final int placementId;

  /// Whether this is a virtual placement, shown through Unicode placeholder
  /// cells; the storage has no position for it.
  final bool isVirtual;

  /// Pixels from the left edge of the top-left cell to the image (`X=`).
  final int cellOffsetX;

  /// Pixels from the top edge of the top-left cell to the image (`Y=`).
  final int cellOffsetY;

  /// The requested left edge of the source rectangle, in image pixels
  /// (`x=`).
  final int sourceX;

  /// The requested top edge of the source rectangle, in image pixels
  /// (`y=`).
  final int sourceY;

  /// The requested source width in image pixels (`w=`); 0 means the full
  /// image width. [KittyPlacementGeometry.sourceWidth] has the resolved
  /// value.
  final int sourceWidth;

  /// The requested source height in image pixels (`h=`); 0 means the full
  /// image height.
  final int sourceHeight;

  /// The requested number of columns (`c=`); 0 means computed from the
  /// image size. [KittyPlacementGeometry.gridCols] has the resolved value.
  final int columns;

  /// The requested number of rows (`r=`); 0 means computed from the image
  /// size.
  final int rows;

  /// The z-index (`z=`): negative values draw below the text.
  final int z;

  /// Where and how large the placement is drawn, resolved against the
  /// image and the terminal's cell size, or `null` when its image is not in
  /// the storage.
  final KittyPlacementGeometry? geometry;

  @override
  bool operator ==(Object other) =>
      other is KittyPlacement &&
      other.imageId == imageId &&
      other.placementId == placementId &&
      other.isVirtual == isVirtual &&
      other.cellOffsetX == cellOffsetX &&
      other.cellOffsetY == cellOffsetY &&
      other.sourceX == sourceX &&
      other.sourceY == sourceY &&
      other.sourceWidth == sourceWidth &&
      other.sourceHeight == sourceHeight &&
      other.columns == columns &&
      other.rows == rows &&
      other.z == z &&
      other.geometry == geometry;

  @override
  int get hashCode => Object.hash(
    imageId,
    placementId,
    isVirtual,
    cellOffsetX,
    cellOffsetY,
    sourceX,
    sourceY,
    sourceWidth,
    sourceHeight,
    columns,
    rows,
    z,
    geometry,
  );

  @override
  String toString() =>
      'KittyPlacement(image #$imageId, placement #$placementId'
      '${isVirtual ? ', virtual' : ''}, z=$z)';
}

/// The resolved geometry of a [KittyPlacement]
/// (`GhosttyKittyGraphicsPlacementRenderInfo` and
/// `ghostty_kitty_graphics_placement_rect`).
final class KittyPlacementGeometry {
  /// Creates a geometry description.
  const KittyPlacementGeometry({
    required this.pixelWidth,
    required this.pixelHeight,
    required this.gridCols,
    required this.gridRows,
    required this.viewportCol,
    required this.viewportRow,
    required this.sourceX,
    required this.sourceY,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.screenTopLeft,
    required this.screenBottomRight,
  });

  /// The width to draw the image at, in pixels.
  final int pixelWidth;

  /// The height to draw the image at, in pixels.
  final int pixelHeight;

  /// The number of cell columns the placement covers.
  final int gridCols;

  /// The number of cell rows the placement covers.
  final int gridRows;

  /// The viewport column of the top-left cell (0 is the leftmost column),
  /// or `null` when no part of the placement is in the viewport or the
  /// storage cannot place it (a virtual placement, or one relative to it).
  final int? viewportCol;

  /// The viewport row of the top-left cell (0 is the top row; negative when
  /// the top scrolled above the viewport), or `null` exactly when
  /// [viewportCol] is.
  final int? viewportRow;

  /// The left edge of the part of the image to draw, in image pixels,
  /// clamped to the image.
  final int sourceX;

  /// The top edge of the part of the image to draw, in image pixels.
  final int sourceY;

  /// The width of the part of the image to draw, in image pixels.
  final int sourceWidth;

  /// The height of the part of the image to draw, in image pixels.
  final int sourceHeight;

  /// The top-left cell the placement covers, in [PointSpace.screen]
  /// coordinates, or `null` when the storage has no rectangle for it:
  /// virtual and relative (`P=`) placements, placements whose rows were
  /// pruned from the scrollback, placements that cover no cells, and
  /// library builds without grid introspection.
  final GridPoint? screenTopLeft;

  /// The bottom-right cell the placement covers (inclusive), in
  /// [PointSpace.screen] coordinates, or `null` exactly when
  /// [screenTopLeft] is.
  final GridPoint? screenBottomRight;

  /// Whether any part of the placement is in the viewport.
  bool get isInViewport => viewportCol != null;

  @override
  bool operator ==(Object other) =>
      other is KittyPlacementGeometry &&
      other.pixelWidth == pixelWidth &&
      other.pixelHeight == pixelHeight &&
      other.gridCols == gridCols &&
      other.gridRows == gridRows &&
      other.viewportCol == viewportCol &&
      other.viewportRow == viewportRow &&
      other.sourceX == sourceX &&
      other.sourceY == sourceY &&
      other.sourceWidth == sourceWidth &&
      other.sourceHeight == sourceHeight &&
      other.screenTopLeft == screenTopLeft &&
      other.screenBottomRight == screenBottomRight;

  @override
  int get hashCode => Object.hash(
    pixelWidth,
    pixelHeight,
    gridCols,
    gridRows,
    viewportCol,
    viewportRow,
    sourceX,
    sourceY,
    sourceWidth,
    sourceHeight,
    screenTopLeft,
    screenBottomRight,
  );

  @override
  String toString() =>
      'KittyPlacementGeometry(${gridCols}x$gridRows cells, '
      '${pixelWidth}x${pixelHeight}px'
      '${isInViewport ? ' at ($viewportCol, $viewportRow)' : ''})';
}
