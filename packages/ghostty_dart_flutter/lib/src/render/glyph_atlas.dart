import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../metrics/cell_metrics.dart';

/// The bytes of every atlas image a view holds, live or pinned by cached
/// row pictures (ADR 0012). Shared by the successive [GlyphAtlas]es of
/// one view, so the images of a dropped atlas stay counted until the last
/// picture that uses them is disposed. Never exported.
final class AtlasLedger {
  int _bytes = 0;
  int _images = 0;

  /// The bytes of the atlas images not freed yet (4 per pixel).
  int get bytes => _bytes;

  /// How many atlas images are not freed yet.
  int get images => _images;
}

/// One rasterised image of an atlas page, shared by the atlas and the row
/// pictures recorded with it. Never exported.
///
/// A recorded picture keeps the engine image alive on its own; this
/// object only does the accounting. Every cached row picture [retain]s
/// the images it draws and [release]s them when it is disposed. When a
/// page is rasterised again (new glyphs), its previous image is
/// [retire]d: it stays counted in the [AtlasLedger] while pictures still
/// use it, and is freed with the last one.
final class AtlasImage {
  AtlasImage._(this.image, this.bytes, this._ledger) {
    _ledger
      .._bytes += bytes
      .._images += 1;
  }

  /// The page image.
  final ui.Image image;

  /// Its size in bytes (4 per pixel).
  final int bytes;

  final AtlasLedger _ledger;
  int _users = 0;
  bool _retired = false;
  bool _freed = false;

  /// Whether the image was freed (retired and unused).
  bool get isFreed => _freed;

  /// Whether a newer image replaced this one, or its atlas was dropped.
  bool get isRetired => _retired;

  /// How many cached pictures use this image.
  int get users => _users;

  /// Counts one more cached picture that draws this image.
  void retain() {
    assert(!_freed, 'retained a freed atlas image');
    _users++;
  }

  /// Counts one cached picture less; frees a retired image with its last
  /// user.
  void release() {
    assert(_users > 0, 'released an atlas image more often than retained');
    _users--;
    _freeIfUnused();
  }

  /// Marks this image as replaced: no new picture will draw it.
  void retire() {
    _retired = true;
    _freeIfUnused();
  }

  void _freeIfUnused() {
    if (!_retired || _users > 0 || _freed) return;
    _freed = true;
    image.dispose();
    _ledger
      .._bytes -= bytes
      .._images -= 1;
  }
}

