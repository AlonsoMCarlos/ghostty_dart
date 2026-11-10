# Parser throughput benchmark

How fast can each Dart terminal engine consume program output? This benchmark
feeds the same deterministic VT byte streams to three engines and measures
input throughput, memory growth, and whether they end up with the same screen.

| Engine | Package | Input |
|---|---|---|
| `ghostty_dart` | this workspace (`packages/ghostty_dart`), libghostty-vt 1.0.0 via FFI | `Uint8List` (pty bytes) |
| `xterm` | [`xterm`](https://pub.dev/packages/xterm) 4.0.0, `package:xterm/core.dart` | `String` |
| `xterm2_core` | [`xterm2_core`](https://pub.dev/packages/xterm2_core) 1.0.0, the pure-Dart core of [`xterm2`](https://pub.dev/packages/xterm2) 5.4.0 | `String` |

`xterm2` 5.4.0 re-exports its terminal from `xterm2_core` 1.0.0
(`export 'package:xterm2_core/xterm2_core.dart'` in `lib/core.dart`), so
benchmarking `xterm2_core` measures exactly the parser and buffer that `xterm2`
ships, without Flutter. `package:xterm/core.dart` imports only `dart:` libraries,
so all three engines run on the plain Dart VM.

## Run it

From the repository root, after `mise install`, `dart pub get` and
`mise run native:build` (or any build that fills `.native-cache/out`):

```sh
mise run bench:parser                        # JIT + AOT, 16 MiB per workload, ~10 min
mise run bench:parser -- --runtime=aot --size=4 --runs=3   # quicker
```

Options, all `--key=value`:

| Option | Default | Meaning |
|---|---|---|
| `--runtime` | `jit,aot` | `jit` = `dart run`; `aot` = `dart build cli` executable |
| `--size` | `16` | MiB generated per workload |
| `--runs` / `--warmup` | `5` / `1` | measured / discarded runs per cell; the median is reported |
| `--chunks` | `4096,65536` | bytes per `write` call |
| `--workloads` | all | `ascii,sgr,unicode,tui,wrapped` |
| `--engines` | all | `ghostty_dart,xterm,xterm2_core` |
| `--memory` | `true` | also run the RSS measurement |
| `--out` | – | also write the Markdown report to a file |

The report goes to stdout (progress to stderr). The process exits with code 1
if the engines disagree on the screen of a required workload (`ascii`, `sgr`).

## Methodology

- **Same terminal for everyone:** 200 × 50 cells, 10,000 lines of scrollback.
  For `ghostty_dart` that means `scrollbackMaxLines = 10000` and
  `scrollbackMaxBytes = null` (its default is a ~400 KB byte limit, which would
  keep far less history). `xterm`/`xterm2_core` get `maxLines: 10050`, because
  their `maxLines` includes the visible rows. Reflow stays at each engine's
  default.
- **Workloads** (`lib/src/workloads.dart`), generated from `Random(42)` so
  every engine and run sees identical bytes:
  1. `ascii`: plain words in lines shorter than 120 columns, CRLF endings.
  2. `sgr`: `ls --color`-style names, each with an SGR sequence: 16-colour,
     bold directory, 256-colour, truecolor, mixed attributes + backgrounds.
  3. `unicode`: CJK ideographs, Hiragana, emoji, skin-tone modifiers, ZWJ
     sequences, flags, precomposed and combining accents, mixed with ASCII.
  4. `tui`: htop/vim-like full-screen redraws in the alternate screen: CUP,
     coloured meters, a scroll region scrolled with LF and `SD`, EL, ICH/DCH,
     IL/DL, ECH, DECSC/DECRC and a status line.
  5. `wrapped`: `cat` of long lines (500–5,000 columns) that soft-wrap.
- **Chunks:** the stream is cut into fixed 4 KiB and 64 KiB pieces, ignoring
  UTF-8 and escape-sequence boundaries, like real pty reads.
- **Feeds:** `ghostty_dart` takes the bytes directly (`bytes`). The xterm
  engines take decoded text, so they are measured twice:
  - `decode`: a chunked `Utf8Decoder(allowMalformed: true)` runs inside the
    timed loop, which is what an app using `flutter_pty` or `dartssh2` with
    `utf8.decoder` pays end to end;
  - `text`: strings decoded before timing, i.e. the parser alone.
  The "vs fastest other" column compares end-to-end numbers (`bytes` against
  the faster `decode`).
- **Timing:** each run constructs a fresh engine (not timed), feeds the whole
  workload, and stops the clock. One warm-up run, then the median of five.
  MB/s is 10^6 bytes of pty input per second.
- **Isolation:** every engine × workload runs in its own process, for both
  JIT and AOT, so one engine's JIT profile, heap growth or native allocations
  never affect another.
- **Memory:** a separate fresh process per engine × workload records
  `ProcessInfo.currentRss` after generating the input and creating the engine
  type once (so code and the native library are already loaded), feeds the
  workload once in 64 KiB chunks (xterm engines with decoding), and records RSS
  again; the peak is sampled after every chunk. RSS is the fair metric because
  libghostty-vt's memory is native and invisible to Dart heap tools.
- **Correctness:** after the last run of every chunk size and feed, the
  visible screen is extracted with the same normalisation for every engine
  (empty cell = space, wide-character spacer skipped, trailing blanks trimmed,
  plus ` ⟦n⟧` = columns occupied so a different cell layout cannot hide behind
  equal text). Screens are compared across engines, and within an engine
  across chunk sizes and feeds ("chunking").

## Results

Measured on 2026-11-09 with `mise run bench:parser` (defaults: 16 MiB per
workload, 1 warm-up + 5 runs, JIT and AOT). In short: end to end,
`ghostty_dart` consumed pty output **3.3–7.6× faster** than the faster of
the two xterm engines in every workload, and grew RSS by 0.5–18 MiB where
they grew by 1.5–81 MiB. The xterm engines spend little on UTF-8 decoding
(`decode` vs `text` is within ~15%): their cost is in the parser and buffer.

### Machine

| | |
|---|---|
| Date | 2026-11-09 |
| CPU | AMD Ryzen 5 3600 6-Core Processor (6 logical CPUs) |
| Memory | 23.9 GiB |
| OS | linux Linux 6.12.115+deb13.1-cloud-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.12.115-2 (2026-11-01) |
| Dart | 3.13.7 (stable) (Thu Oct 22 14:28:57 2026 -0700) on "linux_x64" |
| libghostty-vt | libghostty-vt 1.0.0, optimize=releaseFast, simd=true |

### Settings

- Engines: ghostty_dart (workspace), xterm 4.0.0, xterm2_core 1.0.0
- Terminal: 200x50, 10000 scrollback lines
- Workload size: 16.0 MiB each; chunk sizes: 4 KiB, 64 KiB
- 1 warm-up + 5 measured runs per cell; median shown. MB/s = 10^6 bytes of pty input per second.

### Throughput — JIT

`bytes`: raw pty bytes. `decode`: UTF-8 decoding inside the timed loop (end to end, as apps do). `text`: pre-decoded strings (parser only).

| Workload | Chunk | ghostty_dart (bytes) | xterm (decode) | xterm (text) | xterm2_core (decode) | xterm2_core (text) | ghostty_dart vs fastest other, end to end |
|---|---:|---:|---:|---:|---:|---:|---:|
| ascii | 4 KiB | 98.6 MB/s · 170 ms | 15.7 MB/s · 1067 ms | 15.9 MB/s · 1054 ms | 27.6 MB/s · 607 ms | 28.0 MB/s · 599 ms | 3.6× |
| ascii | 64 KiB | 92.8 MB/s · 181 ms | 13.6 MB/s · 1233 ms | 13.8 MB/s · 1213 ms | 27.7 MB/s · 605 ms | 27.7 MB/s · 605 ms | 3.3× |
| sgr | 4 KiB | 86.4 MB/s · 194 ms | 20.6 MB/s · 815 ms | 20.7 MB/s · 812 ms | 24.9 MB/s · 675 ms | 24.9 MB/s · 674 ms | 3.5× |
| sgr | 64 KiB | 86.1 MB/s · 195 ms | 17.1 MB/s · 980 ms | 17.3 MB/s · 969 ms | 24.9 MB/s · 674 ms | 25.1 MB/s · 669 ms | 3.5× |
| unicode | 4 KiB | 128.2 MB/s · 131 ms | 28.6 MB/s · 587 ms | 32.6 MB/s · 515 ms | 9.6 MB/s · 1749 ms | 10.0 MB/s · 1675 ms | 4.5× |
| unicode | 64 KiB | 131.4 MB/s · 128 ms | 26.9 MB/s · 623 ms | 31.4 MB/s · 535 ms | 9.7 MB/s · 1733 ms | 10.1 MB/s · 1661 ms | 4.9× |
| tui | 4 KiB | 171.0 MB/s · 98 ms | 24.4 MB/s · 689 ms | 24.5 MB/s · 685 ms | 24.9 MB/s · 673 ms | 25.0 MB/s · 671 ms | 6.9× |
| tui | 64 KiB | 171.8 MB/s · 98 ms | 16.0 MB/s · 1047 ms | 16.3 MB/s · 1029 ms | 24.2 MB/s · 693 ms | 24.1 MB/s · 696 ms | 7.1× |
| wrapped | 4 KiB | 303.6 MB/s · 55 ms | 21.1 MB/s · 798 ms | 21.2 MB/s · 792 ms | 60.3 MB/s · 279 ms | 60.5 MB/s · 278 ms | 5.0× |
| wrapped | 64 KiB | 310.8 MB/s · 54 ms | 17.3 MB/s · 975 ms | 17.1 MB/s · 983 ms | 61.1 MB/s · 275 ms | 61.2 MB/s · 275 ms | 5.1× |

### Throughput — AOT

`bytes`: raw pty bytes. `decode`: UTF-8 decoding inside the timed loop (end to end, as apps do). `text`: pre-decoded strings (parser only).

| Workload | Chunk | ghostty_dart (bytes) | xterm (decode) | xterm (text) | xterm2_core (decode) | xterm2_core (text) | ghostty_dart vs fastest other, end to end |
|---|---:|---:|---:|---:|---:|---:|---:|
| ascii | 4 KiB | 98.8 MB/s · 170 ms | 14.0 MB/s · 1198 ms | 14.0 MB/s · 1196 ms | 24.5 MB/s · 684 ms | 24.7 MB/s · 680 ms | 4.0× |
| ascii | 64 KiB | 99.5 MB/s · 169 ms | 11.6 MB/s · 1444 ms | 12.0 MB/s · 1401 ms | 24.4 MB/s · 688 ms | 25.0 MB/s · 671 ms | 4.1× |
| sgr | 4 KiB | 88.1 MB/s · 191 ms | 17.3 MB/s · 971 ms | 17.5 MB/s · 959 ms | 23.7 MB/s · 710 ms | 23.3 MB/s · 721 ms | 3.7× |
| sgr | 64 KiB | 88.9 MB/s · 189 ms | 15.1 MB/s · 1114 ms | 15.0 MB/s · 1117 ms | 23.4 MB/s · 718 ms | 23.3 MB/s · 720 ms | 3.8× |
| unicode | 4 KiB | 131.7 MB/s · 128 ms | 26.2 MB/s · 640 ms | 29.8 MB/s · 563 ms | 8.7 MB/s · 1933 ms | 9.0 MB/s · 1860 ms | 5.0× |
| unicode | 64 KiB | 131.8 MB/s · 127 ms | 25.1 MB/s · 670 ms | 28.2 MB/s · 594 ms | 8.7 MB/s · 1930 ms | 9.0 MB/s · 1874 ms | 5.3× |
| tui | 4 KiB | 169.5 MB/s · 99 ms | 18.9 MB/s · 890 ms | 18.8 MB/s · 893 ms | 23.0 MB/s · 731 ms | 23.1 MB/s · 728 ms | 7.4× |
| tui | 64 KiB | 171.4 MB/s · 98 ms | 14.4 MB/s · 1161 ms | 14.3 MB/s · 1171 ms | 22.7 MB/s · 740 ms | 22.6 MB/s · 741 ms | 7.6× |
| wrapped | 4 KiB | 306.7 MB/s · 55 ms | 16.6 MB/s · 1017 ms | 16.6 MB/s · 1015 ms | 59.1 MB/s · 285 ms | 59.2 MB/s · 284 ms | 5.2× |
| wrapped | 64 KiB | 318.5 MB/s · 53 ms | 14.2 MB/s · 1183 ms | 14.2 MB/s · 1184 ms | 57.5 MB/s · 293 ms | 60.0 MB/s · 281 ms | 5.5× |

### Memory — AOT, fresh process per cell

Resident set size growth while writing the whole workload once (64 KiB chunks; xterm engines include UTF-8 decoding): `ProcessInfo.currentRss` after − before, and in brackets the peak growth (sampled after every chunk). Includes native memory.

| Workload | ghostty_dart | xterm | xterm2_core |
|---|---:|---:|---:|
| ascii | +15.6 MiB (peak +15.9 MiB) | +81.2 MiB (peak +93.2 MiB) | +33.2 MiB (peak +37.6 MiB) |
| sgr | +16.6 MiB (peak +16.8 MiB) | +66.4 MiB (peak +75.0 MiB) | +30.8 MiB (peak +34.5 MiB) |
| unicode | +17.6 MiB (peak +17.7 MiB) | +68.7 MiB (peak +77.9 MiB) | +39.5 MiB (peak +56.0 MiB) |
| tui | +0.5 MiB (peak +0.5 MiB) | +5.5 MiB (peak +5.5 MiB) | +1.5 MiB (peak +1.6 MiB) |
| wrapped | +15.6 MiB (peak +15.7 MiB) | +59.7 MiB (peak +73.1 MiB) | +60.2 MiB (peak +67.8 MiB) |

### Correctness

Visible screen text after each workload (empty cells as spaces, trailing blanks trimmed). Required to match: ascii, sgr. "chunking" checks that every chunk size and feed left each engine with the same screen.

| Runtime | Workload | ghostty_dart vs xterm | ghostty_dart vs xterm2_core | xterm vs xterm2_core | chunking |
|---|---|---|---|---|---|
| jit | ascii | ✅ identical | ✅ identical | ✅ identical | ✅ |
| jit | sgr | ✅ identical | ✅ identical | ✅ identical | ✅ |
| jit | unicode | ⚠️ 40/50 rows differ | ⚠️ 43/50 rows differ | ⚠️ 43/50 rows differ | ✅ |
| jit | tui | ✅ identical | ✅ identical | ✅ identical | ✅ |
| jit | wrapped | ✅ identical | ✅ identical | ✅ identical | ✅ |
| aot | ascii | ✅ identical | ✅ identical | ✅ identical | ✅ |
| aot | sgr | ✅ identical | ✅ identical | ✅ identical | ✅ |
| aot | unicode | ⚠️ 40/50 rows differ | ⚠️ 43/50 rows differ | ⚠️ 43/50 rows differ | ✅ |
| aot | tui | ✅ identical | ✅ identical | ✅ identical | ✅ |
| aot | wrapped | ✅ identical | ✅ identical | ✅ identical | ✅ |

First differing row per mismatch:

- unicode, ghostty_dart vs xterm, first at row 0:
  - ghostty_dart: `…杸 ごりぎぼ 鄣陫雒菫侰 #1k3V 觯鮀之 呦漵朝 ⟦152⟧`
  - xterm: `…杸 ごりぎぼ 鄣陫雒菫侰 #1k3V 觯鮀之 呦漵朝 ⟦154⟧`
- unicode, ghostty_dart vs xterm2_core, first at row 0:
  - ghostty_dart: `…咶杸 ごりぎぼ 鄣陫雒菫侰 #1k3V 觯鮀之 呦漵朝 ⟦152⟧`
  - xterm2_core: `…咶杸 ごりぎぼ 鄣陫雒菫侰 #1k3V 觯鮀之 呦漵朝 ⟦145⟧`
- unicode, xterm vs xterm2_core, first at row 0:
  - xterm: `…咶杸 ごりぎぼ 鄣陫雒菫侰 #1k3V 觯鮀之 呦漵朝 ⟦154⟧`
  - xterm2_core: `…咶杸 ごりぎぼ 鄣陫雒菫侰 #1k3V 觯鮀之 呦漵朝 ⟦145⟧`


## Caveats

- **Only input processing is measured:** VT parsing, screen and scrollback
  updates. Painting, layout, widgets, the render state/frame snapshot, input
  encoding and selection are not measured, so these numbers do not predict
  frame rates in a Flutter app.
- **Scrollback size dominates `ghostty_dart`'s numbers.** With its default
  byte limit (about one page of history) a quick JIT probe on this machine gave
  ~460–520 MB/s for 16 MiB of `ascii` and ~125–135 MB/s for `sgr`, against
  ~85–95 and ~82 MB/s with the 10,000-line limit used here (and ~105 / ~85 with
  no limit). The benchmark uses the same 10,000 lines for everyone because
  that is the fair comparison, but it is the slow configuration for ghostty.
  The gap is mostly an upstream inefficiency, not the cost of keeping 10,000
  lines: libghostty-vt 1.0.0 decommits each page it prunes by line count and
  immediately faults it back in for the next page. The byte limit that keeps
  about the same history (`scrollbackMaxBytes = 18276352`,
  `scrollbackMaxLines = null`) avoids it and runs ~2x faster. Details, C repro
  and a candidate fix: `docs/internal/research/2026-11-09-upstream-findings.md` §7.
  Re-measure when upstream changes it.
- **JIT vs AOT:** Flutter release builds are AOT, so the AOT table is the one
  that predicts shipped apps; JIT (`dart run`, debug builds) is shown because
  it is what developers see. The FFI cost of `ghostty_dart` is the same in both;
  the xterm engines are pure Dart and benefit more from AOT/JIT differences.
- **`ghostty_dart.write` copies** each chunk into native memory before calling
  `ghostty_terminal_vt_write`; that copy is included, as it is in real use.
- **Chunk size matters:** smaller chunks mean more calls (FFI transitions for
  `ghostty_dart`, decoder and `notifyListeners` calls for the xterm engines).
  Real ptys deliver anything from a few bytes to 64 KiB per read.
- **RSS deltas are coarse:** they include garbage the Dart GC has not yet
  returned (decoded strings for the xterm engines) and allocator retention, and
  vary with GC timing. There is no forced GC (that would need `vm_service`).
  Read them as orders of magnitude, not exact retained sizes.
- **Single machine, not isolated:** the numbers below come from a shared
  cloud VM with other work running; expect a few percent of noise. Re-run on
  your hardware before quoting a figure.
- **Correctness check is screen text and layout only**, not colours or
  attributes, and only the final screen, not the scrollback.
- **Known, expected disagreements:**
  - `unicode`: the text is identical in all three engines, but the cell layout
    of some graphemes differs (the ` ⟦n⟧` column counts). libghostty-vt
    clusters graphemes (flags, ZWJ sequences, VS16 emoji take one 2-column
    cell), whereas xterm.dart 4.0.0 and xterm2_core give code points their own
    widths, and they also differ from each other. This is a real behavioural
    difference, not a benchmark artefact, so the workload is reported and
    not enforced.
  - `CSI 0 T` (scroll down, parameter 0): xterm2_core scrolls one line, as
    the real xterm does (0 means "default"); libghostty-vt 1.0.0 and xterm.dart
    4.0.0 do nothing. The first version of the `tui` workload emitted it by
    accident and showed 18 differing rows; the workload now always scrolls 1–4
    lines, since real programs do not send a 0 count.

## Dependency audit

Added only to this unpublished member (`publish_to: none`); the published
packages gain no dependency. Checked on 2026-11-09 against pub.dev, with every
package's source read in `~/.pub-cache`:

| Package | Version | Published | Why it is here | `hook/` or build-time code |
|---|---|---|---|---|
| `xterm` | 4.0.0 | 2024-02-27 | engine under test | none |
| `xterm2_core` | 1.0.0 | 2026-10-21 | engine under test | none |
| `equatable` | 2.1.0 | 2026-07-05 | xterm | none |
| `zmodem` | 0.0.6 | 2023-04-27 | xterm | none |
| `characters` | 1.4.1 | 2025-06-25 | xterm2_core, Flutter | none |
| `material_color_utilities` | 0.13.0 | 2025-06-04 | Flutter SDK | none |
| `vector_math` | 2.4.4 | 2026-10-26 | Flutter SDK | none (`build.yaml` only configures its own web tests for build_runner) |
| `flutter`, `sky_engine` | SDK | – | xterm's pubspec requires `flutter: sdk` | none |

Already in the lockfile and also reached through xterm: `convert` 3.1.2,
`meta` 1.19.0, `quiver` 3.2.2 (→ `matcher` 0.12.20 → `async`, `stack_trace`,
`term_glyph`, `test_api`, `boolean_selector`, `source_span`, `string_scanner`,
`stream_channel`, `path`, `collection`), `typed_data` 1.4.0 — none ships a
`hook/` directory. `mise run cooldown` passes (every locked version ≥ 3 days
old) and the lockfile diff adds exactly the nine entries above.

Because xterm 4.0.0 declares `flutter: sdk: flutter`, the workspace now
resolves only with Flutter's Dart (which mise installs); a standalone Dart SDK
fails at `dart pub get`. Nothing from Flutter is imported: both xterm entry
points used here import only `dart:` libraries (plus `characters` for
xterm2_core).

`benchmark_harness` is not used: it reports a mean of a time-boxed loop,
whereas this benchmark needs per-run medians over a fixed amount of input, and
avoiding it keeps the dependency set smaller.

## Frame-time benchmark (widgets)

How long does each Flutter terminal widget take to produce a frame? This
benchmark (`benchmarks/widget/`, a Flutter app and workspace member) drives
the same per-frame byte streams into three widgets and records the frame
timeline with `integration_test`'s `traceAction` under `flutter drive
--profile`, as the [Flutter profiling
cookbook](https://docs.flutter.dev/cookbook/testing/integration/profiling)
describes (checked 2026-11-10).

| Widget | Package | Input |
|---|---|---|
| `ghostty_dart_flutter` | this workspace, `VtTerminalView` | `Uint8List` via `writeBytes` |
| `xterm 4.0.0` | [`xterm`](https://pub.dev/packages/xterm) 4.0.0, `TerminalView` | `String` (UTF-8 decoded in the write) |
| `xterm2 5.4.0` | [`xterm2`](https://pub.dev/packages/xterm2) 5.4.0, `TerminalView` | `String` (UTF-8 decoded in the write) |

### Run it

It needs a display and a desktop toolchain (Linux: `clang cmake ninja-build
pkg-config libgtk-3-dev`, from the [Flutter Linux
setup](https://docs.flutter.dev/platform-integration/linux/setup), updated
2026-09-10), plus the JetBrains Mono test fonts in
`packages/ghostty_dart_flutter/test/fonts/`.

```sh
mise run bench:widget                      # Linux desktop: 3 passes x 300 traced frames, Impeller
mise run bench:widget --frames=600 --passes=5
mise run bench:widget --renderer=skia      # --no-enable-impeller
mise run bench:widget macos                # on a Mac
# Headless Linux: a virtual display large enough for the window; GDK_SCALE=2
# asks GTK for device pixel ratio 2 (the ADR 0011 targets are at DPR 2).
GDK_SCALE=2 xvfb-run -a -s '-screen 0 3840x2400x24' mise run bench:widget
```

The report goes to stdout and `benchmarks/widget/build/widget_bench.md`;
every run's timeline and `TimelineSummary` are in
`benchmarks/widget/build/<scenario>__<widget>__p<pass>.timeline{,_summary}.json`.
`mise run bench:widget:test` (part of `mise run check`) tests the harness
headlessly: the streams, the report, and that all three widgets end up with
the same screen text for every scenario.

The macOS bench app is not sandboxed, because it reads the test fonts from
the repository. It has not been run on a Mac yet.

### Methodology

- **Same grid for everyone:** 200 × 60 cells, JetBrains Mono 12 px, no
  focus (no cursor blink), cursor hidden. `ghostty_dart_flutter` gets a box
  of exactly 200 × 60 device-pixel-aligned cells (`VtCellMetrics.measure`,
  the style's natural line height). The xterm widgets get `autoResize:
  false`, a 200 × 60 terminal, line height 1.0, and a box measured from the
  font plus 2% slack, so every row is inside the viewport and painted. The
  row and column counts are identical (the harness test proves the same
  text), but the painted areas differ slightly. The test fails if the window
  cannot hold the grid (the Linux runner opens 1800 × 1100 logical px).
- **Streams** (`lib/src/frame_streams.dart`, `Random(42)`): printable ASCII
  in words with SGR styling (16, 256 and truecolor foregrounds, bold,
  italic, underline, backgrounds). Rows are exactly 200 columns and
  addressed with CUP, except in the scroll scenario. The setup writes RIS
  and ED, hides the cursor and fills the screen.
- **Scenarios** (ADR 0011 targets for `ghostty_dart_flutter`, UI / raster):
  1. `idle`: no output; a forced frame recomposites the unchanged screen
     (≤ 0.5 / ≤ 1 ms);
  2. `3 dirty rows`: three rows 20 apart are rewritten per frame with new
     text, moving down one row each frame (≤ 1 / ≤ 2 ms);
  3. `full screen, fresh`: all 60 rows are rewritten per frame with new
     text that never repeats, warm-up included (≤ 4 / ≤ 4 ms: the ADR's
     "full screen, warm cache" target, caches warmed by the same kind of
     output);
  4. `scroll (cat)`: `cat` of a plain text file, 6 new lines (0–160
     columns, no escapes) at the bottom per frame, so the screen scrolls
     (no ADR target);
  5. `htop-like (20 % of cells)`: the setup screen stays, and every frame
     writes new 8-digit values into 5 fixed fields of every row (2,400 of
     12,000 cells; every row changes) (no ADR target);
  6. `full screen, warm (cache replay)`: all 60 rows are rewritten per
     frame, cycling through 8 screens. After the warm-up every frame repeats
     one already drawn, so it measures replaying caches, not drawing new
     text; a widget that caches whole rows by content (ours) draws no text
     when its cache holds the cycle. Kept for comparison with the first
     runs; read the fresh scenario for full-screen output.
- **Warm-up:** 32 untraced frames from the *same* stream as the measured
  frames. The measured frames continue that stream: in the cache-replay
  scenario every measured frame has already been drawn once; in the fresh
  scenario none has.
- **Frames:** the binding uses `benchmarkLive`, so frames come from the
  engine's vsync, as in an app. Each step writes its bytes, forces a frame
  and waits for it (`endOfFrame`).
- **Write time:** the write runs before the frame, on the UI thread. It
  includes parsing and anything the widget does synchronously on a write
  (listeners, render-state updates). It is timed per step with a
  `Stopwatch` and reported next to the frame times. The UI target is
  checked against **write + UI frame** time, so work moved out of the frame
  still counts.
- **Passes:** 3 by default. Each pass runs every scenario on every widget,
  rotating the widget order, so no widget always runs first or last.
  Averages are the median of the per-pass averages. p90, p99 (nearest rank)
  and worst pool every pass. A run where the timeline recorded fewer than
  95% of the driven frames is flagged `⚠` and must not be published.
- **Tracing:** only the `Dart`, `Embedder` and `GC` timeline streams, into
  an endless buffer (`--endless-trace-buffer`). The first run on
  2026-11-10 traced `all` streams into the VM's ring buffer: the `API`
  stream (tens of thousands of `Dart_StringToUTF8` events per full-screen
  run) evicted the frame events, the 3-dirty-rows timeline covered only
  the last 1.5 s, and the driver stopped on a run with no frames left.
  Those numbers were discarded.
- **Renderer and DPR:** the task passes `--enable-impeller` (the default)
  or `--no-enable-impeller`, which the desktop device forwards to the
  engine. The report records the renderer the timeline's engine event
  names show (Impeller's OpenGL ES backend: `ReactorGLES::React` and
  `RenderPassGLES::*`; Impeller on any backend: `CreateGlyphAtlas`; Skia:
  `SkCanvas::Flush`, which the engine only traces with `--trace-skia`, so
  a Skia run reads `unknown`) and the actual device pixel ratio. The ADR
  verdict is printed only at DPR 2. Under `xvfb-run` there is no GPU, so
  the raster numbers are software rendering; report them only next to the
  machine and display they come from.

### Results

The third run on 2026-11-10 (renderer of the T6 fix round, harness with the
fresh, scroll and htop-like scenarios), on a cloud VM **without a GPU**.
Read the raster columns as software rendering and the UI columns as one
6-core VM; neither predicts a phone or a desktop with a GPU. Re-run on your
hardware before quoting a number.

```sh
GDK_SCALE=2 xvfb-run -a -s '-screen 0 3840x2400x24' mise run bench:widget
```

| | |
|---|---|
| Machine | AMD Ryzen 5 3600 (`lscpu`: 6 vCPUs, 1 thread per core), 21 GiB RAM, KVM guest with an emulated VGA (no GPU) |
| OS | Debian 13, Linux 6.12.115 |
| Display | Xvfb 21.1.16, 3840 × 2400 × 24; Mesa 25.0.7 (software rasteriser) |
| Flutter / Dart | 3.47.9 / 3.13.7, `flutter drive --profile` |
| Renderer | Impeller, OpenGL ES backend (requested with `--enable-impeller`; the report read `Impeller (OpenGL ES)` from the timelines) |
| Device pixel ratio | 2.0 (`GDK_SCALE=2`), window 1800 × 1100 logical px |
| Grid, font | 200 × 60 cells, JetBrains Mono 12 px |
| Frames | 300 traced per run (+ 32 warm-up), 3 passes, widget order rotated |
| Semantics | On for all three widgets: the Linux embedder enabled it (all 54 timelines have `Semantics.*` events). `ghostty_dart_flutter` then also reads its visible text at most every 500 ms. |

Times in ms. UI = frame build time (build, layout, paint on the UI
thread); raster = rasterizer time; write = the synchronous write before
the frame. avg = median of the per-pass averages; p90, p99 and worst pool
all passes. The ADR verdict checks write + UI against the UI target.

| Scenario | Widget | Frames | UI avg | UI p90 | UI p99 | UI worst | Raster avg | Raster p90 | Raster p99 | Raster worst | Write avg | Write p99 | Write + UI avg | ADR target (UI / raster) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| idle | ghostty_dart_flutter | 900/900 | 0.14 | 0.18 | 0.30 | 0.60 | 102.46 | 110.62 | 125.65 | 184.42 | 0.00 | 0.00 | 0.14 | UI met, raster missed (≤ 0.5 / ≤ 1.0) |
| idle | xterm 4.0.0 | 900/900 | 0.15 | 0.17 | 0.28 | 4.06 | 160.52 | 174.89 | 196.06 | 321.75 | 0.00 | 0.00 | 0.15 | – |
| idle | xterm2 5.4.0 | 900/900 | 0.15 | 0.17 | 0.23 | 0.38 | 141.45 | 153.53 | 184.03 | 307.47 | 0.00 | 0.00 | 0.15 | – |
| 3 dirty rows | ghostty_dart_flutter | 901/900 | 2.44 | 2.90 | 5.52 | 10.72 | 102.30 | 111.17 | 137.00 | 178.56 | 0.05 | 0.20 | 2.49 | missed (≤ 1.0 / ≤ 2.0) |
| 3 dirty rows | xterm 4.0.0 | 900/900 | 19.01 | 22.51 | 35.23 | 55.16 | 160.60 | 176.84 | 204.12 | 330.17 | 0.10 | 0.17 | 19.11 | – |
| 3 dirty rows | xterm2 5.4.0 | 901/900 | 25.38 | 30.09 | 37.40 | 91.68 | 147.28 | 161.41 | 200.56 | 305.70 | 0.11 | 0.19 | 25.49 | – |
| full screen, fresh | ghostty_dart_flutter | 903/900 | 31.95 | 35.87 | 53.39 | 102.49 | 105.03 | 111.57 | 133.48 | 187.44 | 0.35 | 0.49 | 32.30 | missed (≤ 4.0 / ≤ 4.0) |
| full screen, fresh | xterm 4.0.0 | 900/900 | 19.92 | 24.71 | 35.56 | 56.22 | 161.84 | 178.30 | 234.28 | 333.31 | 1.66 | 2.77 | 21.58 | – |
| full screen, fresh | xterm2 5.4.0 | 901/900 | 24.15 | 28.71 | 37.19 | 86.37 | 148.32 | 162.19 | 190.39 | 306.07 | 1.35 | 2.16 | 25.51 | – |
| scroll (cat) | ghostty_dart_flutter | 900/900 | 1.71 | 2.14 | 3.21 | 6.90 | 103.19 | 109.61 | 140.93 | 220.78 | 0.05 | 0.51 | 1.76 | – |
| scroll (cat) | xterm 4.0.0 | 901/900 | 5.81 | 8.57 | 14.16 | 19.23 | 91.44 | 99.81 | 127.50 | 167.69 | 0.06 | 0.10 | 5.87 | – |
| scroll (cat) | xterm2 5.4.0 | 901/900 | 6.38 | 9.05 | 13.07 | 19.68 | 94.21 | 102.52 | 126.12 | 182.87 | 0.05 | 0.12 | 6.43 | – |
| htop-like (20 % of cells) | ghostty_dart_flutter | 903/900 | 33.25 | 37.04 | 51.39 | 92.12 | 106.49 | 113.25 | 124.34 | 179.78 | 0.07 | 0.12 | 33.32 | – |
| htop-like (20 % of cells) | xterm 4.0.0 | 900/900 | 19.28 | 23.55 | 35.08 | 58.96 | 159.19 | 174.91 | 209.34 | 317.97 | 0.35 | 0.72 | 19.63 | – |
| htop-like (20 % of cells) | xterm2 5.4.0 | 900/900 | 23.71 | 28.00 | 37.25 | 86.36 | 148.91 | 163.02 | 191.47 | 282.43 | 0.31 | 0.54 | 24.02 | – |
| full screen, warm (cache replay) | ghostty_dart_flutter | 901/900 | 2.63 | 3.47 | 6.13 | 12.38 | 103.43 | 110.91 | 123.24 | 178.02 | 0.41 | 1.57 | 3.05 | UI met, raster missed (≤ 4.0 / ≤ 4.0) |
| full screen, warm (cache replay) | xterm 4.0.0 | 900/900 | 18.79 | 22.80 | 32.87 | 59.98 | 160.79 | 178.18 | 215.05 | 315.53 | 1.64 | 2.67 | 20.42 | – |
| full screen, warm (cache replay) | xterm2 5.4.0 | 900/900 | 24.48 | 29.43 | 36.21 | 71.91 | 147.73 | 164.29 | 178.69 | 283.29 | 1.35 | 2.06 | 25.83 | – |

Write + UI average per pass (ms), all three passes:

| Scenario | ghostty_dart_flutter | xterm 4.0.0 | xterm2 5.4.0 |
|---|---|---|---|
| idle | 0.14 / 0.15 / 0.14 | 0.16 / 0.15 / 0.15 | 0.15 / 0.15 / 0.14 |
| 3 dirty rows | 2.52 / 2.61 / 2.39 | 19.62 / 19.11 / 18.32 | 25.48 / 25.91 / 23.28 |
| full screen, fresh | 33.17 / 32.30 / 31.19 | 22.74 / 21.49 / 21.58 | 25.41 / 25.69 / 25.09 |
| scroll (cat) | 1.89 / 1.80 / 1.71 | 5.89 / 6.57 / 5.73 | 6.49 / 6.94 / 6.25 |
| htop-like (20 % of cells) | 36.10 / 32.93 / 33.32 | 19.63 / 19.13 / 19.76 | 24.80 / 24.03 / 23.65 |
| full screen, warm (cache replay) | 3.37 / 3.01 / 3.02 | 21.38 / 20.16 / 20.42 | 27.17 / 24.69 / 25.83 |

What this run shows, and what it does not:

- **Where `ghostty_dart_flutter` is slower than xterm 4.0.0:** a full
  screen of new text (32.30 ms write + UI against 21.58, 1.5× slower) and
  the htop-like screen where every row changes (33.32 against 19.63, 1.7×
  slower; xterm2 is also faster in both). The view lays out one paragraph
  per changed row, about 0.5 ms for a 200-column styled row on this VM;
  the xterm widgets draw one cached paragraph per cell, keyed by character
  and style (`xterm` 4.0.0 `lib/src/ui/painter.dart`, a 10,240-entry
  cache), which this alphabet keeps warm whatever the text. A glyph atlas
  (ADR 0011's v2) is the planned answer; until then, these are the cases
  to expect it to lose.
- **Where it is faster:** few changed rows per frame (3 dirty rows: 2.49
  against 19.11, about 7.7×) and scrolling output (`cat`: 1.76 against
  5.87, about 3.3×). In both, only the rows that changed are laid out;
  scrolled rows keep their pictures.
- **Cache replay:** 3.05 ms against 20.42 because the eight repeated
  screens are replayed from the view's row-picture cache, not drawn. It
  says how cheap a cache hit is, not how fast new output is drawn.
- **ADR 0011 targets on this VM:** UI met for idle (0.14 ≤ 0.5) and for
  the cache replay (3.05 ≤ 4); UI missed for 3 dirty rows (2.49 > 1) and
  for a fresh full screen (32.30 > 4). Raster is missed in every scenario
  (software rasteriser).
- **Raster is software here.** About 100 ms per frame for
  `ghostty_dart_flutter` and 90–160 ms for the xterm widgets, even idle:
  Mesa's software rasteriser redraws the whole 3600 × 2200 px window. The
  absolute numbers say nothing about a GPU.
- **How the renderer got here** (2026-11-10): the first run measured 63.56
  ms UI for the cache-replay scenario (then labelled "full screen, warm").
  Probes put it in paragraph creation: one paragraph per style run from a
  4,096-entry cache that this stream's ~11,500 distinct runs defeated.
  Rows of several runs are now one paragraph, and row pictures are cached
  by content within a 16 MiB per-view budget. The fresh, scroll and
  htop-like scenarios were added afterwards because the replay scenario
  had stopped measuring text drawing; they have no earlier numbers.
- **Write** stays under 0.4 ms on average for `ghostty_dart_flutter`
  (parsing included), against up to 1.7 ms for the xterm widgets.
- In the CUP scenarios nothing scrolls. The scroll scenario does scroll,
  into the default scrollback (libghostty-vt's byte limit, xterm's 1,000
  lines); libghostty-vt 1.0.0's slower line-limited scrollback (upstream
  discussion ghostty-org/ghostty#15157; the fix, PR ghostty-org/ghostty#15173,
  merged into upstream `main` on 2026-11-10, is not in a 1.0.x release
  yet, checked that day) is not involved, since the controller uses the
  byte limit.

### Grid pixel check on the device renderer

`mise run test:grid-pixels` (`integration_test/grid_pixel_test.dart`) is
the device half of the check `ghostty_dart_flutter` runs on
flutter_tester's software raster: three 200-column rows of `|` (regular,
bold, italic) through `VtTerminalView`, read back with
`RenderRepaintBoundary.toImage`; the first lit device pixel of each cell
must sit at `col × widthPx + constant` within 1 px, at DPR 1, 1.5, 2 and
3 and font sizes 11, 13 and 15.5. The renderer is read from the traced
on-screen frame.

The pixels come from that **offscreen** `toImage` snapshot, rendered by
the same engine backend but not into the window's surface, so anything
specific to the on-screen surface (its multisampling, the compositor) is
not covered. Only `|` glyphs are drawn: the check catches advance drift
across the row, not per-glyph bearing differences.

On 2026-11-10, on the machine above (`GDK_SCALE=2 xvfb-run -a -s '-screen
0 3840x2400x24' mise run test:grid-pixels`): **Impeller (OpenGL ES), 12 of
12 cases with 0 px deviation and 0 px drift at column 199.** The same run
with `--renderer=skia` (`--no-enable-impeller`) also gave 0 px in all 12
cases, but its timeline had no Impeller events and no Skia ones either
(Skia is only traced with `--trace-skia`), so it does not prove which
renderer drew it. Both are Mesa's software rasteriser; a GPU driver may
round glyph positions differently, so re-run it on real hardware.

### Dependency audit (frame benchmark)

Checked on 2026-11-10 against the pub.dev API (versions, dates, and archive
sha256 equal to `pubspec.lock`), with the sources read in `~/.pub-cache`.
The lockfile diff adds exactly these entries, and `mise run cooldown`
passes.

| Package | Version | Published | Why it is here | `hook/` or build-time code |
|---|---|---|---|---|
| `xterm2` | 5.4.0 | 2026-10-21 | widget under test | none (no `hook/`, no native code) |
| `flutter_pty` | 0.4.2 | 2025-01-06 | demo app (`apps/demo`) | a small C library built by the Flutter plugin build, no downloads (below) |
| `integration_test`, `flutter_driver`, `fuchsia_remote_debug_protocol` | SDK | – | the harness | none |
| `webdriver` | 3.2.0 | 2026-09-09 | flutter_driver | none |
| `sync_http` | 0.3.1 | 2022-06-15 | webdriver | none |

`xterm` 4.0.0 was already locked for the parser benchmark.

**flutter_pty 0.4.2 native build**, read 2026-11-10:
- `linux/CMakeLists.txt` and `windows/CMakeLists.txt` only
  `add_subdirectory(../src)`. That builds one shared library from
  `src/flutter_pty.c`, which includes Dart's `dart_api_dl.c`, then
  `forkpty.c` + `flutter_pty_unix.c` on Unix or `flutter_pty_win.c`
  (ConPTY) on Windows.
- The macOS and iOS podspecs compile a forwarder of the same file, so the
  macOS demo needs CocoaPods.
- There is no `ExternalProject`, `FetchContent`, `file(DOWNLOAD)`,
  `execute_process` or network access anywhere, and no build hook.
- The Android `build.gradle` declares the Android Gradle Plugin 8.1.0 from
  Google's Maven repository, as every Android plugin does. The demo does not
  build for Android.

Its runtime defects and what the demo does about them are listed under
"Known limitations" in `apps/demo/README.md`.
