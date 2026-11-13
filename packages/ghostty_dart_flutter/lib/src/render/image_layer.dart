import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../seams/terminal_geometry.dart';
import '../seams/terminal_seams.dart';

/// The texture of one placed image: the generation it shows and the one
/// being uploaded, if any.
final class _Texture {
  /// The texture drawn for the image; `null` until the first upload is
  /// ready. An older generation stays here until its replacement is ready,
  /// so a replaced image or an animation never flashes empty.
  ui.Image? image;

  /// The image generation [image] was made from (or the last generation
  /// that failed to upload, so it is not tried again).
  int? generation;

  /// The image generation being uploaded, if any.
  int? pending;
}

/// The Kitty graphics images of the render box (ADR 0014): the placements
/// of the render state, sorted into the two passes the box draws, and one
/// texture per placed image. Never exported.
///
/// **Placements** are re-read only when
/// [RenderState.imagePlacementsGeneration] changes ([update]), skipping
/// [ImageProtocol.unknown], and sorted by layer, then z, then iterator
/// order. [paintBelow] draws [ImageLayer.belowBackground] and
/// [ImageLayer.belowText] (the box calls it after the default background,
/// before the row pictures); [paintAbove] draws [ImageLayer.aboveText] and
/// [ImageLayer.unknown] (after the rows, before the cursor). Row pictures
/// paint cell backgrounds and text together, so a `belowText` image sits
/// under non-default cell backgrounds (ADR 0014, a known difference).
///
/// **Textures** are keyed by image id and image generation, made from the
/// source's [TerminalFrameSource.imagePixels] (expanded to premultiplied
/// RGBA) with an asynchronous upload; [onTextureReady] runs when one is
/// ready, so the box repaints. A texture whose image is no longer placed
/// is disposed at the next re-read, a stale generation when its
/// replacement is ready, and everything on [clear]. An upload that
/// completes after [clear] (or after its image was replaced or removed)
/// disposes its image and reports nothing. Textures are not counted in the
/// box's cache budget: the terminal's storage limit bounds them.
final class KittyImageLayer {
  /// An empty layer; [onTextureReady] runs whenever a texture becomes
  /// ready to draw.
  KittyImageLayer({required this.onTextureReady});

  /// Called when an upload finished and the layer draws something new.
  final VoidCallback onTextureReady;

  int? _placementsGeneration;
  List<RenderImagePlacement> _below = const [];
  List<RenderImagePlacement> _above = const [];

  /// The image generation each placed image should show.
  Map<int, int> _wanted = const {};
  final _textures = <int, _Texture>{};

  /// Whether a placed image had no pixels yet (a restored snapshot still
  /// delivering them); [update] tries again on every frame until it has.
  bool _missing = false;

  /// How many textures exist (shown or being uploaded).
  @visibleForTesting
  int get debugTextureCount => _textures.length;

  /// How many uploads are in flight.
  @visibleForTesting
  int get debugPendingUploads =>
      _textures.values.where((t) => t.pending != null).length;

  /// The texture shown for [imageId], if any.
  @visibleForTesting
  ui.Image? debugTexture(int imageId) => _textures[imageId]?.image;

  /// The placements drawn, in draw order: [paintBelow]'s, then
  /// [paintAbove]'s.
  @visibleForTesting
  List<RenderImagePlacement> get debugPlacements => [..._below, ..._above];

  /// Whether anything is placed.
  bool get isEmpty => _below.isEmpty && _above.isEmpty;

  /// Reads the placements of [state] if they changed since the last call,
  /// and starts the uploads they need from [source]. Call it from `paint`,
  /// after [TerminalFrameSource.updateFrame] and before
  /// [TerminalFrameSource.endFrame].
  void update(RenderState state, TerminalFrameSource source) {
    final generation = state.imagePlacementsGeneration;
    if (generation != _placementsGeneration) {
      _placementsGeneration = generation;
      _readPlacements(state.imagePlacements());
    } else if (!_missing) {
      return;
    }
    _loadTextures(source);
  }

