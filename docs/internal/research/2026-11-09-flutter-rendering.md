# R1: Rendering research for `ghostty_dart_flutter`

Date: 2026-11-09. Every source was read that day unless another date is given.

- **[V]** means verified at the source: local SDK or pub-cache files, GitHub source, or official docs.
- **[I]** means inferred or estimated. It must be measured or checked before anyone relies on it.

Local sources:

- Flutter SDK at `~/.local/share/mise/installs/flutter/3.47.9`. `bin/cache/flutter.version.json` gives framework `c197ca51…` (2026-10-29), engine `89c39edf…` (2026-10-27) and Dart 3.13.7.
- `F/` below is short for that SDK root.
- `ui/` is short for `F/bin/cache/pkg/sky_engine/lib/ui/`.
- `web/` is short for `F/bin/cache/flutter_web_sdk/lib/`.

---

## 0. What `ghostty_dart` gives the renderer (read from `packages/ghostty_dart/lib/src`)

All **[V]**.

### Frame loop (`RenderState`)

Source: `render/render_state.dart`.

- Calls: `update(terminal)`, then `dirty` (`clean` / `partial` / `full` / `unknown`, where `unknown` is treated as full), then `dirtyRows` (or `allRows`), then `markClean()`.
- Dirty flags only rise between `markClean()` calls, so a frame that is skipped is not lost.
- There is also `beginUpdate`/`endUpdate` for the case where a lock is shared with an I/O thread.
- Scalars:
  - `cols`, `rows`;
  - `cursor`: `RenderCursor`, the same instance when unchanged, so `identical` works as a cheap change test;
  - `colors`: `RenderColors`, also the same instance when unchanged;
  - `overscan` / `overscanRequest`, which gives extra rows above and below the viewport for smooth scrolling.

### `RenderRow`

Source: `render/render_row.dart`.

- **One reused, borrowed object.** It throws once the iteration moves on.
- Fields:
  - `viewportY`, `length`, `isDirty` (settable);
  - `id`: a `RenderRowId` that is stable while the row scrolls. **Key per-row caches by it.**
  - `selectionStart`/`selectionEnd` (inclusive columns, or null);
  - per-cell `codepointAt`, `hasGraphemeAt`, `widthAt`, `styleAt`, `backgroundAt`/`backgroundRgbAt`/`foregroundRgbAt`, `hasHyperlinkAt`, `writeTextTo(x, sink)`;
  - `styleRunEnd(start)`: pure Dart, compares style ids.
- The packed cells come over in the same native call that moves to the row, so per-cell reads never call native code.
- `styleAt` costs one native read per distinct style per row.
- `CellStyle` instances are shared across rows and frames, so `identical` works as a cheap comparison.

### `CellWidth`

Source: `render/render_enums.dart`. Values: `narrow`, `wide` (draw across 2 cells), `spacerTail` and `spacerHead` (skip both), and `unknown` (draw as narrow).

### `CellStyle`

Source: `core/style.dart`.

- Colours: `foreground`, `background`, `underlineColor` (`DefaultColor` means "same as fg").
- Flags: `bold`, `italic`, `faint`, `blink`, `inverse`, `invisible`, `strikethrough`, `overline`.
- `underline`: `UnderlineStyle.none | single | double | curly | dotted | dashed | unknown`, where `unknown` is drawn as single.
- **Inverse and bold-as-bright are not applied by the library.** The renderer does it.

### `RenderColors`

- Fields: `background`, `foreground`, `cursor?` (null means the renderer picks), `palette` (256 entries).
- `resolve(ColorRef)` returns `RgbColor?`, where null means the default colour.

### `RenderCursor`

- Fields: `style` (DECSCUSR), `isVisible`, `isBlinking`, `isPasswordInput`, `position?` (null when the cursor is outside the viewport), `isOnWideTail` (then draw at `x - 1`, 2 cells wide).

### Terminal-side colour defaults (theming)

Source: `terminal/terminal.dart:529-572`.

- `colorForegroundDefault`, `colorBackgroundDefault`, `colorCursorDefault`, `colorPaletteDefault`.
- With these, OSC 10/11/4 *queries* answer with the theme, and the render state reports theme colours.
- Related helpers:
  - `defaultColorPalette` and a Ghostty-style 256-colour generator from a 16-colour theme (`color/color_palette.dart`);
  - `onColorSchemeQuery` (`terminal/effects.dart:165`).

### Synchronized output and scrolling

- Synchronized output: `onRenderHold(bool held)` (`terminal/effects.dart:229`), plus `TerminalMode.synchronizedOutput` (DEC 2026).
- Scrollbar: `terminal.scrollbar` (`ViewportScrollbar`) and `scrollViewport(ViewportScroll…)`.
- `terminal.resize(cols, rows, cellWidthPx:, cellHeightPx:)`. The pixel cell size feeds Kitty placements, pixel mouse reports and size reports, so the widget must pass its measured cell size.