/// A device-pixel glyph atlas for grid text, drawn with one
/// `Canvas.drawRawAtlas` per row and page (ADR 0012). Never exported.
///
/// **Slots.** One slot per (UTF-16 code unit, bold/italic faces,
/// luminance bucket) of a grid-safe narrow glyph. A slot is one cell plus
/// a margin of half a cell left and right, 3/10 of a cell above and 1/8
/// below (see [padX]), in whole device pixels, so glyphs that overhang their cell
/// (italic, wide bold, tall accents) are drawn whole, as a paragraph draws
/// them. A glyph is rasterised from a one-character paragraph in the grid
/// style, at the same sub-pixel offset inside its slot that a row
/// paragraph gives it inside its cell; drawn back at scale
/// `1 / devicePixelRatio`, every texel lands on one device pixel.
///
/// **Colour.** Text rasterisers adjust a glyph's coverage to the text
/// colour's luminance (Impeller on Linux and Windows, Skia's mask gamma),
/// so a glyph is rasterised in a grey of the cell colour's luminance,
/// quantised to [lumaBuckets] levels, and drawn with [blendMode]
/// (`dstIn`): only its alpha is used, filled with the cell colour. The key
/// space is bounded (at most 16 × glyphs × 4 faces) whatever colours a
/// program uses.
///
/// **Pages.** Slots live in pages of at most [pageWidth] × [pageHeight]
/// device pixels, filled row by row. [slotOf] assigns a new glyph the next
/// free slot and queues it; [flush] rasterises every queued glyph at once,
/// into a new image of each page that got glyphs (the page's previous
/// image is copied in first, then [AtlasImage.retire]d). A page image is
/// only as tall as the slot rows in use ([imageHeight]), so the last,
/// partly filled page costs what it holds, not a full page. The renderer
/// flushes once per frame, so a page gets at most one new image per frame
/// and a full page never changes again.
///
/// **Fallbacks.** [slotOf] returns -1 for a glyph whose advance is not one
/// cell (within half a device pixel), i.e. one from a fallback font: the
/// caller draws it another way.
final class GlyphAtlas {
  /// An atlas for cells of [metrics]; [styleOf] gives the engine text style
  /// of a glyph in a colour and faces (with the grid letter spacing).
  /// Images are counted in [ledger]. A page is at most [maxPageWidth] ×
  /// [maxPageHeight] device pixels and [maxPageBytes] bytes, but always
  /// holds at least one slot.
  GlyphAtlas({
    required this.metrics,
    required this.styleOf,
    required this.ledger,
    int maxPageWidth = 1024,
    int maxPageHeight = 512,
    int maxPageBytes = defaultMaxPageBytes,
  }) : padX = (metrics.widthPx + 1) ~/ 2,
       padTop = (metrics.heightPx * 3 + 9) ~/ 10,
       padBottom = (metrics.heightPx + 7) ~/ 8 {
    slotWidth = metrics.widthPx + 2 * padX;
    slotHeight = metrics.heightPx + padTop + padBottom;
    final slotBytes = slotWidth * slotHeight * 4;
    columns = math.max(
      1,
      math.min(maxPageWidth ~/ slotWidth, maxPageBytes ~/ slotBytes),
    );
    rowsPerPage = math.max(
      1,
      math.min(
        maxPageHeight ~/ slotHeight,
        maxPageBytes ~/ (slotBytes * columns),
      ),
    );
    _ascii.fillRange(0, _ascii.length, _unknown);
  }

  /// The default bound of a page's size: 2 MiB, one eighth of the
  /// renderer's default cache budget.
  static const defaultMaxPageBytes = 2 << 20;

  /// Luminance levels a glyph's raster colour is quantised to.
  static const lumaBuckets = 16;

  /// The blend mode that fills a glyph's alpha with its cell colour
  /// (`colors` of `drawRawAtlas` are the destination, the atlas the
  /// source).
  static const blendMode = BlendMode.dstIn;

  /// The cell size and baseline.
  final VtCellMetrics metrics;

  /// The engine style of a glyph in `color` (ARGB) and `faces`.
  final ui.TextStyle Function(int color, int faces) styleOf;

  /// Where the page images are counted.
  final AtlasLedger ledger;

  /// Margins of a slot around its cell, in device pixels: half a cell
  /// left and right, 3/10 of a cell above, 1/8 below. With the pinned
  /// JetBrains Mono, ink leaves the cell by up to ~0.3 cell width on either
  /// side (Greek tonos, italic `Ĵ`) and 0.25 cell height above (`Ǻ`), and
  /// never below (`glyph_atlas_test.dart` checks every grid-safe glyph).
  final int padX, padTop, padBottom;

  /// Slot size in device pixels.
  late final int slotWidth, slotHeight;

  /// Slots per page row, and page rows.
  late final int columns, rowsPerPage;

  /// Slots per page.
  int get slotsPerPage => columns * rowsPerPage;

  /// Page size in device pixels.
  int get pageWidth => columns * slotWidth;

  /// The height of a full page in device pixels.
  int get pageHeight => rowsPerPage * slotHeight;

  /// The bytes of a full page image.
  int get pageBytes => pageWidth * pageHeight * 4;

