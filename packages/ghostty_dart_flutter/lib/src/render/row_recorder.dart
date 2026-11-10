import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../metrics/cell_metrics.dart';
import 'paragraph_cache.dart';

/// Face flags of a cached paragraph (the `faces` field of
/// [ParagraphKey]). Never exported.
abstract final class TextFace {
  /// Bold weight.
  static const bold = 1;

  /// Italic style.
  static const italic = 2;

  /// A single cell laid out on its own, without the grid letter spacing:
  /// wide characters, grapheme clusters and glyphs that may come from a
  /// fallback font.
  static const cluster = 4;
}

/// The cell under the cursor, copied out of its (borrowed) row so the
/// cursor overlay can redraw its glyph in a block cursor. Never exported.
final class CursorCell {
  /// A copy of one cell.
  const CursorCell({
    required this.text,
    required this.span,
    required this.background,
    required this.faces,
  });

  /// An empty narrow cell on the default background.
  const CursorCell.empty(this.background) : text = '', span = 1, faces = 0;

  /// The cell's text, empty for a blank cell or invisible text.
  final String text;

  /// How many columns the cell covers: 2 for a wide character.
  final int span;

  /// The colour the cell's background is drawn in (inverse applied); a
  /// block cursor draws the glyph in this colour.
  final Color background;

  /// [TextFace] flags to draw [text] with.
  final int faces;
}

// Draw operations of a [RowContent], each followed by its operands.
const _opBackground = 1; // col, count, argb
const _opSelection = 2; // col, count, argb
const _opRun = 3; // col, text index, argb, faces
const _opCluster = 4; // col, text index, argb, faces, span
const _opDecoration = 5; // start, end, bits, underline argb, argb

// Decoration bits: the underline style's index (0-6), then the lines.
const _decoStrike = 1 << 3;
const _decoOverline = 1 << 4;

/// Everything that decides the pixels of one recorded row: a compact list
/// of draw operations (background spans, selection, text runs and
/// clusters with their colours, faces and columns, decorations) plus the
/// run texts. Never exported.
///
/// Two rows with equal content draw identical pixels with the same
/// [RowRecorder], so a cached picture whose content equals a freshly
/// scanned row is kept even when the row is flagged dirty. That is what
/// makes scrolling cheap: libghostty-vt flags every row dirty when the
/// viewport moves (ADR 0011, amendment of 2026-11-10).
final class RowContent {
  RowContent._(this._ops, this._texts, this._hash);

  final Uint32List _ops;
  final List<String> _texts;
  final int _hash;

  /// A readable list of the operations, for tests: `bg 0+3 #ffcd3131`,
  /// `sel 1+2 #aaaeafad`, `run 4 "abc" #ffcccccc f0`, `cluster 7 "中" …
  /// span 2`, `deco 0-5 underline:curly strike #ff000000 #ffcccccc`.
  List<String> debugDescribe() {
    String hex(int argb) => '#${argb.toRadixString(16).padLeft(8, '0')}';
    final out = <String>[];
    for (var i = 0; i < _ops.length;) {
      switch (_ops[i]) {
        case _opBackground:
          out.add('bg ${_ops[i + 1]}+${_ops[i + 2]} ${hex(_ops[i + 3])}');
          i += 4;
        case _opSelection:
          out.add('sel ${_ops[i + 1]}+${_ops[i + 2]} ${hex(_ops[i + 3])}');
          i += 4;
        case _opRun:
          out.add(
            'run ${_ops[i + 1]} "${_texts[_ops[i + 2]]}" '
            '${hex(_ops[i + 3])} f${_ops[i + 4]}',
          );
          i += 5;
        case _opCluster:
          out.add(
            'cluster ${_ops[i + 1]} "${_texts[_ops[i + 2]]}" '
            '${hex(_ops[i + 3])} f${_ops[i + 4]} span ${_ops[i + 5]}',
          );
          i += 6;
        default:
          final bits = _ops[i + 3];
          final underline = UnderlineStyle.values[bits & 7];
          out.add(
            'deco ${_ops[i + 1]}-${_ops[i + 2]}'
            '${underline == UnderlineStyle.none ? '' : ' underline:${underline.name}'}'
            '${bits & _decoStrike != 0 ? ' strike' : ''}'
            '${bits & _decoOverline != 0 ? ' overline' : ''}'
            ' ${hex(_ops[i + 4])} ${hex(_ops[i + 5])}',
          );
          i += 6;
      }
    }
    return out;
  }
}