### Images

Sources: `render_values.dart`, `kitty/kitty_graphics.dart`, `sys/system.dart`.

- `RenderState.imagePlacementsGeneration` and `imagePlacements()`.
- Each placement has `layer` (`belowBackground` / `belowText` / `aboveText`), `z`, `viewportCol/Row`, `gridCols/Rows`, `cellOffsetX/Y`, `pixelWidth/Height` and a source rect.
- `terminal.kittyImagePixels(id)` returns decoded `rgb`/`rgba`/`gray`/`grayAlpha` bytes.
- `KittyImage.generation`.
- `tickKittyAnimations(nowMs)`.
- **PNG needs `setVtPngDecoder`, a *synchronous* `Uint8List -> RgbaImage?` callback that runs inside `vt_write`.**

---

## 1. How existing Flutter terminals render

### 1.1 xterm 4.0.0 (`~/.pub-cache/hosted/pub.dev/xterm-4.0.0/lib/src/ui/`, released 2024-02-27)

All **[V]** from the source.

**Widget and render object**
- `RenderTerminal` (`render.dart`) is a single `RenderBox` with `isRepaintBoundary = true`.
- `paint()` calls `context.setWillChangeHint()`.
- **Every terminal change calls `markNeedsLayout()`** (`_onTerminalChange`, line 166), so each `write` costs a relayout *and* a full repaint.
- There is no dirty tracking at all.

**Per frame** (`_paint`, lines 401-457)
- Compute the first and last visible line from the scroll offset.
- For each visible line, `painter.paintLine()`, which works **per cell**:
  - `paintCellBackground` does a `drawRect` with a new `Paint()` per cell that has a non-default background.
  - `paintCellForeground` does a `drawParagraph` **of one character**.
- Then the cursor, highlights and selection are painted as rect overlays. Selection is drawn *on top* as a translucent rect, not by changing the cell colours.

**Cache** (`paragraph_cache.dart`)
- `quiver` `LruMap<int, Paragraph>(10240)`.
- Key: `cellData.getHash() ^ textScaler.hashCode`, so it is per (char, colours, flags).
- On eviction it does **not** dispose the paragraphs, which leaves the GC to free native memory.
- The cache is cleared on a text style, scaler or theme change.

**Cell size** (`_measureCharSize`)
- Lay out `'mmmmmmmmmm'`, then `maxIntrinsicWidth / 10` and `paragraph.height`.
- No pixel snapping.
- Defaults (`terminal_text_style.dart`): font size 13, height 1.2, family `'monospace'` with a long fallback list (Menlo, Consolas, Noto CJK, Noto Color Emoji, …).

**Decorations and attributes**
- Only a single underline, through `TextDecoration.underline`.
- Spaces are swapped for U+00A0 so the underline is drawn.
- Faint is `withOpacity(0.5)`.
- Inverse swaps fg/bg.
- No curly, dotted, dashed or double underline, no strikethrough, no blink.
- Wide characters skip `i++`. Cursor shapes are block, underline and bar; an unfocused cursor is an outlined rect.

**Known problems** (GitHub issues, read 2026-11-09)
- #73 (2021-10-26, open) "Stuttering using interactive commands", on a 1920×1080 grid with vim/top.
- #191 "input lags" (2024-02-29).
- #198 (2024-07-02, open) "Text weirdly spaced on Web" and #42 (2021-07-09). The `monospace` family does not exist on CanvasKit, so text falls back to a proportional font. The workaround is to bundle a font.
- A 2026 comment on #198 says the bundled-font workaround still fails with the **wasm** build.
- #165 (2023-03-09, open) cursor underline/bar drawn wrongly. In the source, `paintCursor` draws the underline at `y = cellHeight - 1` without the row offset.
- #211 (2025-11-06) is a ligatures PR.

### 1.2 xterm2 5.4.0 (`~/.pub-cache/hosted/pub.dev/xterm2-5.4.0/lib/src/ui/`, released 2026-10-21)

All **[V]**.

**Still per-cell `drawParagraph`**, with these improvements:
- **Background run merging.** `paintLineBackgrounds` merges neighbouring cells of equal colour into one `drawRect`.
- **ASCII fast path.** A plain printable ASCII cell with default colours and no flags is cached by its codepoint alone (`painter.dart:493-509`).
- **Proper LRU.** `LinkedList` recency, a default size of 2048, and `Paragraph.dispose()` on eviction and on clear (`paragraph_cache.dart`).
- **Procedural box-drawing and block glyphs** (`procedural_glyphs.dart`, 2322 lines; changelog 5.0.0: "without font seams").
- **Decorations.**
  - `TextDecorationStyle.wavy`, `dotted` and `dashed` for those underline styles.
  - Double underline and underline colour painted by hand (`_paintDoubleUnderline`).
  - `glyphConstraintCellSpan` lets wide symbols use the blank cells next to them (5.3.0).
