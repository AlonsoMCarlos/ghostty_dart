import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../seams/terminal_geometry.dart';
import '../seams/terminal_seams.dart';
import '../theme/terminal_theme.dart';
import 'glyph_atlas.dart';
import 'paragraph_cache.dart';
import 'row_recorder.dart';
import 'text_rendering.dart';

/// The terminal grid renderer (ADR 0011 "Rendering (v1)", ADR 0012): one
/// repaint-isolated render box that draws the rows of [source] with a
/// cached picture per row, plus the cursor, inside [geometry]. Grid text
/// comes from a glyph atlas or from paragraphs ([textRendering]). Never
/// exported.
///
/// Output only repaints: the frame is read from [source] once per paint,
/// only rows that changed are recorded again, and a frame where nothing
/// changed records nothing. The cursor is an overlay with its own blink
/// timer, so moving or blinking it never records a row.
class TerminalRenderWidget extends LeafRenderObjectWidget {
  /// A renderer for [source] laid out by [geometry], drawing with
  /// [textStyle]'s font. [focused] selects the focused cursor style.
  const TerminalRenderWidget({
    super.key,
    required this.source,
    required this.geometry,
    required this.textStyle,
    required this.focused,
    this.hideCursor = false,
    this.textScaler = TextScaler.noScaling,
    this.cursorStyle,
    this.alwaysShowCursor = false,
    this.backgroundOpacity = 1.0,
    this.cursorHidden,
    this.cacheBudget = RenderTerminal.defaultCacheBudget,
    this.textRendering = VtTextRendering.atlas,
  }) : assert(
         backgroundOpacity >= 0 && backgroundOpacity <= 1,
         'backgroundOpacity must be between 0 and 1',
       );

  /// Where the frames come from.
  final TerminalFrameSource source;

  /// Where the grid is and how big its cells are.
  final TerminalGeometry geometry;

  /// The font of the grid; [geometry]'s metrics were measured with it (and
  /// with [textScaler]).
  final TextStyle textStyle;

  /// Whether the view has keyboard focus. An unfocused view draws the
  /// cursor as a hollow block and does not blink it.
  final bool focused;

  /// Whether to hide the cursor, e.g. while the input layer shows IME
  /// composing text at the cursor.
  final bool hideCursor;

  /// The text scaling [geometry]'s metrics were measured with
  /// (`VtCellMetrics.measure`); applied to [textStyle]'s font size.
  final TextScaler textScaler;

  /// Draws the cursor in this shape instead of the one the program asked
  /// for (DECSCUSR); `null` follows the program. For xterm's `cursorType`.
  final VtCursorStyle? cursorStyle;

  /// Draws the cursor even while the program hides it (DECTCEM). For
  /// xterm's `alwaysShowCursor`.
  final bool alwaysShowCursor;

  /// The opacity of the default background (0 to 1), so the app behind
  /// shows through. Cell backgrounds stay opaque. For xterm's
  /// `backgroundOpacity`.
  final double backgroundOpacity;

  /// Hides the cursor while its value is true, like [hideCursor], but
  /// without a rebuild: the render box listens to it and repaints. The view
  /// drives it from the IME composing state, which can change while the
  /// tree is being built (a connection closed from `didUpdateWidget`).
  final ValueListenable<bool>? cursorHidden;

  /// About how many bytes of row pictures, atlas images and paragraphs
  /// the view keeps cached (see [RenderTerminal.cacheBudget]).
  final int cacheBudget;

  /// How grid text is drawn (see [VtTextRendering]).
  final VtTextRendering textRendering;

  @override
  RenderTerminal createRenderObject(BuildContext context) => RenderTerminal(
    source: source,
    geometry: geometry,
    textStyle: textStyle,
    focused: focused,
    hideCursor: hideCursor,
    textScaler: textScaler,
    cursorStyle: cursorStyle,
    alwaysShowCursor: alwaysShowCursor,
    backgroundOpacity: backgroundOpacity,
    cursorHidden: cursorHidden,
    blinkEnabled: TickerMode.valuesOf(context).enabled,
    cacheBudget: cacheBudget,
    textRendering: textRendering,
  );

