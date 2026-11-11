## 0.0.1-dev

- Unreleased. `VtTerminalView` renders a `VtTerminalController`'s terminal
  (cached row pictures, cursor overlay, padding, background opacity) and
  takes keyboard (legacy and Kitty encoding, shell-safe shortcuts), IME and
  soft-keyboard text, mouse reports, selection, wheel and touch scrolling,
  and resizes the terminal to fit. While accessibility is on it exposes the
  visible text as a semantics node, with optional announcements of new
  output. `VtTerminalKeyToolbar` adds Esc, Ctrl, Alt, Tab and arrow keys for
  touch screens.
- Grid text is drawn from a glyph atlas by default (ADR 0012): each glyph
  (character, bold and italic faces, one of 16 luminance levels of its
  colour) is rasterised once into fixed-size atlas pages and every row is
  drawn with `Canvas.drawRawAtlas`, without laying out text. The atlas
  counts in the view's cache budget and is released with the other
  caches. `VtTerminalView.textRendering` (`VtTextRendering.atlas` or
  `VtTextRendering.paragraphs`) opts out, for exact paragraph shaping.