- **Cursor and text blink** use `Timer.periodic`. Cursor blink stops after 5 s idle.
- **Cell size** is the **max** advance and height over U+0021–U+007E, each laid out separately.
- **Repaint** still goes through `markNeedsLayout` / `markNeedsPaint` on terminal change. No dirty rows.
- 5.1.0 changelog: "Reduce parser, resize, repaint, and paragraph-cache overhead under sustained output". 5.4.0: "Reduce paragraph cache churn when rendering log output".

### 1.3 flterm (github.com/elias8/libghostty, `packages/flterm`, HEAD `a52afc40` on 2026-11-04)

All **[V]**. The source was read as text through the GitHub API and raw URLs; nothing was downloaded into the project or compiled.

**Glyph atlas and `drawRawAtlas`**
- `rendering/atlas/*`, with lanes: `text_lane`, `emoji_lane`, `sprite_lane` (procedural box, braille, powerline), `decoration_lane` and `paragraph_lane`.
- The atlas is built by recording pictures and calling `Picture.toImageSync(w, h)` (`atlas_texture.dart:114-133`), with a gap between slots "to prevent sub-pixel bleed".
- Atlases come from an `atlas_pool.dart` keyed by `AtlasConfig` (font size, family, weight, fallback, metrics, DPR), and admission is limited by `atlas_budget.dart`.

**Per-row sprite slots** (`sprite_buffer.dart:180-290`)
- Each row owns a fixed slot range. Dirty rows rewrite their slots; clean rows cost nothing.
- `seal()` packs the active slots incrementally from the first dirty row.
- Painting is a few `drawRawAtlas` calls (transforms, rects, colours, `BlendMode.modulate` for tint).
- Its comment: *"Skia does not reliably cull scale-0 RSTransforms, so leaving them in the submission corrupts output"*. That is a real gotcha.
- Emoji are drawn untinted, as "direct" glyphs.

**Per-row decoded cache** (`frame_row_cache.dart`): it copies codepoints, style ids, backgrounds and flags into typed arrays per row.

**Cell metrics** (`font/measure_cell_metrics.dart`)
- Width is the advance of `'M'`; height is the full line height of `'Mgj'`.
- **Both are ceiled to the device-pixel grid**, and the baseline is centred.
- Underline and strikethrough position and thickness are parsed from the font's `post` and `OS/2` tables (`font_table_metrics.dart`), with heuristics as fallback. This needs the raw font bytes (`font_data_resolver_io/web`).

**Synchronized output** (`terminal_surface.dart:220-330`): during a render hold it records a `Picture` of the last frame and replays it with `drawPicture`.

**Kitty graphics**: `kitty_image_cache.dart`, `kitty_placement_cache.dart`, `kitty_png_decoder.dart`.

**Fonts**
- Bundled in the example and test fixtures: JetBrains Mono Regular/Bold, Noto Sans JP, Noto Emoji, Noto Color Emoji (plus a Windows subset) and a Symbols Nerd Font subset.
- `test/input/goldens` exists.

**Benchmarks** (`tool/benchmarks/README.md`, `.github/workflows/benchmark-flterm.yml`)
- `flutter drive --profile` on `macos-15`, measuring UI and raster frame times.
- Grid 120×80, fixed metrics, DPR 1.
- Scenarios:
  - clean frame (300 frames);
  - partial update of 3 rows (300);
  - full-screen styled output (300);
  - new glyphs (120 frames of fresh CJK, bold, combining and emoji);
  - first frame (at least 30 fresh instances).
- At least 95% of the samples must be present. **No numbers are published.**

**Issues** (`gh issue list`, 2026-11-09): no rendering-performance issues are filed. The rendering-related ones:
- #26 "render unsupported unicode glyphs via sprite font" (2026-04-11);
- #74 (Firefox double key input);
- #114 (Windows `viewId` text input).

### 1.4 Takeaways

**[I]**, from the evidence above:

- Per-cell `drawParagraph` (xterm, xterm2) costs the UI thread O(cells) per frame. With no dirty tracking that is O(visible cells) on *every* write: a 200×60 grid means 12k paragraph draws per frame.
- flterm went straight to a full `drawRawAtlas` atlas. It is fast, but costs a lot of code: atlas lifetime and budget, DPR keys, `toImageSync`, packing, emoji lanes, and font table parsing.
- AGENTS.md sets the order: runs first, atlas later with benchmark evidence. That matches the evidence, and flterm gives a reference design for the v2 atlas.

---

## 2. Best approach in Nov 2026

### 2.1 What the Flutter 3.47.9 engine actually offers

All **[V]**, from `ui/painting.dart` and `ui/text.dart`.

