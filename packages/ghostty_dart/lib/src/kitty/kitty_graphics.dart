/// The [VtTerminalKittyGraphics] extension: read the Kitty graphics image
/// storage of a terminal and play its animations (`kitty_graphics.h`).
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../render/render_enums.dart';
import '../terminal/terminal.dart' show VtTerminal;
import '../terminal/terminal_native.dart' show checkNotInCallback, readData;
import 'kitty_types.dart';

/// The Kitty graphics image storage of a [VtTerminal]: the images and
/// placements programs sent with the
/// [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
///
/// The storage holds pixels; it does not say where to draw. A renderer
/// draws `RenderState.imagePlacements` and reads each image's pixels from
/// here, caching textures by [KittyImage.generation]:
///
/// ```dart
/// for (final p in renderState.imagePlacements()) {
///   if (p.protocol != ImageProtocol.kitty) continue;
///   if (cache[p.imageId]?.generation != p.imageGeneration) {
///     final pixels = terminal.kittyImagePixels(p.imageId);
///     if (pixels != null) cache[p.imageId] = upload(pixels, p.imageGeneration);
///   }
///   draw(cache[p.imageId], p);
/// }
/// final next = terminal.tickKittyAnimations(clock.elapsedMilliseconds);
/// ```
///
/// Every member reads the storage of the **active** screen (primary and
/// alternate screens have separate storages) and returns Dart copies that
/// stay valid after the terminal changes. Storage limits and the allowed
/// transmission media are options of [VtTerminal]
/// (`kittyImageStorageLimit`, `isKittyImageFileMediumEnabled`, ...); PNG
/// images need a decoder (`setVtPngDecoder`).
///
/// Kitty graphics is an optional build feature: when the loaded library
/// lacks it (`libghosttyVtBuildInfo.supports(VtFeature.kittyGraphics)` is
/// `false`), every member throws [UnsupportedError]. Every member throws
/// [StateError] after [VtTerminal.dispose] or when called from inside a
/// callback of the terminal.
extension VtTerminalKittyGraphics on VtTerminal {
  /// A value that changes whenever a program sends, replaces, places or
  /// deletes an image, or when pending pixels arrive; 0 while nothing has
  /// changed the storage yet (it is then empty).
  ///
  /// Never reused, even across screens, resets and terminals, so it works
  /// as a cache key for the whole storage. It does not change when
  /// placements merely move (scrolling, resizing): use
  /// `RenderState.imagePlacementsGeneration` to know when to re-read the
  /// render state's image list.
  int get kittyGraphicsGeneration => _withStorage(
    'kittyGraphicsGeneration',
    (_, storage) => withScratch(sizeOf<Uint64>(), (out) {
      checkResult(
        ghostty_kitty_graphics_get(
          storage,
          GhosttyKittyGraphicsData.GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION,
          out.cast(),
        ),
        'ghostty_kitty_graphics_get',
      );
      return out.cast<Uint64>().value;
    }),
  );

  /// The image with id [imageId], or `null` if the storage has none.
  ///
  /// Throws [RangeError] unless [imageId] is 0–0xFFFFFFFF.
  KittyImage? kittyImage(int imageId) {
    _checkImageId(imageId);
    return _withStorage('kittyImage', (_, storage) {
      final image = ghostty_kitty_graphics_image(storage, imageId);
      return image == nullptr ? null : _readImage(image);
    });
  }

  /// A copy of the pixels of the image with id [imageId], in its
  /// [KittyImage.format], or `null` if there is no such image or its pixels
  /// have not arrived yet ([KittyImage.hasPixels]).
  ///
  /// The pixels are fully decoded and uncompressed, `width * height *
  /// bytesPerPixel` bytes, row by row from the top-left corner. For an
  /// animation they are the current frame. Copying can be expensive for
  /// large images: re-read only when [KittyImage.generation] (or the
  /// render state's `imageGeneration`) changes.
  ///
  /// Throws [RangeError] unless [imageId] is 0–0xFFFFFFFF.
  Uint8List? kittyImagePixels(int imageId) {
    _checkImageId(imageId);
    return _withStorage('kittyImagePixels', (_, storage) {
      final image = ghostty_kitty_graphics_image(storage, imageId);
      return image == nullptr ? null : _readPixels(image);
    });
  }

