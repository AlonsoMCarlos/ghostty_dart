/// How a `VtTerminalView` draws the text of its grid (ADR 0012).
///
/// Both paths place every glyph on the same device-pixel grid and draw
/// backgrounds, decorations, wide characters, grapheme clusters, emoji
/// and box drawing the same way; they differ only in how narrow grid text
/// becomes pixels.
///
/// ```dart
/// VtTerminalView(
///   controller: controller,
///   textRendering: VtTextRendering.paragraphs, // opt out of the atlas
/// )
/// ```
enum VtTextRendering {
  /// The default: a glyph atlas. Each glyph (character, bold and italic
  /// faces, and one of 16 luminance levels of its colour) is rasterised
  /// once into an atlas image, and a row's text is drawn with one
  /// `Canvas.drawRawAtlas` call, without laying out text. A screen of new
  /// text costs about a fifth of the UI time of [paragraphs] (benchmark
  /// of 2026-11-10, `benchmarks/README.md`).
  ///
  /// Glyphs are drawn one by one, without shaping context, and their
  /// coverage is the platform rasteriser's for the nearest of 16
  /// luminance levels of the cell colour, so a few pixels can differ
  /// slightly from [paragraphs]. Glyphs whose advance is not one cell
  /// (from a fallback font) are laid out as paragraphs, as are wide
  /// characters, grapheme clusters, emoji and box drawing.
  atlas,

  /// Lays out each row's text as one paragraph with a style span per run
  /// (one paragraph per run when the row does not measure its cells).
  ///
  /// Choose it for exact paragraph shaping: fonts whose glyphs change by
  /// context even with ligatures and contextual alternates turned off
  /// (seen with JetBrains Mono's grave accent after a letter), the exact
  /// per-colour coverage of the platform's text rasteriser, a view that is
  /// shown scaled (atlas glyphs are images at the device pixel ratio and
  /// are resampled under a scale transform, while paragraphs are
  /// rasterised at the final scale), or to rule out the atlas while
  /// debugging a rendering difference. Every screen of new text costs a
  /// paragraph layout per changed row.
  paragraphs,
}