**Canvas `draw*`**
- Available: `drawColor`, `drawLine`, `drawPaint`, `drawRect`, `drawRRect`, `drawDRRect`, `drawRSuperellipse`, `drawOval`, `drawCircle`, `drawArc`, `drawPath`, `drawImage`, `drawImageRect`, `drawImageNine`, `drawPicture`, `drawParagraph`, `drawPoints`, `drawRawPoints`, `drawVertices`, `drawAtlas`, `drawRawAtlas` (`painting.dart:7683`) and `drawShadow`.
- **There is no `Canvas.drawGlyphs`, `TextBlob` or glyph-run API** (grep for `drawGlyph|GlyphRun|TextBlob` in `ui/` finds nothing). Glyph-level drawing goes through `drawParagraph` or an atlas only.

**Text APIs**
- `Paragraph.getGlyphInfoAt` and `getClosestGlyphInfoForOffset` (`text.dart:3109-3114`); `computeLineMetrics`.
- `FontFeature.disable(String)` (`text.dart:223`).
- `TextLeadingDistribution.even`; `StrutStyle(forceStrutHeight:)`.
- `TextStyle.letterSpacing`.
- `TextDecorationStyle { solid, double, dotted, dashed, wavy }` (`text.dart:1415-1427`).

**Images and pictures**
- `Picture.toImageSync` (`painting.dart:8479`).
- `decodeImageFromPixels` is async: `ImmutableBuffer` → `ImageDescriptor.raw` → codec (`painting.dart:2690`).
- **`decodeImageFromPixelsSync`** (`painting.dart:2755`) exists natively, but on web it **throws `UnimplementedError('… not implemented for web targets.')`** (`web/ui/painting.dart:909`).
- `PixelFormat { rgba8888, bgra8888, rgbaFloat32, rFloat32 }`: there is **no RGB or gray format**, so RGB and gray Kitty images must be expanded to RGBA in Dart.

**Web**
- The engine has `canvaskit/` and `skwasm/` and **no HTML renderer** (directory listing of `web/_engine/engine/`).
- Both implement `drawRawAtlas` (`canvaskit/canvas.dart`, `skwasm/skwasm_impl/canvas.dart`).
- There is a new experimental `web_paragraph/` text stack (Canvas2D-based; its comments mention open Skwasm work). Treat it as unstable **[I]**.
- **Missing glyphs on web are fetched from `https://fonts.gstatic.com/s/` by default** (`configuration.dart:363-365`, `fontFallbackBaseUrl`). This matters for privacy and offline use, and the README should mention it. Apps can override it in the engine configuration.

### 2.2 Impeller vs Skia vs web

From https://docs.flutter.dev/perf/impeller (updated 2026-08-21, covers 3.47), **[V]**:

| Platform | Default renderer | Can opt out? |
|---|---|---|
| iOS | Impeller (the only renderer) | No |
| Android API 29+ | Impeller | Yes; falls back to OpenGL on older or non-Vulkan devices |
| macOS, Linux, Windows | Impeller, *as of 3.47* | Yes, "for now" (to be removed) |
| Web | Skia (CanvasKit/skwasm) | – |

- **So Impeller is now the main native target, and Skia matters mostly for web and the remaining opt-outs.**
- **[V]** Impeller has **no raster cache**: `GPUSurfaceGLImpeller::EnableRasterCache()` and `GPUSurfaceVulkanImpeller::EnableRasterCache()` return `false` (`F/engine/src/flutter/shell/gpu/gpu_surface_*_impeller.cc`), and the rasterizer then sets `ignore_raster_cache = true` (`shell/common/rasterizer.cc:805`). Metal was not checked, but it is assumed to be the same.
  - Consequence: a `RepaintBoundary` per row saves *UI-thread* re-recording only; every layer is re-rasterized each frame.
- **[V]** `Canvas.drawPicture` records a single `DrawDisplayListOp` that references the child display list (`display_list/dl_builder.cc:1760-1792`).
  - So caching a `Picture` per row and replaying it is cheap on the UI thread.
  - The raster thread still replays every op every frame.
- **[V]** Impeller draws text from its own glyph atlas, which has a history of per-pass churn: https://github.com/flutter/flutter/issues/116815 ("glyph atlases … created per render pass … the main bottleneck in text-heavy apps"), plus later caching work (engine PR #56798 "cache even more text frame data").
  - **[I]** So the raster cost of `drawParagraph` text on Impeller is roughly per-glyph quads from an atlas already. A Dart-side atlas mostly saves *UI-thread* shaping and paragraph objects, not raster time. This needs measuring.
- **[I]** Text shaping and layout (SkParagraph) runs on the UI thread on every backend. Laying out a paragraph is the expensive part, which is why caching matters. Drawing a cached paragraph is cheap.
- Gotchas:
  - **[V]** flterm's comment that Skia does not cull scale-0 RSTransforms in `drawRawAtlas`. Submit only live sprites.
  - **[V]** xterm issues #42 and #198: on web, never rely on `'monospace'`. Bundle and load a font.
  - **[I]** Fractional cell origins cause seams between background rects and blurry glyph edges. Snap row and cell origins to device pixels.

### 2.3 Options for drawing text