  /// Every placement in the storage, or only those whose z-index puts them
  /// in one of [layers] (see [ImageLayer] for the ranges).
  ///
  /// Each entry is a copy that includes its resolved geometry. This
  /// inspects the storage: to draw, use `RenderState.imagePlacements`,
  /// which also positions virtual placements. The order is the storage's
  /// and not meaningful.
  ///
  /// Throws [ArgumentError] if [layers] contains [ImageLayer.unknown].
  List<KittyPlacement> kittyPlacements({Set<ImageLayer>? layers}) {
    final mask = layers == null ? 0 : _layerMask(layers);
    return _withStorage(
      'kittyPlacements',
      // A mask of 0 means "no filter" to the library, so an empty set never
      // reaches it.
      (terminal, storage) => layers != null && mask == 0
          ? const []
          : _readPlacements(terminal, storage, mask),
    );
  }

  /// Advances every playing animation to the frame due at [nowMs] and
  /// returns the time the next frame is due, or `null` when nothing is
  /// playing.
  ///
  /// Time is in milliseconds on a clock you choose (for example a
  /// [Stopwatch] started with the app). It must only move forward, and the
  /// same clock must be used for the terminal's whole life; the returned
  /// time is on that clock. An animation moves at most one frame per call,
  /// so late calls slow playback down instead of skipping frames. Call it
  /// once per drawn frame, then schedule the next frame at the returned
  /// time.
  ///
  /// Images that changed frame get a new [KittyImage.generation] and new
  /// pixels. Like [VtTerminal.write], this changes the terminal: borrowed
  /// views (render rows, grid references) become invalid.
  ///
  /// A due time past the largest Dart int is returned as that int.
  ///
  /// Throws [RangeError] if [nowMs] is negative.
  int? tickKittyAnimations(int nowMs) {
    RangeError.checkNotNegative(nowMs, 'nowMs');
    final handle = handleOf<GhosttyTerminalImpl>(this);
    return _withStorage('tickKittyAnimations', (_, storage) {
      final next = withScratch(sizeOf<Uint64>(), (out) {
        final hasNext = checkResultHasValue(
          ghostty_kitty_graphics_animation_tick(storage, nowMs, out.cast()),
          'ghostty_kitty_graphics_animation_tick',
        );
        if (!hasNext) return null;
        // The library saturates `now + delay` at 2^64 - 1, which reads back
        // negative as a Dart int: saturate at the largest Dart int instead.
        final due = out.cast<Uint64>().value;
        return due < 0 ? _maxInt : due;
      });
      handle.bumpEpoch();
      return next;
    });
  }

  /// Runs [action] with the terminal pointer and the active screen's
  /// storage, after the dispose and reentrancy checks ([member] names the
  /// caller in errors). The storage pointer is borrowed: it is valid only
  /// until the terminal next changes, so it never leaves [action].
  R _withStorage<R>(
    String member,
    R Function(
      Pointer<GhosttyTerminalImpl> terminal,
      Pointer<GhosttyKittyGraphicsImpl> storage,
    )
    action,
  ) {
    final handle = handleOf<GhosttyTerminalImpl>(this);
    checkNotInCallback(handle, member);
    final terminal = handle.pointer;
    final storage = readData(
      terminal,
      GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
      sizeOf<Pointer<Void>>(),
      (out) => out.cast<Pointer<GhosttyKittyGraphicsImpl>>().value,
    );
    return action(terminal, storage);
  }
}

/// The largest Dart (signed 64-bit) int.
const _maxInt = 0x7FFFFFFFFFFFFFFF;

