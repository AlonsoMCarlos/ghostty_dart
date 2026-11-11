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
  colour) is rasterised once into atlas pages, whose images grow by slot
  rows as glyphs arrive, and every row is drawn with
  `Canvas.drawRawAtlas`, without laying out text. The atlas counts in the
  view's cache budget and is released with the other caches.
  `VtTerminalView.textRendering` (`VtTextRendering.atlas` or
  `VtTextRendering.paragraphs`) opts out, for exact paragraph shaping.
- `VtTerminalView.cacheBudget` (default `VtTerminalView.defaultCacheBudget`,
  16 MiB) bounds the view's rendering caches: row pictures, atlas images
  and laid-out text share it, laid-out text taking at most a quarter.
  Atlas-path row pictures are counted by their display list, so a
  heavily coloured 200 × 60 view keeps about 1,000 rows cached by default.
- Hooks for apps and adapters, all optional: `VtTerminalView.onTerminalKey`
  and `onTerminalText` replace what a key or committed text sends,
  `mouseReportFilter` decides which presses, wheel steps and motion are
  reported to a program that tracks the mouse, and `onTerminalMouse`
  replaces the encoding of a report. `wordBoundaryCodepoints` sets the
  characters that end double-click words, `rectangleSelection` makes a
  plain drag select a block, and the view answers `SelectAllTextIntent`
  (no default shortcut). `VtTerminalViewState` gained `cursorRect`,
  `globalCursorRect` and `hasInputConnection`.
- `VtTerminalController.addHighlight` paints coloured ranges over the text
  (search results, for example) that follow their text as output scrolls;
  `VtTerminalHighlight.dispose` removes one. They are drawn as an overlay,
  so they never record rows again.
