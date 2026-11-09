/// Enums of the render state and of packed cells (`render.h`, `screen.h`,
/// `types.h`).
///
/// Pure Dart (no `dart:ffi`), so a future web backend can reuse them. The
/// codecs are public top-levels hidden from the module barrel; the grid
/// module (cell queries) and the kitty graphics module (image layers) may
/// import them from this file.
library;

import '../core/enum_codec.dart';

/// How much of a render state changed in the last update
/// (`GhosttyRenderStateDirty`).
///
/// Read it with `RenderState.dirty` right after an update to decide how
/// much to redraw.
enum RenderDirtyState {
  /// Nothing changed; the frame can be skipped
  /// (`GHOSTTY_RENDER_STATE_DIRTY_FALSE`).
  clean(0),

  /// Some rows changed; redraw only the dirty rows.
  partial(1),

  /// Global state changed (size, colours, screen switch, ...); redraw
  /// everything.
  full(2),

  /// A value added by a later libghostty-vt release. Treat it as [full].
  unknown(null);

  const RenderDirtyState(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyRenderStateDirty` values to [RenderDirtyState] and
/// back.
final renderDirtyStateCodec = RawEnumCodec<RenderDirtyState>(
  RenderDirtyState.values,
  raw: (state) => state._raw,
  unknown: RenderDirtyState.unknown,
);

/// The width behaviour of one cell (`GhosttyCellWide`).
///
/// A wide character (CJK, most emoji) takes two columns: a [wide] cell that
/// holds the text, followed by a [spacerTail] cell that must not be drawn.
enum CellWidth {
  /// An ordinary one-column cell.
  narrow(0),

  /// The first column of a two-column character; draw its text across two
  /// cells.
  wide(1),

  /// The second column of a wide character. Draw nothing for it (its
  /// background still belongs to the wide character).
  spacerTail(2),

  /// The last column of a soft-wrapped row whose wide character did not
  /// fit and moved to the next row. Draw nothing for it.
  spacerHead(3),

  /// A value added by a later libghostty-vt release. Draw it as [narrow].
  unknown(null);

  const CellWidth(this._raw);

  final int? _raw;

  /// Whether this cell is a spacer ([spacerTail] or [spacerHead]) that a
  /// renderer skips.
  bool get isSpacer => this == spacerTail || this == spacerHead;
}

/// Converts raw `GhosttyCellWide` values to [CellWidth] and back.
final cellWidthCodec = RawEnumCodec<CellWidth>(
  CellWidth.values,
  raw: (width) => width._raw,
  unknown: CellWidth.unknown,
);

/// What kind of shell content a cell holds, as reported by semantic prompt
/// sequences (OSC 133) (`GhosttyCellSemanticContent`).
enum CellSemanticContent {
  /// Regular output, such as command output. The default.
  output(0),

  /// Text the user typed.
  input(1),

  /// Part of a shell prompt.
  prompt(2),

  /// A value added by a later libghostty-vt release.
  unknown(null);

  const CellSemanticContent(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyCellSemanticContent` values to [CellSemanticContent]
/// and back.
final cellSemanticContentCodec = RawEnumCodec<CellSemanticContent>(
  CellSemanticContent.values,
  raw: (content) => content._raw,
  unknown: CellSemanticContent.unknown,
);

/// The image protocol an image placement came from (`GhosttyImageProtocol`).
///
/// It says where to read the image's pixels. Skip placements whose protocol
/// you do not support, including [unknown].
enum ImageProtocol {
  /// The Kitty graphics protocol.
  kitty(0),

  /// A protocol added by a later libghostty-vt release.
  unknown(null);

  const ImageProtocol(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyImageProtocol` values to [ImageProtocol] and back.
final imageProtocolCodec = RawEnumCodec<ImageProtocol>(
  ImageProtocol.values,
  raw: (protocol) => protocol._raw,
  unknown: ImageProtocol.unknown,
);

/// Where an image is drawn relative to the text (`GhosttyImageLayer`).
///
/// Draw each frame bottom-up: [belowBackground] images, cell backgrounds,
/// [belowText] images, text, [aboveText] images. Within a layer, draw
/// lower z-indices first.
enum ImageLayer {
  /// Below the cell background colours (Kitty z-index below
  /// −1,073,741,824).
  belowBackground(0),

  /// Above the cell backgrounds and below the text (Kitty z-index from
  /// −1,073,741,824 to −1).
  belowText(1),

  /// Above the text (Kitty z-index 0 and above).
  aboveText(2),

  /// A layer added by a later libghostty-vt release. Draw it as
  /// [aboveText].
  unknown(null);

  const ImageLayer(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyImageLayer` values to [ImageLayer] and back.
final imageLayerCodec = RawEnumCodec<ImageLayer>(
  ImageLayer.values,
  raw: (layer) => layer._raw,
  unknown: ImageLayer.unknown,
);

/// The kind of a Kitty graphics placement in the render state
/// (`GhosttyRenderStateKittyPlacementKind`).
///
/// Most renderers draw every kind the same way.
enum KittyPlacementKind {
  /// One run of neighbouring Unicode placeholder cells in a single row;
  /// always one row tall.
  virtual(0),

  /// A placement positioned relative to another placement (its parent).
  relative(1),

  /// A placement at a cell of the screen, scrolling with the text.
  fixed(2),

  /// A kind added by a later libghostty-vt release.
  unknown(null);

  const KittyPlacementKind(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyRenderStateKittyPlacementKind` values to
/// [KittyPlacementKind] and back.
final kittyPlacementKindCodec = RawEnumCodec<KittyPlacementKind>(
  KittyPlacementKind.values,
  raw: (kind) => kind._raw,
  unknown: KittyPlacementKind.unknown,
);