  void _readPlacements(List<RenderImagePlacement> all) {
    final indexed = <(int, RenderImagePlacement)>[
      for (var i = 0; i < all.length; i++)
        if (all[i].protocol != ImageProtocol.unknown) (i, all[i]),
    ];
    indexed.sort((a, b) {
      final layer = _layerOrder(a.$2.layer) - _layerOrder(b.$2.layer);
      if (layer != 0) return layer;
      final z = a.$2.z.compareTo(b.$2.z);
      return z != 0 ? z : a.$1 - b.$1;
    });
    final below = <RenderImagePlacement>[];
    final above = <RenderImagePlacement>[];
    final wanted = <int, int>{};
    for (final (_, placement) in indexed) {
      (_layerOrder(placement.layer) < _aboveText ? below : above).add(
        placement,
      );
      wanted[placement.imageId] = placement.imageGeneration;
    }
    _below = below;
    _above = above;
    _wanted = wanted;
    _textures.removeWhere((id, texture) {
      if (wanted.containsKey(id)) return false;
      texture.image?.dispose();
      return true;
    });
  }

  static const _aboveText = 2;

  static int _layerOrder(ImageLayer layer) => switch (layer) {
    ImageLayer.belowBackground => 0,
    ImageLayer.belowText => 1,
    ImageLayer.aboveText || ImageLayer.unknown => _aboveText,
  };

  void _loadTextures(TerminalFrameSource source) {
    _missing = false;
    for (final MapEntry(key: id, value: generation) in _wanted.entries) {
      final texture = _textures[id];
      if (texture != null &&
          (texture.generation == generation || texture.pending == generation)) {
        continue;
      }
      final pixels = source.imagePixels(id);
      if (pixels == null) {
        _missing = true;
        continue;
      }
      final target = texture ?? (_textures[id] = _Texture());
      final rgba = premultipliedRgba(pixels);
      if (rgba == null) {
        // A format this version cannot draw: never try this generation
        // again.
        target.generation = generation;
        continue;
      }
      target.pending = generation;
      _upload(rgba, pixels.width, pixels.height).then((image) {
        _uploaded(id, target, generation, image);
      });
    }
  }

  void _uploaded(int id, _Texture texture, int generation, ui.Image? image) {
    if (!identical(_textures[id], texture) || texture.pending != generation) {
      // Cleared, removed or replaced by a newer generation meanwhile.
      image?.dispose();
      return;
    }
    texture
      ..pending = null
      ..generation = generation;
    if (image == null) return;
    texture.image?.dispose();
    texture.image = image;
    onTextureReady();
  }

  /// Uploads [rgba] (premultiplied, [width] × [height]) as an image, or
  /// returns `null` if the engine rejects it.
  static Future<ui.Image?> _upload(
    Uint8List rgba,
    int width,
    int height,
  ) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// [pixels] as premultiplied RGBA (what [ui.PixelFormat.rgba8888]
  /// expects), or `null` for a format without a fixed pixel size or data
  /// shorter than its size says. RGB, grey and grey+alpha are expanded;
  /// Kitty sends straight (unpremultiplied) alpha, as PNG does.
  @visibleForTesting
  static Uint8List? premultipliedRgba(ImagePixels pixels) {
    final count = pixels.width * pixels.height;
    final bpp = pixels.format.bytesPerPixel;
    final src = pixels.pixels;
    if (bpp == null || count <= 0 || src.length < count * bpp) return null;
    final out = Uint8List(count * 4);
    switch (pixels.format) {
      case KittyImageFormat.rgba:
        for (var i = 0, o = 0; i < count; i++, o += 4) {
          final a = src[o + 3];
          if (a == 255) {
            out
              ..[o] = src[o]
              ..[o + 1] = src[o + 1]
              ..[o + 2] = src[o + 2];
          } else if (a != 0) {
            out
              ..[o] = _mul(src[o], a)
              ..[o + 1] = _mul(src[o + 1], a)
              ..[o + 2] = _mul(src[o + 2], a);
          }
          out[o + 3] = a;
        }
      case KittyImageFormat.rgb:
        for (var i = 0, s = 0, o = 0; i < count; i++, s += 3, o += 4) {
          out
            ..[o] = src[s]
            ..[o + 1] = src[s + 1]
            ..[o + 2] = src[s + 2]
            ..[o + 3] = 255;
        }
      case KittyImageFormat.grayAlpha:
        for (var i = 0, s = 0, o = 0; i < count; i++, s += 2, o += 4) {
          final a = src[s + 1];
          final g = a == 255 ? src[s] : _mul(src[s], a);
          out
            ..[o] = g
            ..[o + 1] = g
            ..[o + 2] = g
            ..[o + 3] = a;
        }
      case KittyImageFormat.gray:
        for (var i = 0, o = 0; i < count; i++, o += 4) {
          final g = src[i];
          out
            ..[o] = g
            ..[o + 1] = g
            ..[o + 2] = g
            ..[o + 3] = 255;
        }
      case KittyImageFormat.png || KittyImageFormat.unknown:
        return null;
    }
    return out;
  }