/// Scans terminal rows into [RowContent] and records content into a
/// [ui.Picture] (ADR 0011 "Rendering (v1)"): merged background spans, the
/// selection, one paragraph per style run and hand-drawn decorations.
/// Never exported.
///
/// The picture is drawn at the row's top-left grid corner (x = 0 is column
/// 0, y = 0 the row's top).
///
/// **Grid placement.** Runs hold only narrow, single-codepoint cells of
/// scripts monospace fonts cover (Latin, Greek, Cyrillic, without format
/// or combining characters); they are laid out with
/// `letterSpacing = metrics.letterSpacing`, so glyph *i* advances by
/// exactly one cell width. Every run is measured once, when it is laid
/// out: if its width is not its cell count times the cell width (a glyph
/// from a fallback font, or a face with another advance), it is drawn cell
/// by cell instead. Everything else (wide characters, grapheme clusters,
/// emoji, symbols that may come from a fallback font) is laid out on its
/// own, centred in its one or two cells, and scaled down if wider.
final class RowRecorder {
  /// A recorder for rows of [metrics] cells in [textStyle] (scaled by
  /// [textScaler]), sharing paragraphs through [paragraphs].
  RowRecorder({
    required this.metrics,
    required this.textStyle,
    required this.paragraphs,
    this.textScaler = TextScaler.noScaling,
  }) : _fontSize = textScaler.scale(textStyle.fontSize ?? kDefaultFontSize) {
    final px = 1 / metrics.devicePixelRatio;
    _thickness = math.max(px, _snap(_fontSize * decorationThicknessEm));
    final underlineTop = _snap(
      metrics.baseline + _fontSize * underlineOffsetEm,
    );
    // Keep the underline (a double one is three thicknesses tall) inside
    // the cell.
    _underlineTop = math.min(underlineTop, metrics.height - 3 * _thickness);
    _strikeTop = _snap(metrics.baseline - _fontSize * strikethroughOffsetEm);
  }

  // Decoration geometry. Heuristics in ems of the font size until the
  // font's own values (`post` underline position and thickness, `OS/2`
  // strikeout position) are read from the font tables.

  /// Line thickness of underlines, strikethrough and overline: 1/14 em
  /// (one pixel at 14 px), at least one device pixel.
  static const decorationThicknessEm = 1 / 14;

  /// How far below the baseline the underline starts.
  static const underlineOffsetEm = 0.1;

  /// How far above the baseline the strikethrough sits (about half the
  /// x-height of common monospace fonts).
  static const strikethroughOffsetEm = 0.3;

  /// The alpha of faint text: Ghostty's default `faint-opacity` 0.5
  /// (`src/config/Config.zig:3929` at 1.0.0), applied as
  /// `ceil(0.5 * 255)` (`src/renderer/generic.zig:676`).
  static const faintAlpha = 0x80;

  /// Half a device pixel, in device pixels: the most a run may differ
  /// from its cells' width and still be drawn as one paragraph.
  static const gridTolerancePx = 0.5;

  /// The cell size and baseline.
  final VtCellMetrics metrics;

  /// The grid font; [metrics] were measured with it.
  final TextStyle textStyle;

  /// The text scaling [metrics] were measured with.
  final TextScaler textScaler;

  /// The paragraph cache shared by every row.
  final ParagraphCache paragraphs;

  final double _fontSize;
  late final double _thickness;
  late final double _underlineTop;
  late final double _strikeTop;

  final _text = StringBuffer();
  final _cluster = StringBuffer();
  final _paint = Paint();

  // Scan output, reused for every row.
  final _ops = <int>[];
  final _texts = <String>[];
  int _hash = 0;

  static final _paragraphStyle = ui.ParagraphStyle(
    textDirection: TextDirection.ltr,
  );

  static const _noLigatures = [
    FontFeature.disable('liga'),
    FontFeature.disable('calt'),
  ];

