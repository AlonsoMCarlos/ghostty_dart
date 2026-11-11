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
the same per-frame byte streams into four widgets and records the frame
timeline with `integration_test`'s `traceTimeline` under `flutter drive
--profile`, summarised with `flutter_driver`'s `TimelineSummary` as the
[Flutter profiling
cookbook](https://docs.flutter.dev/cookbook/testing/integration/profiling)
describes (checked 2026-11-10).

| Widget | Package | Input |
|---|---|---|
| `ghostty_dart_flutter` | this workspace, `VtTerminalView` with its default glyph atlas (ADR 0012) | `Uint8List` via `writeBytes` |
| `ghostty_dart_flutter (paragraphs)` | the same view with `textRendering: VtTextRendering.paragraphs` (row paragraphs, ADR 0011) | `Uint8List` via `writeBytes` |
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
headlessly: the streams, the report, and that all four widgets end up with
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
- **Summaries in the app:** each run's timeline is summarised inside the
  benchmark app right after the run (`TimelineSummary.summarize`), written
  to `build/<key>.timeline{,_summary}.json` (`BENCH_OUT_DIR`), and dropped
  before the next run; only the summaries go to the driver. Until
  2026-11-10 every timeline was sent to the driver at the end and
  summarised there, which held all of them in memory at once in both
  processes: a 5-widget run (90 timelines) was killed for low memory
  while its driver summarised them.
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

The run of 2026-11-10 after the glyph atlas became the default (ADR 0012),
with four widgets: `ghostty_dart_flutter` (atlas), the same view with
`VtTextRendering.paragraphs` (the previous renderer, ADR 0011), xterm
4.0.0 and xterm2 5.4.0, on a cloud VM **without a GPU**. Read the raster
columns as software rendering and the UI columns as one 6-core VM; neither
predicts a phone or a desktop with a GPU. Re-run on your hardware before
quoting a number.

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
| Frames | 300 traced per run (+ 32 warm-up), 3 passes, widget order rotated; every run recorded all its frames |
| Semantics | On for all four widgets: the Linux embedder enabled it (all 72 timelines have `Semantics.*` events). `ghostty_dart_flutter` then also reads its visible text at most every 500 ms. |

Times in ms. UI = frame build time (build, layout, paint on the UI
thread); raster = rasterizer time; write = the synchronous write before
the frame. avg = median of the per-pass averages; p90, p99 and worst pool
all passes. The ADR verdict checks write + UI against the UI target.

| Scenario | Widget | Frames | UI avg | UI p90 | UI p99 | UI worst | Raster avg | Raster p90 | Raster p99 | Raster worst | Write avg | Write p99 | Write + UI avg | ADR target (UI / raster) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| idle | ghostty_dart_flutter | 901/900 | 0.14 | 0.18 | 0.28 | 0.54 | 122.17 | 132.10 | 139.96 | 157.80 | 0.00 | 0.00 | 0.14 | UI met, raster missed (≤ 0.5 / ≤ 1.0) |
| idle | ghostty_dart_flutter (paragraphs) | 901/900 | 0.15 | 0.19 | 0.31 | 1.25 | 103.39 | 110.81 | 117.43 | 123.21 | 0.00 | 0.00 | 0.15 | UI met, raster missed (≤ 0.5 / ≤ 1.0) |
| idle | xterm 4.0.0 | 900/900 | 0.16 | 0.17 | 0.23 | 2.88 | 155.17 | 170.99 | 183.61 | 202.19 | 0.00 | 0.00 | 0.16 | – |
| idle | xterm2 5.4.0 | 900/900 | 0.15 | 0.18 | 0.24 | 0.66 | 137.71 | 149.43 | 158.98 | 163.65 | 0.00 | 0.00 | 0.15 | – |
| 3 dirty rows | ghostty_dart_flutter | 901/900 | 0.85 | 0.99 | 1.38 | 4.90 | 126.08 | 134.05 | 141.16 | 148.28 | 0.07 | 0.18 | 0.92 | UI met, raster missed (≤ 1.0 / ≤ 2.0) |
| 3 dirty rows | ghostty_dart_flutter (paragraphs) | 900/900 | 2.43 | 2.96 | 6.43 | 8.56 | 97.71 | 109.41 | 115.47 | 126.50 | 0.06 | 0.14 | 2.49 | missed (≤ 1.0 / ≤ 2.0) |
| 3 dirty rows | xterm 4.0.0 | 900/900 | 19.21 | 23.02 | 28.43 | 32.05 | 156.96 | 174.41 | 187.74 | 208.72 | 0.10 | 0.16 | 19.31 | – |
| 3 dirty rows | xterm2 5.4.0 | 900/900 | 24.74 | 30.07 | 35.85 | 46.16 | 146.51 | 162.77 | 175.58 | 179.71 | 0.09 | 0.15 | 24.83 | – |
| full screen, fresh | ghostty_dart_flutter | 900/900 | 6.02 | 8.62 | 12.22 | 17.46 | 125.40 | 134.04 | 142.21 | 150.69 | 0.50 | 4.38 | 6.52 | missed (≤ 4.0 / ≤ 4.0) |
| full screen, fresh | ghostty_dart_flutter (paragraphs) | 901/900 | 32.35 | 36.26 | 49.91 | 68.38 | 98.26 | 110.72 | 117.17 | 135.97 | 0.36 | 0.51 | 32.70 | missed (≤ 4.0 / ≤ 4.0) |
| full screen, fresh | xterm 4.0.0 | 900/900 | 20.17 | 25.40 | 32.77 | 43.46 | 159.90 | 175.78 | 191.05 | 198.69 | 1.67 | 5.17 | 21.84 | – |
| full screen, fresh | xterm2 5.4.0 | 901/900 | 25.69 | 30.36 | 35.60 | 41.49 | 147.98 | 163.28 | 175.53 | 182.33 | 1.19 | 1.72 | 26.88 | – |
| scroll (cat) | ghostty_dart_flutter | 900/900 | 1.18 | 1.40 | 2.28 | 9.97 | 106.19 | 110.83 | 117.84 | 159.56 | 0.05 | 1.01 | 1.23 | – |
| scroll (cat) | ghostty_dart_flutter (paragraphs) | 900/900 | 1.83 | 2.19 | 3.38 | 7.30 | 103.32 | 108.31 | 115.75 | 141.55 | 0.07 | 1.14 | 1.90 | – |
| scroll (cat) | xterm 4.0.0 | 900/900 | 5.95 | 8.85 | 12.54 | 16.07 | 77.47 | 96.98 | 105.48 | 124.70 | 0.07 | 0.12 | 6.02 | – |
| scroll (cat) | xterm2 5.4.0 | 900/900 | 6.84 | 9.74 | 14.61 | 20.20 | 82.35 | 99.94 | 106.72 | 147.91 | 0.06 | 0.11 | 6.91 | – |
| htop-like (20 % of cells) | ghostty_dart_flutter | 901/900 | 6.05 | 8.96 | 12.97 | 15.05 | 126.75 | 135.94 | 144.01 | 149.97 | 0.14 | 1.34 | 6.19 | – |
| htop-like (20 % of cells) | ghostty_dart_flutter (paragraphs) | 901/900 | 35.36 | 38.71 | 52.17 | 62.48 | 98.05 | 110.81 | 117.23 | 124.58 | 0.07 | 0.12 | 35.43 | – |
| htop-like (20 % of cells) | xterm 4.0.0 | 900/900 | 20.17 | 24.26 | 31.02 | 56.02 | 158.32 | 173.99 | 187.74 | 239.79 | 0.34 | 0.74 | 20.51 | – |
| htop-like (20 % of cells) | xterm2 5.4.0 | 901/900 | 24.32 | 28.75 | 34.53 | 43.61 | 148.01 | 162.14 | 172.86 | 193.25 | 0.29 | 0.41 | 24.61 | – |
| full screen, warm (cache replay) | ghostty_dart_flutter | 900/900 | 5.52 | 8.27 | 11.89 | 14.86 | 127.04 | 133.65 | 140.90 | 148.23 | 0.43 | 4.36 | 5.94 | missed (≤ 4.0 / ≤ 4.0) |
| full screen, warm (cache replay) | ghostty_dart_flutter (paragraphs) | 900/900 | 2.83 | 3.48 | 7.24 | 9.27 | 99.60 | 109.44 | 115.52 | 122.96 | 0.43 | 3.59 | 3.27 | UI met, raster missed (≤ 4.0 / ≤ 4.0) |
| full screen, warm (cache replay) | xterm 4.0.0 | 900/900 | 19.20 | 23.61 | 30.76 | 35.70 | 157.73 | 175.59 | 189.30 | 201.56 | 1.65 | 3.18 | 20.85 | – |
| full screen, warm (cache replay) | xterm2 5.4.0 | 901/900 | 24.34 | 29.62 | 35.22 | 46.61 | 146.38 | 162.09 | 173.17 | 183.30 | 1.21 | 1.81 | 25.54 | – |

Write + UI average per pass (ms):

| Scenario | Widget | Pass 1 | Pass 2 | Pass 3 |
|---|---|---:|---:|---:|
| idle | ghostty_dart_flutter | 0.14 | 0.14 | 0.15 |
| idle | ghostty_dart_flutter (paragraphs) | 0.15 | 0.15 | 0.15 |
| idle | xterm 4.0.0 | 0.15 | 0.16 | 0.16 |
| idle | xterm2 5.4.0 | 0.15 | 0.14 | 0.15 |
| 3 dirty rows | ghostty_dart_flutter | 0.92 | 0.93 | 0.84 |
| 3 dirty rows | ghostty_dart_flutter (paragraphs) | 2.49 | 2.54 | 2.45 |
| 3 dirty rows | xterm 4.0.0 | 19.31 | 19.62 | 18.36 |
| 3 dirty rows | xterm2 5.4.0 | 24.83 | 26.70 | 23.56 |
| full screen, fresh | ghostty_dart_flutter | 6.52 | 6.58 | 5.65 |
| full screen, fresh | ghostty_dart_flutter (paragraphs) | 32.70 | 33.52 | 31.07 |
| full screen, fresh | xterm 4.0.0 | 21.83 | 23.15 | 20.07 |
| full screen, fresh | xterm2 5.4.0 | 26.88 | 27.32 | 24.79 |
| scroll (cat) | ghostty_dart_flutter | 1.30 | 1.23 | 1.18 |
| scroll (cat) | ghostty_dart_flutter (paragraphs) | 1.92 | 1.88 | 1.71 |
| scroll (cat) | xterm 4.0.0 | 6.02 | 6.30 | 5.76 |
| scroll (cat) | xterm2 5.4.0 | 6.91 | 7.01 | 6.53 |
| htop-like (20 % of cells) | ghostty_dart_flutter | 6.34 | 6.22 | 5.38 |
| htop-like (20 % of cells) | ghostty_dart_flutter (paragraphs) | 35.43 | 35.55 | 32.89 |
| htop-like (20 % of cells) | xterm 4.0.0 | 20.51 | 21.62 | 18.27 |
| htop-like (20 % of cells) | xterm2 5.4.0 | 24.61 | 25.79 | 22.95 |
| full screen, warm (cache replay) | ghostty_dart_flutter | 6.53 | 5.92 | 5.59 |
| full screen, warm (cache replay) | ghostty_dart_flutter (paragraphs) | 3.37 | 3.27 | 3.00 |
| full screen, warm (cache replay) | xterm 4.0.0 | 20.84 | 20.85 | 21.14 |
| full screen, warm (cache replay) | xterm2 5.4.0 | 26.72 | 25.51 | 25.52 |

What this run shows, and what it does not:

- **New text is no longer the weak spot.** With the atlas a full screen
  of new text costs 6.52 ms write + UI (paragraphs: 32.70; xterm 4.0.0:
  21.84, about 3.3× slower) and the htop-like screen 6.19 (paragraphs
  35.43; xterm 4.0.0 20.51, 3.3×). Row recording no longer lays out text:
  each row is one `drawRawAtlas` call (two when it mixes tinted and
  untinted glyphs) from an atlas of rasterised glyphs (ADR 0012).
- **Few changed rows and scrolling:** 3 dirty rows 0.92 ms (paragraphs
  2.49, xterm 4.0.0 19.31, about 21×), `cat` 1.23 (paragraphs 1.90, xterm
  6.02, about 4.9×).
- **Cache replay got slower with the atlas:** 5.94 ms against 3.27 with
  paragraphs (xterm 4.0.0: 20.85). These synthetic screens use ~13
  luminance levels in four faces, so the atlas needs four 2 MiB pages,
  which share the 16 MiB budget with the row pictures; the eight-screen
  cycle (480 rows) no longer fits and part of it is recorded again every
  frame. A shell session needs one or two pages.
- **ADR 0011 targets on this VM:** UI met for idle (0.14 ≤ 0.5) and 3
  dirty rows (0.92 ≤ 1); missed for a fresh full screen (6.52 > 4) and
  now for the cache replay (5.94 > 4). Raster is missed in every scenario
  (software rasteriser).
- **Raster is software here, and the atlas costs more of it:** about 122–
  127 ms per frame with the atlas against 98–104 ms with paragraphs and
  146–160 ms for the xterm widgets (77–82 ms for them while scrolling).
  Mesa's software rasteriser redraws the whole 3600 × 2200 px window every
  frame, and each glyph is a textured quad; tinted quads go through
  Impeller's blend pipeline. Glyphs whose colour is exactly their
  luminance level's grey (the default foreground) are drawn untinted,
  which cut raster time by ~17 % in a same-run probe; a `cullRect` and the
  paint's anti-aliasing made no difference. Whether a GPU shows the same
  ratio is not measured yet.
- **Write** stays under 0.5 ms on average for `ghostty_dart_flutter`
  (parsing included), against up to 1.7 ms for the xterm widgets.
- **History** (2026-11-10): the first run measured 63.56 ms UI for the
  cache-replay scenario (then labelled "full screen, warm"); row
  paragraphs and the content-keyed picture cache brought it to 3.05, but
  a fresh full screen still cost 32.30 (xterm 4.0.0: 21.58). The glyph
  atlas was built for that case. A five-widget run of the atlas spike was
  killed for low memory while its driver summarised 90 timelines; the
  timelines are now summarised in the app, one at a time.
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
bold, italic) through `VtTerminalView` on both text paths, read back with
`RenderRepaintBoundary.toImage`; the first lit device pixel of each cell
must sit at `col × widthPx + constant` within 1 px, at DPR 1, 1.5, 2 and
3 and font sizes 11, 13 and 15.5. The renderer is read from the traced
on-screen frame.

The pixels come from that **offscreen** `toImage` snapshot, rendered by
the same engine backend but not into the window's surface, so anything
specific to the on-screen surface (its multisampling, the compositor) is
not covered. Only `|` glyphs are drawn: the check catches advance drift
across the row, not per-glyph bearing differences.

It runs every case on both text paths (`VtTextRendering.atlas` and
`.paragraphs`). On 2026-11-10, after the atlas became the default
(`xvfb-run -a mise run test:grid-pixels`): **Impeller (OpenGL ES), 24 of
24 cases (12 per path) with 0 px deviation and 0 px drift at column
199.** The earlier run, paragraphs only (`GDK_SCALE=2 xvfb-run -a -s
'-screen 0 3840x2400x24' mise run test:grid-pixels`), gave 12 of 12 at
0 px too. The same run
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
| `flutter_pty2` | 3.0.0 | 2026-10-21 | demo app (`apps/demo`); replaced `flutter_pty` 0.4.2 on 2026-11-10 | a build hook that compiles its own C with `native_toolchain_c`, no downloads (below) |
| `integration_test`, `flutter_driver`, `fuchsia_remote_debug_protocol` | SDK | – | the harness | none |
| `webdriver` | 3.2.0 | 2026-09-09 | flutter_driver | none |
| `sync_http` | 0.3.1 | 2022-06-15 | webdriver | none |

`xterm` 4.0.0 was already locked for the parser benchmark.

**flutter_pty2 3.0.0 native build**, read 2026-11-10 (archive sha256
`9802f793109fe7241cc172780571d501e50db6b247624a6b7c4df889bb9cbfe6`, equal to
the pub.dev API's `archive_sha256` and to `pubspec.lock`):
- `hook/build.dart` (54 lines) only calls `CBuilder.library` of
  `native_toolchain_c` 0.19.5 (already locked) on the package's own C files:
  Dart's `dart_api_dl.c`, `src/common/*.c`, then `src/unix/*.c` or
  `src/windows/*.c` (ConPTY). Every `#include` is a system header or one of
  its own.
- There is no network access, no `Process` and no download in the hook or
  the sources. `src/CMakeLists.txt` only builds the same library for the
  package's own native tests and is not used by the hook.
- It is not a Flutter plugin, so the macOS demo no longer needs CocoaPods.
  Building it needs clang on Linux (native_toolchain_c has no gcc
  fallback), Xcode on macOS and MSVC on Windows.
- At run time it honours `FLUTTER_PTY2_LIBRARY`, which makes it load a
  library from that path instead of the bundled one (the same class of risk
  as `LD_PRELOAD`).
- The full comparison with `flutter_pty`, `pty2` and `portable_pty`:
  `docs/internal/research/2026-11-10-pty-packages.md`.

Its runtime defects and what the demo does about them are listed under
"Known limitations" in `apps/demo/README.md`.