void _checkImageId(int imageId) =>
    RangeError.checkValueInInterval(imageId, 0, 0xFFFFFFFF, 'imageId');

/// The `GHOSTTY_IMAGE_LAYER_MASK_*` bits of [layers].
int _layerMask(Set<ImageLayer> layers) {
  var mask = 0;
  for (final layer in layers) {
    mask |= 1 << imageLayerCodec.encode(layer);
  }
  return mask;
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

/// The `ghostty_kitty_graphics_image_get_multi` batch behind [KittyImage],
/// in slot order.
const _imageKeys = [
  GhosttyKittyGraphicsImageData.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_ID,
  GhosttyKittyGraphicsImageData.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_NUMBER,
  GhosttyKittyGraphicsImageData.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH,
  GhosttyKittyGraphicsImageData.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT,
  GhosttyKittyGraphicsImageData.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT,
  GhosttyKittyGraphicsImageData.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_COMPRESSION,
  GhosttyKittyGraphicsImageData.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_EXPECTED_LEN,
  GhosttyKittyGraphicsImageData.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION,
];

KittyImage _readImage(Pointer<GhosttyKittyGraphicsImageImpl> image) =>
    _getMulti(
      _imageKeys,
      'ghostty_kitty_graphics_image_get_multi',
      (count, keys, values) => ghostty_kitty_graphics_image_get_multi(
        image,
        count,
        keys,
        values,
        nullptr,
      ),
      (slot) => KittyImage(
        id: slot(0).cast<Uint32>().value,
        number: slot(1).cast<Uint32>().value,
        width: slot(2).cast<Uint32>().value,
        height: slot(3).cast<Uint32>().value,
        format: kittyImageFormatCodec.decode(slot(4).cast<UnsignedInt>().value),
        compression: kittyImageCompressionCodec.decode(
          slot(5).cast<UnsignedInt>().value,
        ),
        pixelByteLength: slot(6).cast<Size>().value,
        generation: slot(7).cast<Uint64>().value,
        hasPixels: _pixels(image, (_) => true) ?? false,
      ),
    );

/// A copy of [image]'s pixels, or `null` while they have not arrived.
Uint8List? _readPixels(Pointer<GhosttyKittyGraphicsImageImpl> image) =>
    _pixels(image, (pixels) => copyBytes(pixels.ptr, pixels.len));

/// Calls [read] with [image]'s borrowed pixel string, or returns `null` for
/// `GHOSTTY_NO_VALUE` (pixels not arrived).
R? _pixels<R extends Object>(
  Pointer<GhosttyKittyGraphicsImageImpl> image,
  R Function(GhosttyString pixels) read,
) => withScratch(sizeOf<GhosttyString>(), (out) {
  final hasValue = checkResultHasValue(
    ghostty_kitty_graphics_image_get(
      image,
      GhosttyKittyGraphicsImageData.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS,
      out.cast(),
    ),
    'ghostty_kitty_graphics_image_get',
  );
  return hasValue ? read(out.cast<GhosttyString>().ref) : null;
});

// ---------------------------------------------------------------------------
// Placements
// ---------------------------------------------------------------------------

/// The `ghostty_kitty_graphics_placement_get_multi` batch behind
/// [KittyPlacement], in slot order.
const _placementKeys = [
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET,
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET,
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_X,
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_Y,
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_WIDTH,
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_HEIGHT,
  GhosttyKittyGraphicsPlacementData
      .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS,
  GhosttyKittyGraphicsPlacementData.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS,
  GhosttyKittyGraphicsPlacementData.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z,
];

/// Walks the placements of [storage] with a fresh iterator, filtered by the
/// layer [mask] (0 = all). The iterator is freed before returning.
List<KittyPlacement> _readPlacements(
  Pointer<GhosttyTerminalImpl> terminal,
  Pointer<GhosttyKittyGraphicsImpl> storage,
  int mask,
) {
  final iterator = createNative<GhosttyKittyGraphicsPlacementIteratorImpl>(
    'ghostty_kitty_graphics_placement_iterator_new',
    (out) => ghostty_kitty_graphics_placement_iterator_new(nullptr, out),
  );
  try {
    return withScratch(sizeOf<Pointer<Void>>() + sizeOf<Uint32>(), (block) {
      final slot =
          block.cast<Pointer<GhosttyKittyGraphicsPlacementIteratorImpl>>()
            ..value = iterator;
      if (mask != 0) {
        final value = (block + sizeOf<Pointer<Void>>()).cast<Uint32>()
          ..value = mask;
        checkResult(
          ghostty_kitty_graphics_placement_iterator_set(
            iterator,
            GhosttyKittyGraphicsPlacementIteratorOption
                .GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_LAYER,
            value.cast(),
          ),
          'ghostty_kitty_graphics_placement_iterator_set',
        );
      }
      checkResult(
        ghostty_kitty_graphics_get(
          storage,
          GhosttyKittyGraphicsData
              .GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
          slot.cast(),
        ),
        'ghostty_kitty_graphics_get',
      );
      final placements = <KittyPlacement>[];
      while (ghostty_kitty_graphics_placement_next(iterator)) {
        placements.add(_readPlacement(terminal, storage, iterator));
      }
      return List.unmodifiable(placements);
    });
  } finally {
    ghostty_kitty_graphics_placement_iterator_free(iterator);
  }
}

/// Reads the placement [iterator] is on, with its geometry.
KittyPlacement _readPlacement(
  Pointer<GhosttyTerminalImpl> terminal,
  Pointer<GhosttyKittyGraphicsImpl> storage,
  Pointer<GhosttyKittyGraphicsPlacementIteratorImpl> iterator,
) => _getMulti(
  _placementKeys,
  'ghostty_kitty_graphics_placement_get_multi',
  (count, keys, values) => ghostty_kitty_graphics_placement_get_multi(
    iterator,
    count,
    keys,
    values,
    nullptr,
  ),
  (slot) {
    final imageId = slot(0).cast<Uint32>().value;
    final image = ghostty_kitty_graphics_image(storage, imageId);
    return KittyPlacement(
      imageId: imageId,
      placementId: slot(1).cast<Uint32>().value,
      isVirtual: slot(2).cast<Bool>().value,
      cellOffsetX: slot(3).cast<Uint32>().value,
      cellOffsetY: slot(4).cast<Uint32>().value,
      sourceX: slot(5).cast<Uint32>().value,
      sourceY: slot(6).cast<Uint32>().value,
      sourceWidth: slot(7).cast<Uint32>().value,
      sourceHeight: slot(8).cast<Uint32>().value,
      columns: slot(9).cast<Uint32>().value,
      rows: slot(10).cast<Uint32>().value,
      z: slot(11).cast<Int32>().value,
      geometry: image == nullptr
          ? null
          : _readGeometry(terminal, iterator, image),
    );
  },
);

/// The resolved geometry of the placement [iterator] is on: one
/// `render_info` call plus the screen rectangle.
KittyPlacementGeometry _readGeometry(
  Pointer<GhosttyTerminalImpl> terminal,
  Pointer<GhosttyKittyGraphicsPlacementIteratorImpl> iterator,
  Pointer<GhosttyKittyGraphicsImageImpl> image,
) => withScratch(sizeOf<GhosttyKittyGraphicsPlacementRenderInfo>(), (out) {
  final info = out.cast<GhosttyKittyGraphicsPlacementRenderInfo>()
    ..initSized(sizeOf<GhosttyKittyGraphicsPlacementRenderInfo>());
  checkResult(
    ghostty_kitty_graphics_placement_render_info(
      iterator,
      image,
      terminal,
      info,
    ),
    'ghostty_kitty_graphics_placement_render_info',
  );
  final ref = info.ref;
  final visible = ref.viewport_visible;
  final rect = _readScreenRect(terminal, iterator, image);
  return KittyPlacementGeometry(
    pixelWidth: ref.pixel_width,
    pixelHeight: ref.pixel_height,
    gridCols: ref.grid_cols,
    gridRows: ref.grid_rows,
    viewportCol: visible ? ref.viewport_col : null,
    viewportRow: visible ? ref.viewport_row : null,
    sourceX: ref.source_x,
    sourceY: ref.source_y,
    sourceWidth: ref.source_width,
    sourceHeight: ref.source_height,
    screenTopLeft: rect?.$1,
    screenBottomRight: rect?.$2,
  );
});

/// The cells at the corners of the placement, in screen coordinates, or
/// `null` when the storage cannot position it (virtual placements).
(GridPoint, GridPoint)? _readScreenRect(
  Pointer<GhosttyTerminalImpl> terminal,
  Pointer<GhosttyKittyGraphicsPlacementIteratorImpl> iterator,
  Pointer<GhosttyKittyGraphicsImageImpl> image,
) => withScratch(
  sizeOf<GhosttySelection>() + sizeOf<GhosttyPointCoordinate>(),
  (block) {
    final selection = block.cast<GhosttySelection>();
    final hasRect = checkResultHasValue(
      ghostty_kitty_graphics_placement_rect(
        iterator,
        image,
        terminal,
        selection,
      ),
      'ghostty_kitty_graphics_placement_rect',
    );
    if (!hasRect) return null;
    final coordinate = (block + sizeOf<GhosttySelection>())
        .cast<GhosttyPointCoordinate>();
    // The conversion belongs to the grid-introspection/selection build
    // features, which a build with Kitty graphics may lack: the corners are
    // then unknown (null) instead of failing the whole placement list.
    GridPoint? screenPoint(Pointer<GhosttyGridRef> ref) {
      final code = checkResultAllowing(
        ghostty_terminal_point_from_grid_ref(
          terminal,
          ref,
          GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN,
          coordinate,
        ),
        'ghostty_terminal_point_from_grid_ref',
        const {GhosttyResultCode.noValue, GhosttyResultCode.unsupported},
      );
      if (code != GhosttyResultCode.success) return null;
      return GridPoint.screen(coordinate.ref.x, coordinate.ref.y);
    }

    final start = screenPoint(selection.cast<GhosttyGridRef>());
    final end = screenPoint(
      Pointer<GhosttyGridRef>.fromAddress(
        selection.address + _selectionEndOffset,
      ),
    );
    return start == null || end == null ? null : (start, end);
  },
);

/// The byte offset of `GhosttySelection.end` (it follows `start`).
final int _selectionEndOffset = sizeOf<GhosttyGridRef>();

// ---------------------------------------------------------------------------
// get_multi plumbing
// ---------------------------------------------------------------------------

/// Every output of the image and placement batches fits in 8 bytes.
const _slotSize = 8;

/// Reads [keys] with one `*_get_multi` [call] and decodes the outputs with
/// [decode], which receives a function returning the output slot of each
/// key index. All memory comes from one scratch block.
R _getMulti<R>(
  List<int> keys,
  String operation,
  int Function(
    int count,
    Pointer<UnsignedInt> keys,
    Pointer<Pointer<Void>> values,
  )
  call,
  R Function(Pointer<Uint8> Function(int index) slot) decode,
) {
  final count = keys.length;
  final valuesBytes = count * sizeOf<Pointer<Void>>();
  final keysBytes = (count * sizeOf<UnsignedInt>() + 7) & ~7;
  return withScratch(valuesBytes + keysBytes + count * _slotSize, (block) {
    final values = block.cast<Pointer<Void>>();
    final keyArray = (block + valuesBytes).cast<UnsignedInt>();
    final slots = block + valuesBytes + keysBytes;
    for (var i = 0; i < count; i++) {
      keyArray[i] = keys[i];
      values[i] = (slots + i * _slotSize).cast();
    }
    checkResult(call(count, keyArray, values), operation);
    return decode((index) => slots + index * _slotSize);
  });
}
