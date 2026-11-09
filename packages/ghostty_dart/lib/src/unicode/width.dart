/// Terminal display width of codepoints and grapheme clusters
/// (`unicode.h`).
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../core/internal.dart';
import '../ffi/bindings.g.dart';

/// The terminal display width of one Unicode [codepoint], in cells: 0, 1 or
/// 2.
///
/// Uses the same width table the terminal uses to lay out printed text:
///
/// - 0 for C0/C1 controls, combining marks, default-ignorable codepoints
///   (ZWJ, variation selectors, ...) and surrogates;
/// - 2 for East Asian Wide/Fullwidth codepoints (including emoji with
///   default emoji presentation) and regional indicators;
/// - 1 for everything else, including values beyond U+10FFFF.
///
/// This cannot see grapheme-cluster rules (VS16, ZWJ sequences, skin tones).
/// Summing it over a string only predicts the layout when grapheme
/// clustering (mode 2027) is off; otherwise use [textCellWidth] or
/// [graphemeClusters].
///
/// ```dart
/// codepointCellWidth(0x1F600); // 2 (😀)
/// ```
///
/// Throws [RangeError] if [codepoint] does not fit in 32 bits unsigned.
int codepointCellWidth(int codepoint) {
  ensureCompatibleLibrary();
  RangeError.checkValueInInterval(codepoint, 0, 0xFFFFFFFF, 'codepoint');
  return ghostty_unicode_codepoint_width(codepoint);
}

/// One grapheme cluster of a string, as the terminal segments and measures
/// it with grapheme clustering (mode 2027) on. Returned by
/// [graphemeClusters].
final class GraphemeCluster {
  /// A cluster of [text] that starts at UTF-16 offset [start] of its source
  /// string and occupies [width] cells.
  const GraphemeCluster({
    required this.text,
    required this.start,
    required this.width,
  });

  /// The cluster's text (one or more codepoints).
  final String text;

  /// The UTF-16 code unit offset of the cluster in the measured string, so
  /// `source.substring(start, start + text.length) == text`.
  final int start;

  /// The cluster's display width in cells: 0, 1 or 2.
  final int width;

  @override
  bool operator ==(Object other) =>
      other is GraphemeCluster &&
      other.text == text &&
      other.start == start &&
      other.width == width;

  @override
  int get hashCode => Object.hash(text, start, width);

  @override
  String toString() => 'GraphemeCluster($text, start: $start, width: $width)';
}

/// The display width of [text] in terminal cells.
///
/// With [graphemeClustering] on (the default, matching mode 2027, Ghostty's
/// recommended setting) the text is split into grapheme clusters exactly as
/// the terminal does and each cluster's width is summed: `'👍🏽'` is 2 cells,
/// `'é'` is 1. With it off, the per-codepoint widths of
/// [codepointCellWidth] are summed, which is what the terminal does when
/// mode 2027 is disabled.
///
/// Control characters (C0/C1, CR, LF) are never printed by the terminal's
/// text path; their contribution is unspecified but bounded.
///
/// ```dart
/// textCellWidth('日本語'); // 6
/// ```
int textCellWidth(String text, {bool graphemeClustering = true}) {
  ensureCompatibleLibrary();
  if (!graphemeClustering) {
    var total = 0;
    for (final rune in text.runes) {
      total += ghostty_unicode_codepoint_width(rune);
    }
    return total;
  }
  var total = 0;
  _forEachCluster(Uint32List.fromList(text.runes.toList()), (_, _, width) {
    total += width;
  });
  return total;
}

/// Splits [text] into grapheme clusters the way the terminal does with
/// grapheme clustering (mode 2027) on, and measures each one.
///
/// Use it to predict the layout of text that has not been written to the
/// terminal yet, such as an IME preedit overlay. The clusters cover [text]
/// completely and in order. An empty [text] gives an empty list.
///
/// ```dart
/// graphemeClusters('a👍🏽'); // [a (1 cell), 👍🏽 (2 cells)]
/// ```
List<GraphemeCluster> graphemeClusters(String text) {
  ensureCompatibleLibrary();
  final runes = Uint32List.fromList(text.runes.toList());
  final clusters = <GraphemeCluster>[];
  var offset = 0;
  _forEachCluster(runes, (start, length, width) {
    var units = 0;
    for (var i = start; i < start + length; i++) {
      units += runes[i] > 0xFFFF ? 2 : 1;
    }
    clusters.add(
      GraphemeCluster(
        text: text.substring(offset, offset + units),
        start: offset,
        width: width,
      ),
    );
    offset += units;
  });
  return clusters;
}

/// Measures the first grapheme cluster of [codepoints] starting at [start],
/// with grapheme clustering (mode 2027) on.
///
/// Returns how many codepoints the cluster spans (`length`, at least 1
/// unless no codepoints remain, then 0) and its width in cells (`width`,
/// 0–2). This is not a streaming API: if [codepoints] may still continue, a
/// cluster that reaches the end of the list (`start + length ==
/// codepoints.length`) may be extended by later input.
///
/// Throws [RangeError] if [start] is outside `0..codepoints.length` or a
/// codepoint does not fit in 32 bits unsigned.
({int length, int width}) firstGraphemeCellWidth(
  List<int> codepoints, {
  int start = 0,
}) {
  ensureCompatibleLibrary();
  RangeError.checkValueInInterval(start, 0, codepoints.length, 'start');
  for (var i = start; i < codepoints.length; i++) {
    RangeError.checkValueInInterval(
      codepoints[i],
      0,
      0xFFFFFFFF,
      'codepoints[$i]',
    );
  }
  final tail = Uint32List.fromList(codepoints.sublist(start));
  if (tail.isEmpty) return (length: 0, width: 0);
  return _withCodepoints(tail, (cps, width) {
    final length = ghostty_unicode_grapheme_width(cps, tail.length, width);
    return (length: length, width: width.value);
  });
}

/// Calls [onCluster] with the start index, codepoint count and cell width of
/// each grapheme cluster of [codepoints], in order.
void _forEachCluster(
  Uint32List codepoints,
  void Function(int start, int length, int width) onCluster,
) {
  final count = codepoints.length;
  if (count == 0) return;
  _withCodepoints(codepoints, (cps, width) {
    var index = 0;
    while (index < count) {
      final length = ghostty_unicode_grapheme_width(
        cps + index,
        count - index,
        width,
      );
      onCluster(index, length, width.value);
      index += length;
    }
  });
}

/// Copies [codepoints] to native memory once and runs [action] with them and
/// a `uint8_t` width out-parameter. The out-parameter lives in one extra slot
/// after the codepoints, so a whole walk uses a single pooled block.
R _withCodepoints<R>(
  Uint32List codepoints,
  R Function(Pointer<Uint32> codepoints, Pointer<Uint8> width) action,
) {
  final count = codepoints.length;
  final block = Uint32List(count + 1)..setAll(0, codepoints);
  return withNativeBytes(block.buffer.asUint8List(), (data, _) {
    final cps = data.cast<Uint32>();
    return action(cps, (cps + count).cast<Uint8>());
  });
}