  /// Scans [row] with [colors]; [selection] fills the selected cells.
  ///
  /// The result is kept in this recorder until the next scan: compare it
  /// with [scanMatches], and [takeScan] it to keep or record it.
  void scan(RenderRow row, RenderColors colors, Color selection) {
    _ops.clear();
    _texts.clear();
    _hash = row.length;
    _scanBackgrounds(row, colors);
    final start = row.selectionStart;
    final end = row.selectionEnd;
    if (start != null && end != null) {
      _op4(_opSelection, start, end + 1 - start, selection.toARGB32());
    }
    _scanText(row, colors);
  }

  /// Whether the last [scan] equals [content].
  bool scanMatches(RowContent content) {
    if (content._hash != _hash ||
        content._ops.length != _ops.length ||
        content._texts.length != _texts.length) {
      return false;
    }
    final ops = content._ops;
    for (var i = 0; i < ops.length; i++) {
      if (ops[i] != _ops[i]) return false;
    }
    final texts = content._texts;
    for (var i = 0; i < texts.length; i++) {
      if (texts[i] != _texts[i]) return false;
    }
    return true;
  }

  /// A copy of the last [scan].
  RowContent takeScan() =>
      RowContent._(Uint32List.fromList(_ops), List.unmodifiable(_texts), _hash);