  /// The height of page [index]'s image once every assigned slot is
  /// rasterised: whole slot rows, up to the last one in use.
  int imageHeight(int index) {
    final used = math.min(slotsPerPage, _count - index * slotsPerPage);
    return ((used + columns - 1) ~/ columns) * slotHeight;
  }

  static const _unknown = -2;

  // key -> slot, or -1 when the glyph does not fit the grid.
  final _slots = <int, int>{};
  // The same for ASCII, indexed by (bucket * 4 + faces) * 128 + unit.
  final _ascii = Int32List(lumaBuckets * 4 * 128);
  final _pending = <(int, ui.Paragraph)>[];
  final _pages = <AtlasImage>[];
  final _prefilled = <int>{};
  int _count = 0;
  int _rasterised = 0;
  bool _disposed = false;

  static final _paragraphStyle = ui.ParagraphStyle(
    textDirection: TextDirection.ltr,
  );

  /// Glyphs rasterised since creation (tests).
  int debugRasterised = 0;

  /// Page images created since creation (tests).
  int debugImages = 0;

  /// Slots assigned so far (rasterised or queued).
  int get slotCount => _count;

  /// Whether glyphs are queued for the next [flush].
  bool get hasPending => _pending.isNotEmpty;

  /// Pages with an image.
  int get pageCount => _pages.length;

  /// The bytes of this atlas's current page images (superseded images
  /// still pinned by pictures are counted in [ledger] only).
  int get liveBytes => _liveBytes;
  int _liveBytes = 0;

  /// The luminance bucket (0 to [lumaBuckets] - 1) of an ARGB [color]:
  /// Rec. 709 luma of its RGB, alpha ignored.
  static int lumaBucket(int color) {
    final luma =
        0.2126 * (color >> 16 & 0xFF) +
        0.7152 * (color >> 8 & 0xFF) +
        0.0722 * (color & 0xFF);
    return (luma / 255 * (lumaBuckets - 1)).round();
  }

  /// The opaque grey a glyph of luminance [bucket] is rasterised in.
  static int rasterColor(int bucket) {
    final grey = (bucket * 255 / (lumaBuckets - 1)).round();
    return 0xFF000000 | grey << 16 | grey << 8 | grey;
  }

  /// Whether [color] (ARGB) is exactly the grey its luminance bucket is
  /// rasterised in, so a glyph drawn untinted has the cell's colour.
  static bool isExactGrey(int color) => color == rasterColor(lumaBucket(color));

  /// The slot key of [unit] (a UTF-16 code unit) in [faces] (bold 1,
  /// italic 2) and luminance [bucket]: at most 22 bits, so it is exact
  /// and cheap on every Dart platform (dart2js integers are doubles, and
  /// its bitwise operators work on 32 bits).
  static int keyOf(int unit, int faces, int bucket) =>
      bucket << 18 | (faces & 3) << 16 | (unit & 0xFFFF);

  /// The slot of [unit] in [faces] and the luminance bucket of [color],
  /// or -1 if it must be drawn another way (its advance is not one cell).
  /// A new glyph gets the next free slot and is queued for [flush]; see
  /// [isRasterised].
  int slotOf(int unit, int faces, int color) {
    final bucket = lumaBucket(color);
    final ascii = unit < 128;
    final index = ascii ? (bucket * 4 + (faces & 3)) * 128 + unit : 0;
    if (ascii) {
      final known = _ascii[index];
      if (known != _unknown) return known;
    }
    final key = keyOf(unit, faces, bucket);
    final known = ascii ? null : _slots[key];
    if (known != null) return known;
    final slot = _newSlot(unit, faces & 3, bucket);
    if (ascii) {
      _ascii[index] = slot;
    } else {
      _slots[key] = slot;
    }
    return slot;
  }