| Approach | UI cost per dirty row | Raster | Complexity | Verdict |
|---|---|---|---|---|
| `TextPainter` | like a paragraph, plus framework overhead (spans, `TextPainter` objects) | same | low | No: unnecessary overhead; use `dart:ui` `ParagraphBuilder` directly |
| `ParagraphBuilder` per **cell** (xterm) | O(cols) draws, cache lookups per cell | per-glyph | low | No: this is the baseline we beat |
| `ParagraphBuilder` per **style run** with an LRU cache | O(runs); layout only on a cache miss | per-glyph via the engine atlas | medium | **v1** (AGENTS.md) |
| Dart glyph atlas + `drawRawAtlas` (flterm) | O(cells) typed-array writes, no shaping after warm-up | 1–few draw calls | high (atlas lifetime, DPR, budget, emoji, `toImageSync`) | **v2, only with benchmark evidence** |
| `Canvas.drawGlyphs` | – | – | – | Does not exist in 3.47.9 **[V]** |

### 2.4 Dirty-row strategy

- **Per-row `RepaintBoundary` / layers.** Every row becomes its own layer and adds layer-tree overhead. On Impeller there is no raster benefit, because there is no raster cache **[V]**. Rejected.
- **A single `CustomPainter` or `RenderBox` that repaints everything from cached data.** Simple, but it still rebuilds the whole display list each frame (O(runs) draw calls even when clean).
- **Recommended [I]: a single `RenderBox` with a `Picture` cache per row, keyed by `RenderRowId`.**
  - On a dirty row, record a new `Picture` for that row with backgrounds, runs and decorations, at local y = 0, and dispose the old one.
  - In `paint()`, for every visible row, `translate` and then `drawPicture`. This is O(rows) cheap ops plus the overlays: cursor, selection if not baked in, IME preedit.
  - Pure scrolling (row ids unchanged, rows moved) re-records nothing.
  - On a `full` dirty state, or a theme, font or DPR change, drop all pictures.
  - Mark the box `isRepaintBoundary = true` so the rest of the app does not repaint with it.
  - It plugs naturally into the v2 atlas: a row's picture would then hold one `drawRawAtlas` call.
- **Frame scheduling**
  - Never paint per `write`. On terminal output, `markNeedsPaint()` (not `markNeedsLayout`, as xterm does); the next vsync does `state.update()`.
  - Honour `onRenderHold`: while it is held, keep showing the cached pictures.
  - Cursor blink with a `Ticker`/`Timer` that only repaints the cursor overlay, never the rows.

### 2.5 Recommended v1 architecture

**[I]**, to validate with the measurements in §6.

1. **`TerminalRenderBox` (one `RenderBox`, repaint boundary).**
   - It owns one `RenderState`.
   - `paint()`: `update` → if `clean` and nothing else changed, replay the cached row pictures; otherwise re-record the dirty rows → overlays → `markClean()`.
2. **Row recording.**
   - **Backgrounds.** Merge equal-colour spans into one `drawRect` each. Apply inverse here. Selection can be baked into the background and foreground per span using `selectionStart/End`, which is more correct than xterm's translucent overlay.
   - **Text runs.** A run is a maximal span of the same `CellStyle` (`styleRunEnd`, plus `identical` on the style) **and** of "grid-safe" cells: narrow, single codepoint, expected in the primary font.
   - **Wide cells, graphemes, emoji and likely-fallback codepoints** each break the run. They are drawn as their own paragraph positioned at `col * cellW`, constrained or scaled to 1 or 2 cells. This prevents advance drift from fallback fonts.
   - **Paragraph LRU** keyed by `(text, style key, font config)`, with `dispose()` on eviction (as xterm2 does). Size it to the number of runs on a screen times a few frames (start at 4096 and measure).
3. **Decorations drawn by hand**, not with `TextDecoration`:
   - single, double, curly (a `Path` sine or arc series), dotted and dashed underlines;
   - strikethrough and overline as lines at metrics-derived positions, using `underlineColor`.
   - This is consistent across renderers and run boundaries, and covers spaces.
   - Flutter's `TextDecorationStyle` does support all five underline styles **[V]**, so it is a fallback if hand-drawing proves costly.
4. **Box-drawing and block elements procedurally** (U+2500–U+259F, plus braille and powerline later), as xterm2, flterm and Ghostty do. They are seamless at any cell size. This could be v1.1, because it is not needed for correctness.
5. **Cursor overlay.** Block, underline and bar from `RenderCursor.style`, a hollow block when unfocused, blink when `isBlinking`, and the wide tail handled. For a block cursor, redraw the cell's glyph in the inverse colour.
6. **Defer** the glyph atlas (v2), Kitty images (see §5) and ligatures.

---

## 3. Text metrics

### 3.1 Font choice