  /// Records [content] into a picture.
  ui.Picture record(RowContent content) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final ops = content._ops;
    final texts = content._texts;
    for (var i = 0; i < ops.length;) {
      switch (ops[i]) {
        case _opBackground || _opSelection:
          _paint.color = Color(ops[i + 3]);
          canvas.drawRect(_cells(ops[i + 1], ops[i + 2]), _paint);
          i += 4;
        case _opRun:
          _drawRun(
            canvas,
            texts[ops[i + 2]],
            ops[i + 1],
            ops[i + 3],
            ops[i + 4],
          );
          i += 5;
        case _opCluster:
          _drawCluster(
            canvas,
            (texts[ops[i + 2]], ops[i + 3], ops[i + 4]),
            ops[i + 1],
            ops[i + 5],
          );
          i += 6;
        default:
          _paintDecorations(
            canvas,
            ops[i + 1],
            ops[i + 2],
            ops[i + 3],
            Color(ops[i + 4]),
            Color(ops[i + 5]),
          );
          i += 6;
      }
    }
    return recorder.endRecording();
  }

  /// A copy of cell [x] of [row] for the cursor overlay. [x] is the first
  /// column of a wide character, never its spacer.
  CursorCell readCell(RenderRow row, int x, RenderColors colors) {
    final width = row.widthAt(x);
    final style = row.styleAt(x);
    final background = _cellBackground(row, x, style, colors);
    final span = width == CellWidth.wide ? 2 : 1;
    if (width.isSpacer || style.invisible || !row.hasTextAt(x)) {
      return CursorCell(text: '', span: span, background: background, faces: 0);
    }
    _cluster.clear();
    row.writeTextTo(x, _cluster);
    final single = !row.hasGraphemeAt(x) && span == 1;
    return CursorCell(
      text: _cluster.toString(),
      span: span,
      background: background,
      faces:
          _faces(style) |
          (single && isGridSafe(row.codepointAt(x)) ? 0 : TextFace.cluster),
    );
  }

  /// Draws [cell]'s glyph in [color] with its cell's top-left at [origin]
  /// (the block cursor's inverted glyph).
  void paintCellText(
    Canvas canvas,
    CursorCell cell,
    Offset origin,
    Color color,
  ) {
    if (cell.text.isEmpty) return;
    canvas
      ..save()
      ..translate(origin.dx, origin.dy);
    if (cell.faces & TextFace.cluster != 0) {
      _drawCluster(
        canvas,
        (cell.text, color.toARGB32(), cell.faces),
        0,
        cell.span,
      );
    } else {
      _drawRun(canvas, cell.text, 0, color.toARGB32(), cell.faces);
    }
    canvas.restore();
  }

  void _op(int value) {
    _ops.add(value);
    _hash = (_hash * 31 + value) & 0x3FFFFFFF;
  }

  void _op4(int op, int a, int b, int c) {
    _op(op);
    _op(a);
    _op(b);
    _op(c);
  }

  int _addText(String text) {
    _texts.add(text);
    _hash = (_hash * 31 + text.hashCode) & 0x3FFFFFFF;
    return _texts.length - 1;
  }

  // Backgrounds: equal neighbouring colours merge into one rectangle; the
  // default background is not drawn (the view fills it once).
  void _scanBackgrounds(RenderRow row, RenderColors colors) {
    final length = row.length;
    var spanStart = 0;
    var spanColor = 0; // 0: default background, nothing to draw
    for (var x = 0; x <= length; x++) {
      var color = 0;
      if (x < length) {
        final style = row.styleAt(x);
        if (style.inverse) {
          color = _argb(colors.resolve(style.foreground) ?? colors.foreground);
        } else {
          final rgb = colors.resolve(row.backgroundAt(x));
          if (rgb != null) color = _argb(rgb);
        }
      }
      if (x == length || color != spanColor) {
        if (spanColor != 0 && x > spanStart) {
          _op4(_opBackground, spanStart, x - spanStart, spanColor);
        }
        spanStart = x;
        spanColor = color;
      }
    }
  }

  void _scanText(RenderRow row, RenderColors colors) {
    final length = row.length;
    var x = 0;
    while (x < length) {
      final end = row.styleRunEnd(x);
      final style = row.styleAt(x);
      if (!style.invisible) {
        final foreground = _foreground(style, colors);
        final color = foreground.toARGB32();
        final faces = _faces(style);
        _text.clear();
        var segment = -1;
        void flush() {
          if (segment >= 0) _flushRun(segment, color, faces);
          segment = -1;
          _text.clear();
        }

        for (var i = x; i < end; i++) {
          final width = row.widthAt(i);
          if (width.isSpacer) {
            flush();
            continue;
          }
          final codepoint = row.codepointAt(i);
          if (width == CellWidth.wide ||
              row.hasGraphemeAt(i) ||
              (codepoint != 0 && !isGridSafe(codepoint))) {
            flush();
            _cluster.clear();
            row.writeTextTo(i, _cluster);
            if (_cluster.isNotEmpty) {
              _op(_opCluster);
              _op(i);
              _op(_addText(_cluster.toString()));
              _op(color);
              _op(faces | TextFace.cluster);
              _op(width == CellWidth.wide ? 2 : 1);
            }
            continue;
          }
          if (segment < 0) segment = i;
          _text.writeCharCode(codepoint == 0 ? 0x20 : codepoint);
        }
        flush();
        _scanDecorations(style, colors, color, x, end);
      }
      x = end;
    }
  }

  // A run of grid-safe cells starting at column [start]; one UTF-16 code
  // unit per cell (every grid-safe codepoint is in the BMP).
  void _flushRun(int start, int color, int faces) {
    final text = _text.toString();
    var first = 0;
    var last = text.length;
    while (first < last && text.codeUnitAt(first) == 0x20) {
      first++;
    }
    while (last > first && text.codeUnitAt(last - 1) == 0x20) {
      last--;
    }
    if (first == last) return;
    final trimmed = first == 0 && last == text.length
        ? text
        : text.substring(first, last);
    _op(_opRun);
    _op(start + first);
    _op(_addText(trimmed));
    _op(color);
    _op(faces);
  }

  void _scanDecorations(
    CellStyle style,
    RenderColors colors,
    int color,
    int start,
    int end,
  ) {
    final underline = style.underline;
    var bits = underline == UnderlineStyle.unknown
        ? UnderlineStyle.single.index
        : underline.index;
    if (style.strikethrough) bits |= _decoStrike;
    if (style.overline) bits |= _decoOverline;
    if (bits == 0) return;
    final underlineColor =
        underline == UnderlineStyle.none || style.underlineColor is DefaultColor
        ? color
        : _withFaint(
            _color(colors.resolve(style.underlineColor) ?? colors.foreground),
            style,
          ).toARGB32();
    _op(_opDecoration);
    _op(start);
    _op(end);
    _op(bits);
    _op(underlineColor);
    _op(color);
  }

  void _drawRun(Canvas canvas, String text, int col, int color, int faces) {
    final key = (text, color, faces);
    final cached = paragraphs.get(key, () => _build(key));
    if (!cached.onGrid) {
      // A glyph of this run advances by something else than one cell:
      // place every cell on its own.
      for (var i = 0; i < text.length; i++) {
        final unit = text.codeUnitAt(i);
        if (unit == 0x20) continue;
        _drawCluster(
          canvas,
          (String.fromCharCode(unit), color, faces | TextFace.cluster),
          col + i,
          1,
        );
      }
      return;
    }
    final paragraph = cached.paragraph;
    canvas.drawParagraph(
      paragraph,
      Offset(
        col * metrics.width,
        metrics.baseline - paragraph.alphabeticBaseline,
      ),
    );
  }

  void _drawCluster(Canvas canvas, ParagraphKey key, int col, int span) {
    final paragraph = paragraphs.get(key, () => _build(key)).paragraph;
    final box = span * metrics.width;
    final advance = paragraph.maxIntrinsicWidth;
    final left = col * metrics.width;
    final top = metrics.baseline - paragraph.alphabeticBaseline;
    if (advance > 0 && _stretches(key.$1)) {
      // Box drawing and block elements join their neighbours: stretch them
      // to the cell exactly instead of centring them, so no seam shows.
      canvas
        ..save()
        ..translate(left, 0)
        ..scale(box / advance, 1)
        ..drawParagraph(paragraph, Offset(0, top))
        ..restore();
      return;
    }
    if (advance <= box) {
      canvas.drawParagraph(paragraph, Offset(left + (box - advance) / 2, top));
      return;
    }
    // Wider than its cells (an emoji or a fallback glyph): scale it down
    // around the baseline so it never covers the next cell.
    final scale = box / advance;
    canvas
      ..save()
      ..translate(left, metrics.baseline)
      ..scale(scale)
      ..drawParagraph(paragraph, Offset(0, -paragraph.alphabeticBaseline))
      ..restore();
  }

  CachedParagraph _build(ParagraphKey key) {
    final (text, color, faces) = key;
    final base = textStyle;
    final cluster = faces & TextFace.cluster != 0;
    final style = TextStyle(
      color: Color(color),
      fontFamily: base.fontFamily,
      fontFamilyFallback: base.fontFamilyFallback,
      fontSize: base.fontSize ?? kDefaultFontSize,
      fontWeight: faces & TextFace.bold != 0
          ? FontWeight.bold
          : base.fontWeight,
      fontStyle: faces & TextFace.italic != 0
          ? FontStyle.italic
          : base.fontStyle,
      letterSpacing: cluster ? 0 : metrics.letterSpacing,
      fontFeatures: [...?base.fontFeatures, ..._noLigatures],
      fontVariations: base.fontVariations,
      locale: base.locale,
      textBaseline: TextBaseline.alphabetic,
    );
    final builder = ui.ParagraphBuilder(_paragraphStyle)
      ..pushStyle(style.getTextStyle(textScaler: textScaler))
      ..addText(text);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final onGrid =
        cluster ||
        (paragraph.maxIntrinsicWidth - text.length * metrics.width).abs() *
                metrics.devicePixelRatio <=
            gridTolerancePx;
    return CachedParagraph(paragraph, onGrid: onGrid);
  }

  void _paintDecorations(
    Canvas canvas,
    int start,
    int end,
    int bits,
    Color underline,
    Color foreground,
  ) {
    final left = start * metrics.width;
    final right = end * metrics.width;
    final t = _thickness;
    final underlineStyle = UnderlineStyle.values[bits & 7];
    if (underlineStyle != UnderlineStyle.none) {
      _paint.color = underline;
      _paintUnderline(canvas, underlineStyle, left, right);
    }
    if (bits & _decoStrike != 0) {
      _paint.color = foreground;
      canvas.drawRect(
        Rect.fromLTRB(left, _strikeTop, right, _strikeTop + t),
        _paint,
      );
    }
    if (bits & _decoOverline != 0) {
      _paint.color = foreground;
      canvas.drawRect(Rect.fromLTRB(left, 0, right, t), _paint);
    }
  }

  void _paintUnderline(
    Canvas canvas,
    UnderlineStyle style,
    double left,
    double right,
  ) {
    final t = _thickness;
    final top = _underlineTop;
    switch (style) {
      case UnderlineStyle.none:
        return;
      case UnderlineStyle.single || UnderlineStyle.unknown:
        canvas.drawRect(Rect.fromLTRB(left, top, right, top + t), _paint);
      case UnderlineStyle.double:
        canvas
          ..drawRect(Rect.fromLTRB(left, top, right, top + t), _paint)
          ..drawRect(
            Rect.fromLTRB(left, top + 2 * t, right, top + 3 * t),
            _paint,
          );
      case UnderlineStyle.dotted:
        // Dots one thickness wide, one thickness apart.
        for (var x = left; x < right; x += 2 * t) {
          canvas.drawRect(
            Rect.fromLTRB(x, top, math.min(x + t, right), top + t),
            _paint,
          );
        }
      case UnderlineStyle.dashed:
        // Dashes half a cell long (at least two thicknesses), as long as
        // their gaps.
        final dash = math.max(2 * t, _snap(metrics.width / 2));
        for (var x = left; x < right; x += 2 * dash) {
          canvas.drawRect(
            Rect.fromLTRB(x, top, math.min(x + dash, right), top + t),
            _paint,
          );
        }
      case UnderlineStyle.curly:
        // One wave period per cell, a quadratic arc every half period,
        // peaking one thickness above and below the line's middle; clipped
        // to the space a double underline takes.
        final middle = top + 1.5 * t;
        final path = Path()..moveTo(left, middle);
        final half = metrics.width / 2;
        for (var x = left; x < right; x += half) {
          final next = math.min(x + half, right);
          final up = ((x - left) / half).round().isEven;
          path.quadraticBezierTo(
            (x + next) / 2,
            middle + (up ? -2 * t : 2 * t),
            next,
            middle,
          );
        }
        final stroke = Paint()
          ..color = _paint.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = t
          ..isAntiAlias = true;
        canvas
          ..save()
          ..clipRect(Rect.fromLTRB(left, top - t, right, top + 4 * t))
          ..drawPath(path, stroke)
          ..restore();
    }
  }

  Rect _cells(int col, int count) => Rect.fromLTWH(
    col * metrics.width,
    0,
    count * metrics.width,
    metrics.height,
  );

  Color _foreground(CellStyle style, RenderColors colors) {
    final rgb = style.inverse
        ? colors.resolve(style.background) ?? colors.background
        : colors.resolve(style.foreground) ?? colors.foreground;
    return _withFaint(_color(rgb), style);
  }

  Color _cellBackground(
    RenderRow row,
    int x,
    CellStyle style,
    RenderColors colors,
  ) => _color(
    style.inverse
        ? colors.resolve(style.foreground) ?? colors.foreground
        : colors.resolve(row.backgroundAt(x)) ?? colors.background,
  );

  static Color _withFaint(Color color, CellStyle style) =>
      style.faint ? color.withAlpha(faintAlpha) : color;

  static int _faces(CellStyle style) =>
      (style.bold ? TextFace.bold : 0) | (style.italic ? TextFace.italic : 0);

  double _snap(double logical) =>
      (logical * metrics.devicePixelRatio).round() / metrics.devicePixelRatio;

  /// Whether [codepoint] can sit in a letter-spaced run: printable ASCII,
  /// Latin-1, Latin Extended-A/B, Greek and Cyrillic, which monospace fonts
  /// cover at the grid advance, except U+00AD SOFT HYPHEN (a format
  /// character: libghostty-vt gives it a cell, text layout a zero advance)
  /// and the Cyrillic combining marks U+0483-0489. Anything else may come
  /// from a fallback font with another advance. A run that still does not
  /// measure its cells is drawn cell by cell (see the class docs).
  static bool isGridSafe(int codepoint) =>
      (codepoint >= 0x20 && codepoint < 0x7F) ||
      (codepoint >= 0xA0 && codepoint < 0x250 && codepoint != 0xAD) ||
      (codepoint >= 0x370 &&
          codepoint < 0x530 &&
          (codepoint < 0x483 || codepoint > 0x489));

  /// Whether [text] is one box-drawing or block-element character
  /// (U+2500-259F), which is stretched to fill its cell.
  static bool _stretches(String text) {
    if (text.length != 1) return false;
    final unit = text.codeUnitAt(0);
    return unit >= 0x2500 && unit < 0x25A0;
  }

  static int _argb(RgbColor rgb) => colorOfRgb(rgb).toARGB32();

  static Color _color(RgbColor rgb) => colorOfRgb(rgb);
}

/// The opaque [Color] of [rgb]. Never exported.
Color colorOfRgb(RgbColor rgb) => Color(0xFF000000 | rgb.value);