  int _newSlot(int unit, int faces, int bucket) {
    assert(!_disposed, 'used a disposed glyph atlas');
    final paragraph =
        (ui.ParagraphBuilder(_paragraphStyle)
              ..pushStyle(styleOf(rasterColor(bucket), faces))
              ..addText(String.fromCharCode(unit)))
            .build()
          ..layout(const ui.ParagraphConstraints(width: double.infinity));
    if ((paragraph.maxIntrinsicWidth - metrics.width).abs() *
            metrics.devicePixelRatio >
        0.5) {
      paragraph.dispose();
      return -1;
    }
    final slot = _count++;
    _pending.add((slot, paragraph));
    return slot;
  }

  /// Whether [slot] is in a page image already (not only queued).
  bool isRasterised(int slot) => slot < _rasterised;

  /// Queues printable ASCII (U+0021-007E) in the regular face and
  /// [color]'s luminance bucket, once per bucket: the glyphs nearly every
  /// screen needs, in page 0 before any row asks for them.
  void prefill(int color) {
    if (!_prefilled.add(lumaBucket(color))) return;
    for (var unit = 0x21; unit < 0x7F; unit++) {
      slotOf(unit, 0, color);
    }
  }

  /// The page of [slot].
  int pageOf(int slot) => slot ~/ slotsPerPage;

  /// The current image of page [index] (after a [flush]).
  AtlasImage page(int index) => _pages[index];

  /// Writes the source rectangle of [slot] at [i] (four floats) in [rects],
  /// relative to its page.
  void writeRect(Float32List rects, int i, int slot) {
    final inPage = slot % slotsPerPage;
    final x = (inPage % columns) * slotWidth.toDouble();
    final y = (inPage ~/ columns) * slotHeight.toDouble();
    rects[i] = x;
    rects[i + 1] = y;
    rects[i + 2] = x + slotWidth;
    rects[i + 3] = y + slotHeight;
  }

  /// Rasterises every queued glyph: one new image per page that got
  /// glyphs, with the page's previous image copied in. Returns whether
  /// anything was rasterised.
  bool flush() {
    if (_pending.isEmpty) return false;
    final dpr = metrics.devicePixelRatio;
    var start = 0;
    while (start < _pending.length) {
      final page = pageOf(_pending[start].$1);
      var end = start;
      while (end < _pending.length && pageOf(_pending[end].$1) == page) {
        end++;
      }
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final previous = page < _pages.length ? _pages[page] : null;
      if (previous != null) {
        canvas.drawImage(
          previous.image,
          Offset.zero,
          Paint()..blendMode = BlendMode.src,
        );
      }
      canvas.scale(dpr);
      for (var i = start; i < end; i++) {
        final (slot, paragraph) = _pending[i];
        final inPage = slot % slotsPerPage;
        final x = (inPage % columns) * slotWidth + padX;
        final y = (inPage ~/ columns) * slotHeight + padTop;
        canvas.drawParagraph(
          paragraph,
          Offset(
            x / dpr,
            y / dpr + metrics.baseline - paragraph.alphabeticBaseline,
          ),
        );
      }
      final picture = recorder.endRecording();
      final height = imageHeight(page);
      final image = AtlasImage._(
        picture.toImageSync(pageWidth, height),
        pageWidth * height * 4,
        ledger,
      );
      _liveBytes += image.bytes - (previous?.bytes ?? 0);
      picture.dispose();
      debugImages++;
      if (previous == null) {
        assert(page == _pages.length, 'pages are filled in order');
        _pages.add(image);
      } else {
        _pages[page] = image;
        previous.retire();
      }
      start = end;
    }
    for (final (_, paragraph) in _pending) {
      paragraph.dispose();
    }
    debugRasterised += _pending.length;
    _pending.clear();
    _rasterised = _count;
    return true;
  }

  /// Drops the queued glyphs and retires every page image (each is freed
  /// once no cached picture uses it). The atlas cannot be used again.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final (_, paragraph) in _pending) {
      paragraph.dispose();
    }
    _pending.clear();
    for (final page in _pages) {
      page.retire();
    }
    _pages.clear();
    _liveBytes = 0;
  }
}