  static int _mul(int c, int a) => (c * a + 127) ~/ 255;

  /// Draws the [ImageLayer.belowBackground] and [ImageLayer.belowText]
  /// placements into the grid of [geometry], whose top-left is [grid].
  void paintBelow(Canvas canvas, Offset grid, TerminalGeometry geometry) =>
      _paint(_below, canvas, grid, geometry);

  /// Draws the [ImageLayer.aboveText] and [ImageLayer.unknown] placements.
  void paintAbove(Canvas canvas, Offset grid, TerminalGeometry geometry) =>
      _paint(_above, canvas, grid, geometry);

  static final _paintImage = Paint()..filterQuality = FilterQuality.low;

  void _paint(
    List<RenderImagePlacement> placements,
    Canvas canvas,
    Offset grid,
    TerminalGeometry geometry,
  ) {
    if (placements.isEmpty) return;
    final metrics = geometry.metrics;
    final dpr = metrics.devicePixelRatio;
    final cellWidthPx = metrics.widthPx;
    final cellHeightPx = metrics.heightPx;
    var clipped = false;
    for (final p in placements) {
      final image = _textures[p.imageId]?.image;
      if (image == null || p.pixelWidth <= 0 || p.pixelHeight <= 0) continue;
      // An older generation may have another size until its replacement
      // is ready: never sample outside it.
      final source = Rect.fromLTWH(
        p.sourceX.toDouble(),
        p.sourceY.toDouble(),
        p.sourceWidth.toDouble(),
        p.sourceHeight.toDouble(),
      ).intersect(Rect.fromLTWH(0, 0, image.width * 1.0, image.height * 1.0));
      if (source.isEmpty) continue;
      if (!clipped) {
        clipped = true;
        canvas
          ..save()
          ..clipRect(grid & geometry.gridRect.size);
      }
      canvas.drawImageRect(
        image,
        source,
        Rect.fromLTWH(
          grid.dx + (p.viewportCol * cellWidthPx + p.cellOffsetX) / dpr,
          grid.dy + (p.viewportRow * cellHeightPx + p.cellOffsetY) / dpr,
          p.pixelWidth / dpr,
          p.pixelHeight / dpr,
        ),
        _paintImage,
      );
    }
    if (clipped) canvas.restore();
  }

  /// Disposes every texture and forgets the placements: the next [update]
  /// reads them again and uploads what they need. Uploads in flight
  /// dispose their images when they complete.
  void clear() {
    for (final texture in _textures.values) {
      texture.image?.dispose();
    }
    _textures.clear();
    _placementsGeneration = null;
    _below = const [];
    _above = const [];
    _wanted = const {};
    _missing = false;
  }
}
