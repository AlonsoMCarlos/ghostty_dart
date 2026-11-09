/// Immutable values read through grid references: one cell and one row.
///
/// Pure Dart (no `dart:ffi`), so a future web backend can reuse them.
library;

import '../core/color.dart';
import '../render/render_enums.dart';
import 'grid_enums.dart';

/// The packed data of one terminal cell (`GhosttyCell`), read with
/// `GridRef.cell`.
///
/// It is a copy: it stays valid after the terminal changes. It holds what
/// the cell itself stores. The cell's full style, its grapheme text and
/// its hyperlink URI live in the terminal's tables and are read through the
/// `GridRef` ([hasStyling], [hasGrapheme] and [hasHyperlink] tell whether
/// they are worth reading).
final class GridCell {
  /// Creates a cell description. Mostly for tests; get real cells from
  /// `GridRef.cell`.
  const GridCell({
    this.codepoint = 0,
    this.hasGrapheme = false,
    this.width = CellWidth.narrow,
    this.hasStyling = false,
    this.hasHyperlink = false,
    this.isProtected = false,
    this.semanticContent = CellSemanticContent.output,
    this.backgroundColor,
  });

  /// The cell's codepoint, or 0 for an empty cell or a colour-only cell.
  ///
  /// For a multi-codepoint grapheme cluster ([hasGrapheme]) this is the
  /// first codepoint; read the whole cluster with `GridRef.codepoints` or
  /// `GridRef.text`.
  final int codepoint;

  /// Whether the cell holds a grapheme cluster of more than one codepoint
  /// (e.g. an emoji with a skin-tone modifier or a ZWJ sequence).
  final bool hasGrapheme;

  /// Whether the cell is narrow, wide or a spacer of a wide character.
  final CellWidth width;

  /// Whether the cell has a non-default style; read it with
  /// `GridRef.style`.
  final bool hasStyling;

  /// Whether the cell is part of an OSC 8 hyperlink; read the URI with
  /// `GridRef.hyperlinkUri`.
  final bool hasHyperlink;

  /// Whether the cell is protected from erasing (DECSCA / SPA).
  final bool isProtected;

  /// The shell content kind of the cell (OSC 133).
  final CellSemanticContent semanticContent;

  /// The colour of a text-less, colour-only cell (a [PaletteColor] or an
  /// [RgbColor]), as left by erasing with a background colour set; `null`
  /// for every other cell, whose background is its style's background.
  ///
  /// `GridRef.background` resolves both cases.
  final ColorRef? backgroundColor;

  /// Whether the cell has text to draw ([codepoint] is not 0).
  bool get hasText => codepoint != 0;

  @override
  bool operator ==(Object other) =>
      other is GridCell &&
      other.codepoint == codepoint &&
      other.hasGrapheme == hasGrapheme &&
      other.width == width &&
      other.hasStyling == hasStyling &&
      other.hasHyperlink == hasHyperlink &&
      other.isProtected == isProtected &&
      other.semanticContent == semanticContent &&
      other.backgroundColor == backgroundColor;

  @override
  int get hashCode => Object.hash(
    codepoint,
    hasGrapheme,
    width,
    hasStyling,
    hasHyperlink,
    isProtected,
    semanticContent,
    backgroundColor,
  );

  @override
  String toString() {
    final text = hasText
        ? 'U+${codepoint.toRadixString(16).toUpperCase().padLeft(4, '0')}'
        : 'empty';
    return 'GridCell($text, $width'
        '${hasGrapheme ? ', grapheme' : ''}'
        '${hasStyling ? ', styled' : ''}'
        '${hasHyperlink ? ', hyperlink' : ''}'
        '${isProtected ? ', protected' : ''}'
        '${semanticContent == CellSemanticContent.output ? '' : ', $semanticContent'}'
        '${backgroundColor == null ? '' : ', background: $backgroundColor'}'
        ')';
  }
}

/// The flags of one terminal row (`GhosttyRow`), read with `GridRef.row`.
///
/// It is a copy: it stays valid after the terminal changes. All fields are
/// read in one native call.
final class GridRow {
  /// Creates a row description. Mostly for tests; get real rows from
  /// `GridRef.row`.
  const GridRow({
    this.isWrapped = false,
    this.isWrapContinuation = false,
    this.hasGraphemes = false,
    this.hasStyling = false,
    this.hasHyperlinks = false,
    this.semanticPrompt = RowSemanticPrompt.none,
    this.hasKittyVirtualPlaceholder = false,
    this.isDirty = false,
  });

  /// Whether the row is soft-wrapped: its text continues on the next row
  /// because it reached the right margin (not because of a newline).
  final bool isWrapped;

  /// Whether the row continues the soft-wrapped row above it.
  final bool isWrapContinuation;

  /// Whether any cell of the row holds a multi-codepoint grapheme cluster.
  final bool hasGraphemes;

  /// Whether any cell of the row may have non-default styling. It can be
  /// `true` for a row whose styled cells were since overwritten (false
  /// positives), never `false` for a styled row.
  final bool hasStyling;

  /// Whether any cell of the row may be part of a hyperlink. Like
  /// [hasStyling], it can have false positives.
  final bool hasHyperlinks;

  /// Whether the row holds a shell prompt (OSC 133).
  final RowSemanticPrompt semanticPrompt;

  /// Whether the row contains a Kitty graphics virtual placeholder
  /// (U+10EEEE).
  final bool hasKittyVirtualPlaceholder;

  /// Whether the row changed since a render state last marked it clean.
  final bool isDirty;

  @override
  bool operator ==(Object other) =>
      other is GridRow &&
      other.isWrapped == isWrapped &&
      other.isWrapContinuation == isWrapContinuation &&
      other.hasGraphemes == hasGraphemes &&
      other.hasStyling == hasStyling &&
      other.hasHyperlinks == hasHyperlinks &&
      other.semanticPrompt == semanticPrompt &&
      other.hasKittyVirtualPlaceholder == hasKittyVirtualPlaceholder &&
      other.isDirty == isDirty;

  @override
  int get hashCode => Object.hash(
    isWrapped,
    isWrapContinuation,
    hasGraphemes,
    hasStyling,
    hasHyperlinks,
    semanticPrompt,
    hasKittyVirtualPlaceholder,
    isDirty,
  );

  @override
  String toString() {
    final flags = [
      if (isWrapped) 'wrapped',
      if (isWrapContinuation) 'wrap continuation',
      if (hasGraphemes) 'graphemes',
      if (hasStyling) 'styled',
      if (hasHyperlinks) 'hyperlinks',
      if (semanticPrompt != RowSemanticPrompt.none) '$semanticPrompt',
      if (hasKittyVirtualPlaceholder) 'kitty placeholder',
      if (isDirty) 'dirty',
    ];
    return 'GridRow(${flags.join(', ')})';
  }
}