  @override
  void updateRenderObject(BuildContext context, RenderTerminal renderObject) {
    renderObject
      ..source = source
      ..geometry = geometry
      ..textStyle = textStyle
      ..focused = focused
      ..hideCursor = hideCursor
      ..textScaler = textScaler
      ..cursorStyle = cursorStyle
      ..alwaysShowCursor = alwaysShowCursor
      ..backgroundOpacity = backgroundOpacity
      ..cursorHidden = cursorHidden
      ..blinkEnabled = TickerMode.valuesOf(context).enabled
      ..cacheBudget = cacheBudget
      ..textRendering = textRendering;
  }
}

/// A recorded row picture, the content it was recorded from and the atlas
/// images it draws (retained while it lives).
final class _CachedRow {
  _CachedRow(this.picture, this.content, this.frame, this.images, this.bytes) {
    for (final image in images) {
      image.retain();
    }
  }

  final ui.Picture picture;
  final RowContent content;
  final List<AtlasImage> images;

  /// The picture's estimated size: `RowContent.estimatedBytes` for a
  /// paragraph-path picture; for an atlas-path picture its display list
  /// (`ui.Picture.approximateBytesUsed`) plus
  /// `RowContent.atlasOverheadBytes`.
  final int bytes;

  void dispose() {
    picture.dispose();
    for (final image in images) {
      image.release();
    }
  }

  /// The last frame that showed this picture.
  int frame;
}

/// The render box behind [TerminalRenderWidget]. Never exported.
///
/// **Row cache.** Each visible row is a [ui.Picture] keyed by its
/// [RenderRowId], stored with the [RowContent] it was recorded from. A row
/// that is dirty (or every row, after a colour, theme or column change) is
/// scanned again; its picture is recorded again only if the scan differs
/// from the cached content. libghostty-vt flags every row dirty when the
/// viewport moves, so this content check is what lets a scroll reuse the
/// rows that only moved (ADR 0011, amendment of 2026-11-10). Pictures of
/// rows that left the viewport are disposed. Every picture and paragraph
/// is dropped when the text style, text scaler, cell metrics or
/// [textRendering] change.
///
/// **Glyph atlas** (ADR 0012, [VtTextRendering.atlas]). The recorder draws
/// grid text from a [GlyphAtlas] that belongs to it, so the atlas is
/// dropped wherever the recorder is. Glyphs a frame's rows miss are
/// queued while the rows are recorded and rasterised once, after them;
/// only those rows are recorded again. Atlas images count in
/// [cacheBudget], including superseded page images that cached pictures
/// still draw ([AtlasLedger]).
///
/// **Render hold.** While [TerminalFrameSource.isRenderHeld] is true the
/// frame is not read and nothing is dropped: the cached pictures are
/// replayed, and a font or theme change waits for the end of the hold.
///
/// **Disposal.** Once [TerminalFrameSource.isDisposed] is true it paints
/// the last background colour only and frees every picture.
///
/// **Pixel alignment.** Cell edges fall on device pixels relative to this
/// box. The box itself is not snapped: placed at a fractional device-pixel
/// offset by its parent, its layer is resampled and text blurs.
class RenderTerminal extends RenderBox with WidgetsBindingObserver {
  /// Creates the render box; see [TerminalRenderWidget].
  RenderTerminal({
    required TerminalFrameSource source,
    required TerminalGeometry geometry,
    required TextStyle textStyle,
    required bool focused,
    bool hideCursor = false,
    TextScaler textScaler = TextScaler.noScaling,
    VtCursorStyle? cursorStyle,
    bool alwaysShowCursor = false,
    double backgroundOpacity = 1.0,
    ValueListenable<bool>? cursorHidden,
    bool blinkEnabled = true,
    int cacheBudget = defaultCacheBudget,
    VtTextRendering textRendering = VtTextRendering.atlas,
  }) : _source = source,
       _cursorHidden = cursorHidden,
       _geometry = geometry,
       _textStyle = textStyle,
       _focused = focused,
       _hideCursor = hideCursor,
       _textScaler = textScaler,
       _cursorStyle = cursorStyle,
       _alwaysShowCursor = alwaysShowCursor,
       _backgroundOpacity = backgroundOpacity,
       _blinkEnabled = blinkEnabled,
       _cacheBudget = cacheBudget,
       _textRendering = textRendering,
       _paragraphs = ParagraphCache(maxBytes: cacheBudget ~/ 4);