- **Bundle a default monospace font in the package.** This is required for web (#198, #42), for deterministic goldens, and for consistent metrics.
- Let users override `fontFamily` and the fallbacks.
- See §7 for which font.
- `fontFeatures: [FontFeature.disable('liga'), FontFeature.disable('calt')]` turns ligatures off. **[V]** The API exists; most coding-font ligatures (JetBrains Mono, Fira Code) live in `calt` **[I]**, so disable both.
- A Flutter package can declare `fonts:` in its pubspec; users reference it as `package: 'ghostty_dart_flutter'` / `packages/ghostty_dart_flutter/<family>`. **[I]** Standard Flutter behaviour, not re-checked today.

### 3.2 Measuring the cell

**[I]**, synthesised from xterm, xterm2 and flterm (all **[V]** above).

- **Advance `a`:** lay out a long string of `M` (say 100) in the regular face and take `maxIntrinsicWidth / n`. That averages out fractional rounding. Measure the bold face too and confirm the advances are equal.
- **Height `h`:** use `computeLineMetrics()` for ascent and descent (or `'Mgj'` as flterm does). `cellH = ceilToDevicePixel((ascent + descent) * lineHeightFactor)`. Centre the glyph vertically, as `TextLeadingDistribution.even` does.
- **Width:** `cellW = roundToDevicePixel(a)`. To keep a multi-glyph run on the integer grid, set `letterSpacing = cellW - a` on run styles.
  - Verify with `Paragraph.getGlyphInfoAt` in a unit test that glyph *i* starts at `i * cellW ± ε` on every renderer.
  - Fallback if `letterSpacing` misbehaves: keep a fractional `cellW = a` and snap only the row origins.
- **Line spacing:** use `StrutStyle(forceStrutHeight: true)` (or the height factor plus `TextHeightBehavior`) so fallback fonts with taller metrics do not change the line box.
- **Pass `cellW*dpr` and `cellH*dpr` to `terminal.resize(cellWidthPx:, cellHeightPx:)`.**
- Re-measure on font, size, text-scaler or DPR changes, and when the system fonts change. xterm hooks `clearFontCache` on system font changes (`PaintingBinding.systemFonts`).

### 3.3 Wide characters and graphemes

- Trust libghostty's width (`CellWidth.wide` / `spacerTail`) and never measure.
- Draw the wide cell's text in a 2-cell box and skip the spacers.
- For graphemes (`hasGraphemeAt`, and `writeTextTo` gives the whole cluster), draw the whole cluster as its own paragraph at the cell origin.
- Emoji and CJK glyphs that are wider or narrower than their cells:
  - centre them horizontally;
  - scale emoji uniformly down to fit (flterm's emoji lane does this **[V]**);
  - clip to the cell box, or allow overhang into the next cell only if it is blank (xterm2 5.3.0 "let wide symbol glyphs use adjacent blank cells" **[V]**).

### 3.4 Fallback fonts

- Native: the system fallback is automatic through `fontFamilyFallback` and the engine's font manager.
  - Emoji come from Apple Color Emoji, Segoe UI Emoji, or Noto Color Emoji on Linux if installed **[I]**.
  - Offer a `fontFamilyFallback` list like xterm's.
- Web: the engine fetches Noto fonts on demand from gstatic **[V]**. The first frame with a new script can repaint when the font arrives, so listen for font changes and invalidate the caches.
- Tests: bundle Noto Emoji (monochrome, OFL) and a CJK subset as test fixtures only, as flterm does **[V]**.

### 3.5 Attributes

| Attribute | How |
|---|---|
| Bold | Bold face (`FontWeight.bold`). Optional bold-is-bright for palette entries 0–7 (xterm issue #247 asks for it, 2026-11-08). |
| Italic | Italic face (`FontStyle.italic`). Bundle the italic file so it is not synthesised. |
| Underline: single, double, curly, dotted, dashed | Hand-drawn (§2.5.3). Flutter has all five as `TextDecorationStyle` **[V]**. |
| Strikethrough, overline | Hand-drawn lines from the font metrics (flterm reads `post`/`OS/2` **[V]**; v1 can use heuristics). |
| Inverse | Swap the resolved fg/bg, with defaults resolved first. |
| Faint | Multiply the alpha by about 0.5, or blend toward the background. |
| Blink | Toggle visibility on a shared timer; repaint only rows that contain blinking cells. Track this per row while recording. |
| Invisible | Skip the text, keep the background. |
| Hyperlink | `hasHyperlinkAt` gives an underline on hover. Not needed for v1. |

---

## 4. Colours and theme

- `RgbColor` maps to `Color.fromARGB(255, r, g, b)`. Cache the 256 palette `Color`s per `RenderColors` instance (identity check) **[I]**.
- `resolve(...) == null` means the default fg/bg from `RenderColors`.
- Cursor colour: `RenderColors.cursor ?? theme.cursor`.
- **`TerminalTheme`**: mirror xterm 4.0.0's shape for the adapter:
  - cursor, selection, foreground, background;
  - the 16 ANSI colours;
  - `searchHitBackground`, `searchHitBackgroundCurrent`, `searchHitForeground` (all **[V]** in `terminal_theme.dart`).
- Apply a theme by pushing it into the terminal:
  - `colorForegroundDefault`, `colorBackgroundDefault`, `colorCursorDefault`;
  - `colorPaletteDefault`, with the 256-colour palette generated from 16 colours by `ghostty_dart`'s generator.
- Then OSC queries, OSC 4/10/11 overrides and resets all work in the library, and the renderer just reads `RenderColors`.
- Also answer `onColorSchemeQuery` (dark or light) from the theme.

---

## 5. Kitty graphics and images

- **[V]** `ghostty_dart` exposes everything a renderer needs (§0). Drawing steps:
  1. Cache an `ui.Image` per `(imageId, imageGeneration)`.
  2. Convert RGB, gray and grayAlpha to RGBA in Dart.
  3. Decode with `decodeImageFromPixels` (async: draw on a later frame).
     - `decodeImageFromPixelsSync` is native-only: it throws on web.
  4. Draw with `drawImageRect(src → dst)` in layer order: `belowBackground`, then backgrounds, then `belowText`, then text, then `aboveText`.
  5. Animations: `tickKittyAnimations(nowMs)`, which returns the next deadline.
- **PNG problem [V/I]:** `setVtPngDecoder` must decode *synchronously* inside `vt_write`.
  - `dart:ui` decoding is async, so PNG support needs a pure-Dart PNG decoder. That is a new dependency, such as `package:image`, which conflicts with the "minimal dependencies" rule.
  - Or a small inflate-and-unfilter decoder of our own on top of `dart:io` `ZLibDecoder`, which is not available on web.
  - **[I]** Most real senders, such as `kitten icat`, often use PNG, so raw-only support is of limited value.
- **Recommendation: defer Kitty image drawing to after v1** (v1.x).
  - Keep the paint order slots (below-bg, below-text, above-text hooks) in the v1 painter so adding it later is additive.
  - Document it as ❌ planned in the platform/feature table.

---

## 6. Performance targets and measurement

### 6.1 Budget

**[I]**, simple arithmetic plus assumptions.

- 60 Hz gives 16.7 ms and 120 Hz gives 8.3 ms per frame.
- The UI and raster threads are pipelined, so **each** must stay under budget. Leave headroom for the app and the parser, which runs on the UI isolate during `vt_write`.
- A 200×60 grid is 12,000 cells. xterm does roughly 12k `drawParagraph` plus the background rects per frame.
- With runs, a typical TUI or log row has 1–10 runs, so 60–600 cached paragraphs on a full-screen change. A 3-row partial update re-records 3 pictures.

Proposed targets for 200×60 at DPR 2 on a desktop CI machine:

| Scenario | UI target | Raster target |
|---|---|---|
| Clean frame (cursor blink only) | ≤ 0.5 ms | ≤ 1 ms |
| Partial (3 rows) | ≤ 1 ms | ≤ 2 ms |
| Full-screen styled output, warm cache | ≤ 4 ms | ≤ 4 ms |
| Full-screen with all new glyphs, cold cache | report it; no hard target | – |

- The goal is 120 Hz-capable steady state.
- Compare against xterm 4.0.0 and xterm2 5.4.0 on identical byte streams. Reuse the `benchmarks/` workloads (ascii, sgr, unicode, tui, wrapped).

### 6.2 How to measure

- **Authoritative: `integration_test` + `binding.traceAction(..., reportKey:)` + `flutter drive --profile` + `TimelineSummary`.**
  - The summary gives `average/worst_frame_build_time_millis`, `average/worst_frame_rasterizer_time_millis`, `missed_frame_*_budget_count` and per-frame arrays (https://docs.flutter.dev/cookbook/testing/integration/profiling, updated 2026-09-29) **[V]**.
  - Add 90th and 99th percentiles ourselves from the per-frame arrays.
  - **Web is not supported by timeline recording [V]**: use Chrome DevTools or `FrameTiming` separately.
  - flterm does this on `macos-15` **[V]**. We would run Linux (xvfb) and macOS jobs **[I]**.
- **Scenarios:** copy flterm's protocol **[V]** (clean, partial 3 rows, full-screen, new glyphs, first frame). Exclude parser time, use a fixed grid, fixed metrics and the bundled fonts, and require at least 95% of the samples.
- **Micro-benchmarks** (`benchmark_harness`, `flutter test`):
  - Use these only for UI-thread pieces: row recording into a `PictureRecorder`, run splitting, cache hit rate, `RenderState.update` + row iteration cost.
  - `flutter test` runs debug/JIT on flutter_tester, so the numbers are relative only **[I]**.
  - Also note `--enable-impeller` is a `flutter test` option (`F/packages/flutter_tools/lib/src/commands/test.dart:489`) **[V]**.
- **`FrameTiming` / `SchedulerBinding.addTimingsCallback`:** an in-app HUD for the demo. Not authoritative.
- **xterm.dart's own benchmarks [V]:** `bin/xterm_bench.dart` (write and search 1000 lines) and `script/benchmark.dart` (parser `write` loops with a `Stopwatch`). **They are parser-only; there is no rendering benchmark and no published numbers.** flterm publishes no numbers either. Our numbers would be the first public frame-time comparison, so be careful and reproducible.

---

## 7. Golden tests

- **[V]** By default `flutter_test` renders text with the **Ahem** box font. Real fonts must be loaded with `FontLoader(...).addFont(rootBundle.load(...))`, ideally once in `flutter_test_config.dart` (`F/packages/flutter_test/lib/src/matchers.dart:534-575`).
- **[V]** The same docs warn that goldens differ across operating systems and Flutter versions. AGENTS.md's "goldens on Linux CI only" is correct: tag them (`@Tags(['golden'])`) and skip them elsewhere.
- Goldens use the flutter_tester renderer. That is Skia by default **[I]**; `--enable-impeller` exists **[V]**. Pin one and document it.
- **Fonts**
  - Licences checked through the GitHub API on 2026-11-09 **[V]**:

    | Font | Licence | Latest release | Notes |
    |---|---|---|---|
    | JetBrains Mono | OFL-1.1 (`OFL.txt`) | v2.304 (2023-01-14) | No Reserved Font Name in the header. Static TTFs about 270 KB per style (Regular, Bold, Italic, BoldItalic ≈ 1.1 MB). |
    | Fira Code | OFL-1.1 | 6.2 (2021-12-06) | No Reserved Font Name. **No italic.** |
    | Cascadia Code | OFL-1.1 | v2407.24 (2024-11-27) | **"Reserved Font Name Cascadia Code"**: any modified or subset version must be renamed. |

  - **Recommendation: JetBrains Mono.**
    - It has a true italic and no Reserved Font Name, so subsetting is legal without renaming.
    - flterm uses it too.
    - Ship the OFL text next to the font files and mention it in the README.
    - Download the files by pinned sha256 from the GitHub release, under the supply-chain rules.
  - For test-only fixtures: Noto Emoji (monochrome, OFL) and a Noto Sans CJK or JP subset, also OFL.
- **What to golden:**
  - an SGR matrix (colours × attributes);
  - all underline styles;
  - inverse and faint;
  - wide CJK and emoji with spacers;
  - cursor shapes, focused and unfocused;
  - selection across wide characters;
  - box drawing.
- Also add **non-golden geometry tests**, which run on every OS:
  - cell size snapping;
  - glyph *i* x-position via `getGlyphInfoAt`;
  - run splitting;
  - the dirty rows actually re-recorded (count the recordings).

---

## 8. Open questions and things to verify early

1. Does `letterSpacing = cellW - a` keep the glyphs on the grid on Impeller, CanvasKit and skwasm? (`getGlyphInfoAt` test.)
2. On Impeller, what is the raster cost of replaying about 60 row pictures with about 600 paragraphs, compared with the UI cost of re-recording them? (Measure with traceAction.)
3. Is the Metal Impeller surface also free of a raster cache? Only GL and Vulkan were checked.
4. Picking the PNG decoder for Kitty (deferred), and whether `dart:io` `ZLibDecoder` is acceptable on native only.
5. The xterm #198 wasm comment says the bundled-font workaround fails under wasm. Check font loading under `--wasm` (skwasm) in the demo early.

## Sources (all read 2026-11-09)

- Local: `packages/ghostty_dart/lib/src/{render,core,terminal,kitty,sys,color}`; `~/.pub-cache/hosted/pub.dev/xterm-4.0.0`, `xterm2-5.4.0`; the Flutter 3.47.9 SDK (`ui/`, `web/`, `F/engine/src/flutter/{shell,display_list,flow}`, `F/packages/flutter_test`, `F/packages/flutter_tools`).
- flterm: https://github.com/elias8/libghostty (HEAD a52afc40, 2026-11-04). Files: `packages/flterm/lib/src/rendering/**`, `tool/benchmarks/README.md`, `.github/workflows/benchmark-flterm.yml`; issue list.
- xterm.dart issues: https://github.com/TerminalStudio/xterm.dart/issues/73, /198, /42, /165, /191, /211, /247.
- Impeller: https://docs.flutter.dev/perf/impeller (2026-08-21); https://github.com/flutter/flutter/issues/116815; https://github.com/flutter/flutter/issues/112213; https://flutter.googlesource.com/mirrors/engine/+/91f250b5a4154059e42c5f61d85dba0250cccdb0%5E (PR #56798).
- Profiling: https://docs.flutter.dev/cookbook/testing/integration/profiling (2026-09-29).
- Fonts: GitHub API `repos/{JetBrains/JetBrainsMono, tonsky/FiraCode, microsoft/cascadia-code}/license` and `/releases/latest`; the licence file headers.