  /// How long the cursor stays on, then off, while it blinks: Ghostty's
  /// `CURSOR_BLINK_INTERVAL` (600 ms, `src/renderer/Thread.zig:20` at
  /// libghostty-vt 1.0.0, read 2026-11-10).
  static const blinkInterval = Duration(milliseconds: 600);

  /// The width of a bar cursor and the height of an underline cursor, as
  /// a fraction of the cell width (at least one device pixel). A heuristic.
  static const cursorThicknessFraction = 1 / 8;

  /// How long after its tickers are muted a view that is no longer
  /// composited releases its caches.
  static const hiddenReleaseDelay = Duration(seconds: 5);

  /// The default [cacheBudget]: 16 MiB per view.
  static const defaultCacheBudget = 16 << 20;

  TerminalFrameSource _source;
  TerminalGeometry _geometry;
  TextStyle _textStyle;
  bool _focused;
  bool _hideCursor;
  ValueListenable<bool>? _cursorHidden;
  TextScaler _textScaler;
  VtCursorStyle? _cursorStyle;
  bool _alwaysShowCursor;
  double _backgroundOpacity;
  bool _blinkEnabled;
  int _cacheBudget;
  VtTextRendering _textRendering;

  /// See [TerminalRenderWidget.textRendering]. A change drops every cached
  /// picture, as a font change does.
  VtTextRendering get textRendering => _textRendering;
  set textRendering(VtTextRendering value) {
    if (value == _textRendering) return;
    _textRendering = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.source].
  TerminalFrameSource get source => _source;
  set source(TerminalFrameSource value) {
    if (identical(value, _source)) return;
    if (attached) _source.removeListener(_onSourceChanged);
    _source = value;
    if (attached) _source.addListener(_onSourceChanged);
    // Row ids belong to the old source's render state.
    _dropRows();
    _colors = null;
    _cursor = null;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.geometry].
  TerminalGeometry get geometry => _geometry;
  set geometry(TerminalGeometry value) {
    if (value == _geometry) return;
    _geometry = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.textStyle].
  TextStyle get textStyle => _textStyle;
  set textStyle(TextStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.focused].
  bool get focused => _focused;
  set focused(bool value) {
    if (value == _focused) return;
    _focused = value;
    _blinkOn = true;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.hideCursor].
  bool get hideCursor => _hideCursor;
  set hideCursor(bool value) {
    if (value == _hideCursor) return;
    _hideCursor = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.cursorHidden].
  ValueListenable<bool>? get cursorHidden => _cursorHidden;
  set cursorHidden(ValueListenable<bool>? value) {
    if (identical(value, _cursorHidden)) return;
    if (attached) _cursorHidden?.removeListener(markNeedsPaint);
    _cursorHidden = value;
    if (attached) _cursorHidden?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  /// Whether the cursor is hidden now, by [hideCursor] or [cursorHidden].
  bool get isCursorHidden => _hideCursor || (_cursorHidden?.value ?? false);

  /// See [TerminalRenderWidget.textScaler].
  TextScaler get textScaler => _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.cursorStyle].
  VtCursorStyle? get cursorStyle => _cursorStyle;
  set cursorStyle(VtCursorStyle? value) {
    if (value == _cursorStyle) return;
    _cursorStyle = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.alwaysShowCursor].
  bool get alwaysShowCursor => _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.backgroundOpacity].
  double get backgroundOpacity => _backgroundOpacity;
  set backgroundOpacity(double value) {
    if (value == _backgroundOpacity) return;
    _backgroundOpacity = value;
    markNeedsPaint();
  }

  /// Whether the cursor may blink: `false` while tickers are muted
  /// ([TickerMode]), e.g. in a hidden tab or a route below another.
  bool get blinkEnabled => _blinkEnabled;
  set blinkEnabled(bool value) {
    if (value == _blinkEnabled) return;
    _blinkEnabled = value;
    // Pausing or resuming the blink always shows the cursor: a blink
    // stopped in its "off" half would otherwise leave it hidden.
    _blinkOn = true;
    _releaseTimer?.cancel();
    _releaseTimer = null;
    if (!value) {
      _stopBlink();
      // Muted tickers may mean a hidden view (an offstage tab, a covered
      // route) or only paused animations around a view still on screen.
      // Check later whether the view is still composited.
      _releaseTimer = Timer(hiddenReleaseDelay, _releaseIfHidden);
    }
    markNeedsPaint();
  }

  /// About how many bytes of row pictures, glyph atlas images and
  /// paragraphs this view keeps: pictures, atlas images and paragraphs
  /// together stay within it, and paragraphs alone within a quarter of it.
  /// Sizes are estimates (`RowContent.estimatedBytes` for paragraph-path
  /// pictures; an atlas-path picture's display list plus
  /// `RowContent.atlasOverheadBytes`; `ParagraphCache.estimatedBytes`) and
  /// exact for atlas images (4 bytes per pixel, superseded images still
  /// drawn by cached pictures included). Pictures shown in the current
  /// frame, and the atlas images they draw, are kept even beyond it.
  ///
  /// The atlas itself may grow to half of the budget; past that (and past
  /// twice what it held after its first frame, so a screen that needs more
  /// does not thrash) it is dropped with every picture at the next paint
  /// and rebuilt from the screen.
  ///
  /// Pictures are kept by content: a row whose new content was shown
  /// recently (a program redrawing the screen shifted by a line, or
  /// switching back to a screen it drew before) reuses its picture
  /// instead of drawing it again. A 200-column row of ~25 styled runs is
  /// estimated at ~9 KiB with the atlas and ~25 KiB with paragraphs, so
  /// the default keeps about 1,000 atlas rows next to a heavily coloured
  /// atlas (~6 MiB), or about 650 paragraph rows.
  ///
  /// The caches are released when the box is detached; when its tickers
  /// are muted ([blinkEnabled] false) and, [hiddenReleaseDelay] later, it
  /// is no longer composited (a hidden tab, a covered route; a muted view
  /// still on screen keeps them); on memory pressure (all but the visible
  /// rows, and the atlas too if it holds pages the screen does not draw);
  /// and when the system fonts change.
  int get cacheBudget => _cacheBudget;
  set cacheBudget(int value) {
    if (value == _cacheBudget) return;
    _cacheBudget = value;
    _paragraphs
      ..maxBytes = value ~/ 4
      ..trim();
    _evictPictures(_frame);
  }

  Timer? _releaseTimer;

  // Releases the caches if the view is not on screen: a repaint boundary
  // whose layer is no longer in the layer tree (an offstage ancestor
  // stopped painting it). A muted view that is still painted keeps them.
  void _releaseIfHidden() {
    _releaseTimer = null;
    if (_blinkEnabled || !attached) return;
    if (layer?.attached ?? false) return;
    _dropAll();
  }

  int get _atlasBudget => _cacheBudget ~/ 2;

  // Every atlas image of this view (live or pinned by cached pictures).
  final _ledger = AtlasLedger();

  // What the atlas held after the first frame of its generation.
  int _atlasFloor = 0;

  // Row cache.
  final ParagraphCache _paragraphs;
  // The picture each visible row shows. Every value is also in _pictures,
  // which owns (and disposes) the pictures.
  final _rows = <RenderRowId, _CachedRow>{};
  // Pictures by content, least recently used first (a map literal keeps
  // insertion order; a use re-inserts).
  final _pictures = <RowContent, _CachedRow>{};
  int _pictureBytes = 0;
  int _pictureHits = 0;
  List<RenderRowId?> _visibleRowIds = const [];
  bool _visibleRowsComplete = false;
  int _rowCols = 0;
  int _frame = 0;

  // What the cached pictures were recorded with.
  RowRecorder? _recorder;
  VtTerminalTheme? _recordedTheme;
  RenderColors? _colors;

  // Cursor overlay.
  RenderCursor? _cursor;
  CursorCell? _cursorCell;
  bool _blinkOn = true;
  bool _paintedSinceTick = false;
  VtCursorStyle? _paintedCursor;
  Timer? _blinkTimer;

  Color? _lastBackground;
  int _rowRecordings = 0;
  int _rowScans = 0;

  /// How many row pictures were recorded since creation (tests prove that
  /// frames without changes record nothing).
  @visibleForTesting
  int get debugRowRecordings => _rowRecordings;

  /// How many rows were scanned since creation (a scan that matches the
  /// cached content keeps the picture).
  @visibleForTesting
  int get debugRowScans => _rowScans;

  /// How many visible rows have a picture.
  @visibleForTesting
  int get debugCachedRows => _rows.length;

  /// How many pictures the content cache holds (visible rows included).
  @visibleForTesting
  int get debugCachedPictures => _pictures.length;

  /// The estimated bytes of the cached pictures.
  @visibleForTesting
  int get debugPictureBytes => _pictureBytes;

  /// The glyph atlas of the current recorder, if any.
  @visibleForTesting
  GlyphAtlas? get debugAtlas => _recorder?.atlas;

  /// The bytes of every atlas image not freed yet (live pages and
  /// superseded ones still drawn by cached pictures).
  @visibleForTesting
  int get debugAtlasBytes => _ledger.bytes;

  /// How many atlas images are not freed yet.
  @visibleForTesting
  int get debugAtlasImages => _ledger.images;

  /// Rows the current recorder drew as one paragraph (see
  /// `RowRecorder.debugRowParagraphs`); resets when the caches drop.
  @visibleForTesting
  int get debugRowParagraphs => _recorder?.debugRowParagraphs ?? 0;

  /// How many times a changed row found its new content's picture in the
  /// content cache instead of recording it, since creation.
  @visibleForTesting
  int get debugPictureHits => _pictureHits;

  /// The paragraph cache (tests check its size and that it is cleared).
  @visibleForTesting
  ParagraphCache get debugParagraphs => _paragraphs;

  /// Whether the cursor is in the "on" half of its blink.
  @visibleForTesting
  bool get debugBlinkOn => _blinkOn;

  /// The cursor shape the last paint drew, or `null` if it drew none
  /// (hidden, scrolled away or in the "off" half of its blink).
  @visibleForTesting
  VtCursorStyle? get debugPaintedCursor => _paintedCursor;

  /// Whether the blink timer runs.
  @visibleForTesting
  bool get debugBlinking => _blinkTimer?.isActive ?? false;

  /// Drops every cached picture, paragraph and colour, as a cold start
  /// would; the next paint rebuilds everything from the frame source.
  /// Tests compare the pixels before and after.
  @visibleForTesting
  void debugDropCaches() {
    _dropAll();
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _source.addListener(_onSourceChanged);
    _cursorHidden?.addListener(markNeedsPaint);
    WidgetsBinding.instance.addObserver(this);
    PaintingBinding.instance.systemFonts.addListener(_onSystemFonts);
  }

  @override
  void detach() {
    _source.removeListener(_onSourceChanged);
    _cursorHidden?.removeListener(markNeedsPaint);
    WidgetsBinding.instance.removeObserver(this);
    _releaseTimer?.cancel();
    _releaseTimer = null;
    PaintingBinding.instance.systemFonts.removeListener(_onSystemFonts);
    _stopBlink();
    // A detached box paints nothing; reattaching records the screen once.
    _dropAll();
    super.detach();
  }

  @override
  void didHaveMemoryPressure() {
    // Keep what the screen shows, drop everything else.
    _paragraphs.clear();
    _evictPictures(_frame, budget: 0);
    // An atlas page the screen does not draw can only go with the whole
    // atlas: drop it and the pictures, and record the screen again.
    final atlas = _recorder?.atlas;
    if (atlas == null) return;
    final drawn = <AtlasImage>{for (final row in _rows.values) ...row.images};
    for (var page = 0; page < atlas.pageCount; page++) {
      if (!drawn.contains(atlas.page(page))) {
        _dropAll();
        markNeedsPaint();
        return;
      }
    }
  }

  // A font was installed or removed: glyphs drawn with a fallback may now
  // have their own font (as RenderParagraph does on this notification).
  void _onSystemFonts() {
    _dropAll();
    markNeedsPaint();
  }

  @override
  void dispose() {
    _releaseTimer?.cancel();
    _stopBlink();
    _dropAll();
    super.dispose();
  }

  void _onSourceChanged() {
    // Output or input: show the cursor at once and restart its blink (the
    // paint that follows starts the timer again).
    _blinkOn = true;
    _stopBlink();
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paintedSinceTick = true;
    final canvas = context.canvas;
    final bounds = offset & size;
    if (_source.isDisposed) {
      _stopBlink();
      _dropAll();
      canvas.drawRect(
        bounds,
        Paint()
          ..color = _withOpacity(_lastBackground ?? const Color(0xFF000000)),
      );
      return;
    }

    final held = _source.isRenderHeld;
    // While held, keep the old recorder and pictures: a font or theme
    // change is applied when the hold ends, so the grid never goes blank.
    final recorder = held && _recorder != null
        ? _recorder!
        : _prepareRecorder();
    if (!held) _pullFrame(recorder);

    final colors = _colors;
    final background = colors == null
        ? _source.theme.background
        : colorOfRgb(colors.background);
    _lastBackground = background;
    canvas
      ..drawRect(bounds, Paint()..color = _withOpacity(background))
      ..save()
      ..clipRect(bounds);
    final grid = offset + _geometry.gridRect.topLeft;
    final height = _geometry.metrics.height;
    for (var y = 0; y < _visibleRowIds.length; y++) {
      final id = _visibleRowIds[y];
      final row = id == null ? null : _rows[id];
      if (row == null) continue;
      canvas
        ..save()
        ..translate(grid.dx, grid.dy + y * height)
        ..drawPicture(row.picture)
        ..restore();
    }
    final drawn = _paintCursor(canvas, grid, recorder);
    canvas.restore();
    _syncBlink(drawn);
  }

  Color _withOpacity(Color color) => _backgroundOpacity >= 1
      ? color
      : color.withValues(alpha: color.a * _backgroundOpacity);

  /// The recorder for the current font and metrics; drops every cached
  /// picture and paragraph when one of them changed. A theme change only
  /// makes the next pull scan every row (the selection colour is part of
  /// a row's content).
  RowRecorder _prepareRecorder() {
    final metrics = _geometry.metrics;
    final theme = _source.theme;
    if (theme != _recordedTheme) {
      _recordedTheme = theme;
      _visibleRowsComplete = false;
      _rescanAll = true;
    }
    final current = _recorder;
    final useAtlas = _textRendering == VtTextRendering.atlas;
    if (current != null &&
        current.metrics == metrics &&
        current.textStyle == _textStyle &&
        current.textScaler == _textScaler &&
        (current.atlas != null) == useAtlas &&
        !_atlasOverBudget(current.atlas)) {
      return current;
    }
    _dropRows();
    _paragraphs.clear();
    current?.dispose();
    _atlasFloor = 0;
    final recorder = RowRecorder(
      metrics: metrics,
      textStyle: _textStyle,
      textScaler: _textScaler,
      paragraphs: _paragraphs,
      atlasLedger: useAtlas ? _ledger : null,
      // 2 MiB pages for the default budget, smaller ones for small budgets.
      atlasPageBytes: _cacheBudget ~/ 8,
    );
    return _recorder = recorder;
  }

  // Whether [atlas] outgrew its share of the budget, and twice what its
  // first frame needed (so a screen that needs more does not drop it
  // every frame).
  bool _atlasOverBudget(GlyphAtlas? atlas) {
    if (atlas == null || _atlasFloor == 0) return false;
    final bytes = atlas.liveBytes;
    return bytes > _atlasBudget && bytes > 2 * _atlasFloor;
  }

  bool _rescanAll = false;

  /// Reads the frame and re-records the rows whose content changed.
  void _pullFrame(RowRecorder recorder) {
    final state = _source.updateFrame();
    try {
      final colors = state.colors;
      if (!identical(colors, _colors)) {
        // The cursor colour is not part of any row.
        final previous = _colors;
        if (previous == null || !_sameRowColors(previous, colors)) {
          _rescanAll = true;
        }
        _colors = colors;
      }
      if (state.cols != _rowCols) {
        _rescanAll = true;
        _rowCols = state.cols;
      }
      final rows = math.min(state.rows, _geometry.rows);
      final cursor = state.cursor;
      final needsPass =
          _rescanAll ||
          state.dirty != RenderDirtyState.clean ||
          !identical(cursor, _cursor) ||
          _visibleRowIds.length != rows ||
          !_visibleRowsComplete;
      _cursor = cursor;
      if (!needsPass) return;

      final frame = ++_frame;
      final position = cursor.position;
      final cursorY = position?.y ?? -1;
      final cursorX = position == null
          ? 0
          : position.x - (cursor.isOnWideTail ? 1 : 0);
      CursorCell? cursorCell;
      final ids = List<RenderRowId?>.filled(rows, null);
      final selection = _recordedTheme!.selection;
      var complete = true;
      final atlas = recorder.atlas;
      if (atlas != null) {
        // The default foreground's printable ASCII goes first, in page 0.
        atlas
          ..prefill(colorOfRgb(colors.foreground).toARGB32())
          ..flush();
      }
      // Rows whose glyphs were not in the atlas yet: recorded again once
      // the atlas is flushed, after every other row.
      final missed = <(RenderRowId, RowContent)>[];
      try {
        for (final row in state.allRows) {
          final y = row.viewportY;
          if (y < 0 || y >= rows) continue;
          final id = row.id;
          final cached = _rows[id];
          if (cached == null || row.isDirty || _rescanAll) {
            recorder.scan(row, colors, selection);
            _rowScans++;
            if (cached == null || !recorder.scanMatches(cached.content)) {
              final content = recorder.takeScan();
              if (!_showContent(recorder, id, content, frame)) {
                missed.add((id, content));
              }
            } else {
              _touch(cached, frame);
            }
          } else {
            _touch(cached, frame);
          }
          ids[y] = id;
          if (y == cursorY && cursorX >= 0 && cursorX < row.length) {
            cursorCell = recorder.readCell(row, cursorX, colors);
          }
        }
        if (missed.isNotEmpty) {
          atlas!.flush();
          for (final (id, content) in missed) {
            final shown = _showContent(recorder, id, content, frame);
            assert(shown, 'a row missed glyphs after the atlas was flushed');
          }
        }
      } catch (_) {
        _dropRows();
        rethrow;
      }
      if (atlas != null && _atlasFloor == 0) _atlasFloor = atlas.liveBytes;
      for (final id in ids) {
        if (id == null) complete = false;
      }
      // By id, not by the entry's frame: rows with equal content share an
      // entry, so a row that left keeps the stamp of a visible twin.
      final visible = {for (final id in ids) ?id};
      _rows.removeWhere((id, _) => !visible.contains(id));
      _evictPictures(frame);
      _visibleRowIds = ids;
      _visibleRowsComplete = complete;
      _cursorCell = cursorCell;
      _rescanAll = false;
    } finally {
      _source.endFrame();
    }
  }

  /// Shows [content] in row [id]: its cached picture, or a new recording.
  /// Returns false, recording nothing, when the row needs atlas glyphs that
  /// are only queued.
  bool _showContent(
    RowRecorder recorder,
    RenderRowId id,
    RowContent content,
    int frame,
  ) {
    var entry = _pictures.remove(content);
    if (entry == null) {
      final picture = recorder.record(content);
      if (recorder.missedGlyphs) {
        picture.dispose();
        return false;
      }
      entry = _CachedRow(
        picture,
        content,
        frame,
        recorder.recordedImages,
        recorder.atlas == null
            ? content.estimatedBytes
            : picture.approximateBytesUsed + content.atlasOverheadBytes,
      );
      _pictureBytes += entry.bytes;
      _rowRecordings++;
    } else {
      _pictureHits++;
      entry.frame = frame;
    }
    _pictures[content] = entry;
    _rows[id] = entry;
    return true;
  }

  static bool _sameRowColors(RenderColors a, RenderColors b) {
    if (a.background != b.background || a.foreground != b.foreground) {
      return false;
    }
    final pa = a.palette;
    final pb = b.palette;
    for (var i = 0; i < pa.length; i++) {
      if (pa[i] != pb[i]) return false;
    }
    return true;
  }

  /// Paints the cursor; returns whether a blinking cursor is shown (so the
  /// blink timer should run).
  bool _paintCursor(Canvas canvas, Offset grid, RowRecorder recorder) {
    _paintedCursor = null;
    final cursor = _cursor;
    final position = cursor?.position;
    if (cursor == null || position == null || isCursorHidden) return false;
    if (!cursor.isVisible && !_alwaysShowCursor) return false;
    if (position.y >= _visibleRowIds.length) return false;
    final blinks = _focused && _blinkEnabled && cursor.isBlinking;
    if (blinks && !_blinkOn) return true;

    final metrics = _geometry.metrics;
    final x = position.x - (cursor.isOnWideTail ? 1 : 0);
    final colors = _colors!;
    final cell = _cursorCell ?? CursorCell.empty(colorOfRgb(colors.background));
    final span = cursor.isOnWideTail ? 2 : cell.span;
    final rect = Rect.fromLTWH(
      grid.dx + x * metrics.width,
      grid.dy + position.y * metrics.height,
      span * metrics.width,
      metrics.height,
    );
    final color = _cursorColor(colors);
    final px = 1 / metrics.devicePixelRatio;
    final thickness = math.max(
      px,
      (metrics.width * cursorThicknessFraction * metrics.devicePixelRatio)
              .round() *
          px,
    );
    final paint = Paint()..color = color;
    var style = _cursorStyle ?? cursor.style;
    if (!_focused) style = VtCursorStyle.blockHollow;
    _paintedCursor = style;
    switch (style) {
      case VtCursorStyle.block || VtCursorStyle.unknown:
        canvas.drawRect(rect, paint);
        recorder.paintCellText(canvas, cell, rect.topLeft, cell.background);
      case VtCursorStyle.blockHollow:
        canvas.drawRect(
          rect.deflate(px / 2),
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = px,
        );
      case VtCursorStyle.bar:
        canvas.drawRect(
          Rect.fromLTWH(rect.left, rect.top, thickness, rect.height),
          paint,
        );
      case VtCursorStyle.underline:
        canvas.drawRect(
          Rect.fromLTWH(
            rect.left,
            rect.bottom - thickness,
            rect.width,
            thickness,
          ),
          paint,
        );
    }
    return blinks;
  }

  /// The cursor colour (seam rule): the theme's own colour, alpha
  /// included, unless the program set another one (OSC 12).
  Color _cursorColor(RenderColors colors) {
    final theme = _source.theme;
    final program = colors.cursor;
    if (program == null || program == VtTerminalTheme.rgbOf(theme.cursor)) {
      return theme.cursor;
    }
    return colorOfRgb(program);
  }

  void _syncBlink(bool blinking) {
    if (!blinking || !attached) {
      _stopBlink();
      _blinkOn = true;
      return;
    }
    _blinkTimer ??= Timer.periodic(blinkInterval, (_) {
      if (!_paintedSinceTick) {
        // The last toggle was never painted: the view is offstage or
        // otherwise not drawn. Stop until the next paint restarts it.
        _stopBlink();
        _blinkOn = true;
        return;
      }
      _paintedSinceTick = false;
      _blinkOn = !_blinkOn;
      markNeedsPaint();
    });
  }

  void _stopBlink() {
    _blinkTimer?.cancel();
    _blinkTimer = null;
  }

  // Marks [entry] as shown in [frame] and moves it to the most recently
  // used end, so a row that stayed on screen is not the first to go once
  // it leaves.
  void _touch(_CachedRow entry, int frame) {
    if (entry.frame == frame) return;
    entry.frame = frame;
    _pictures
      ..remove(entry.content)
      ..[entry.content] = entry;
  }

  /// Disposes the least recently used pictures until the rest, with the
  /// atlas images, fit [budget] ([cacheBudget] less what the paragraph
  /// cache holds), never one shown in [frame]. A disposed picture releases
  /// its atlas images, so superseded pages it pinned are freed with it.
  void _evictPictures(int frame, {int? budget}) {
    final limit = budget ?? _cacheBudget - _paragraphs.bytes;
    if (_pictureBytes + _ledger.bytes <= limit) return;
    final evicted = <_CachedRow>[];
    for (final entry in _pictures.values) {
      if (_pictureBytes + _ledger.bytes <= limit) break;
      if (entry.frame == frame) continue;
      evicted.add(entry);
      _pictureBytes -= entry.bytes;
      // Releases the atlas images now, so the ledger is current.
      entry.dispose();
    }
    for (final entry in evicted) {
      _pictures.remove(entry.content);
    }
  }

  void _dropRows() {
    for (final row in _pictures.values) {
      row.dispose();
    }
    _pictures.clear();
    _pictureBytes = 0;
    _rows.clear();
    _visibleRowIds = const [];
    _visibleRowsComplete = false;
    _cursorCell = null;
  }

  void _dropAll() {
    _dropRows();
    _paragraphs.clear();
    _recorder?.dispose();
    _recorder = null;
    _recordedTheme = null;
    _colors = null;
    _cursor = null;
    _rowCols = 0;
  }
}
