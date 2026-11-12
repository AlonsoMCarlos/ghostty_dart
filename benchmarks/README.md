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

The run of 2026-11-11, after the cache-budget fix of ADR 0012's
amendment of the same day (the glyph atlas is the default), with four
widgets: `ghostty_dart_flutter` (atlas), the same view with
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
| OS | Debian 13, Linux 6.12.116 |
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
| idle | ghostty_dart_flutter | 900/900 | 0.14 | 0.18 | 0.32 | 3.56 | 122.33 | 129.40 | 153.55 | 218.48 | 0.00 | 0.00 | 0.14 | UI met, raster missed (≤ 0.5 / ≤ 1.0) |
| idle | ghostty_dart_flutter (paragraphs) | 901/900 | 0.14 | 0.18 | 0.29 | 0.52 | 100.41 | 109.57 | 121.63 | 182.60 | 0.00 | 0.00 | 0.14 | UI met, raster missed (≤ 0.5 / ≤ 1.0) |
| idle | xterm 4.0.0 | 900/900 | 0.15 | 0.17 | 0.28 | 2.92 | 150.77 | 165.60 | 206.41 | 318.92 | 0.00 | 0.00 | 0.15 | – |
| idle | xterm2 5.4.0 | 900/900 | 0.15 | 0.18 | 0.26 | 2.04 | 134.47 | 145.43 | 194.90 | 290.97 | 0.00 | 0.00 | 0.15 | – |
| 3 dirty rows | ghostty_dart_flutter | 900/900 | 0.82 | 0.96 | 1.44 | 6.79 | 124.92 | 131.90 | 177.95 | 246.97 | 0.06 | 0.11 | 0.88 | UI met, raster missed (≤ 1.0 / ≤ 2.0) |
| 3 dirty rows | ghostty_dart_flutter (paragraphs) | 901/900 | 2.43 | 2.96 | 6.12 | 9.86 | 100.11 | 107.97 | 142.59 | 178.57 | 0.05 | 0.13 | 2.48 | missed (≤ 1.0 / ≤ 2.0) |
| 3 dirty rows | xterm 4.0.0 | 900/900 | 19.84 | 23.93 | 36.09 | 73.02 | 151.91 | 168.13 | 207.88 | 312.11 | 0.11 | 0.22 | 19.94 | – |
| 3 dirty rows | xterm2 5.4.0 | 900/900 | 26.31 | 31.17 | 44.02 | 82.23 | 144.55 | 158.10 | 181.73 | 291.94 | 0.10 | 0.18 | 26.40 | – |
| full screen, fresh | ghostty_dart_flutter | 901/900 | 5.92 | 8.97 | 13.07 | 16.65 | 125.38 | 132.49 | 156.99 | 218.37 | 0.47 | 3.54 | 6.39 | missed (≤ 4.0 / ≤ 4.0) |
| full screen, fresh | ghostty_dart_flutter (paragraphs) | 901/900 | 32.77 | 36.01 | 52.81 | 113.49 | 97.71 | 110.42 | 122.99 | 183.61 | 0.35 | 0.49 | 33.13 | missed (≤ 4.0 / ≤ 4.0) |
| full screen, fresh | xterm 4.0.0 | 900/900 | 20.88 | 25.57 | 33.70 | 62.37 | 154.78 | 172.89 | 205.04 | 302.97 | 1.63 | 3.39 | 22.52 | – |
| full screen, fresh | xterm2 5.4.0 | 900/900 | 26.33 | 30.71 | 42.02 | 100.94 | 144.16 | 158.49 | 172.53 | 322.73 | 1.22 | 2.06 | 27.55 | – |
| scroll (cat) | ghostty_dart_flutter | 901/900 | 1.14 | 1.33 | 2.33 | 5.03 | 104.98 | 110.33 | 136.49 | 182.35 | 0.10 | 1.48 | 1.24 | – |
| scroll (cat) | ghostty_dart_flutter (paragraphs) | 900/900 | 1.75 | 2.14 | 3.81 | 8.58 | 101.65 | 106.00 | 135.74 | 176.67 | 0.10 | 3.52 | 1.84 | – |
| scroll (cat) | xterm 4.0.0 | 902/900 | 6.35 | 9.12 | 14.12 | 20.40 | 79.44 | 97.74 | 107.71 | 153.11 | 0.06 | 0.13 | 6.42 | – |
| scroll (cat) | xterm2 5.4.0 | 900/900 | 7.01 | 10.02 | 14.98 | 31.39 | 82.33 | 98.94 | 111.86 | 175.34 | 0.06 | 0.11 | 7.07 | – |
| htop-like (20 % of cells) | ghostty_dart_flutter | 900/900 | 6.04 | 8.80 | 14.17 | 21.95 | 126.39 | 134.25 | 167.18 | 217.60 | 0.12 | 1.17 | 6.15 | – |
| htop-like (20 % of cells) | ghostty_dart_flutter (paragraphs) | 901/900 | 35.06 | 38.55 | 59.61 | 91.31 | 102.05 | 111.51 | 125.35 | 191.53 | 0.07 | 0.11 | 35.13 | – |
| htop-like (20 % of cells) | xterm 4.0.0 | 900/900 | 20.80 | 25.30 | 32.06 | 65.78 | 152.56 | 167.64 | 200.77 | 314.25 | 0.35 | 0.78 | 21.15 | – |
| htop-like (20 % of cells) | xterm2 5.4.0 | 901/900 | 25.19 | 30.65 | 40.35 | 99.66 | 145.04 | 158.79 | 173.34 | 296.60 | 0.29 | 0.45 | 25.48 | – |
| full screen, warm (cache replay) | ghostty_dart_flutter | 900/900 | 2.67 | 3.51 | 7.13 | 10.83 | 125.18 | 132.23 | 152.23 | 215.89 | 0.47 | 4.36 | 3.14 | UI met, raster missed (≤ 4.0 / ≤ 4.0) |
| full screen, warm (cache replay) | ghostty_dart_flutter (paragraphs) | 901/900 | 2.73 | 3.49 | 6.81 | 10.19 | 100.06 | 108.88 | 137.90 | 180.26 | 0.43 | 2.59 | 3.16 | UI met, raster missed (≤ 4.0 / ≤ 4.0) |
| full screen, warm (cache replay) | xterm 4.0.0 | 900/900 | 20.16 | 25.03 | 34.46 | 73.41 | 153.23 | 169.46 | 190.61 | 313.18 | 1.68 | 3.80 | 21.84 | – |
| full screen, warm (cache replay) | xterm2 5.4.0 | 900/900 | 26.73 | 31.42 | 41.91 | 98.76 | 144.25 | 160.47 | 181.24 | 258.98 | 1.22 | 1.99 | 27.95 | – |

Write + UI average per pass (ms):

| Scenario | Widget | Pass 1 | Pass 2 | Pass 3 |
|---|---|---:|---:|---:|
| idle | ghostty_dart_flutter | 0.14 | 0.14 | 0.16 |
| idle | ghostty_dart_flutter (paragraphs) | 0.14 | 0.14 | 0.15 |
| idle | xterm 4.0.0 | 0.15 | 0.15 | 0.16 |
| idle | xterm2 5.4.0 | 0.15 | 0.16 | 0.15 |
| 3 dirty rows | ghostty_dart_flutter | 0.87 | 0.91 | 0.86 |
| 3 dirty rows | ghostty_dart_flutter (paragraphs) | 2.46 | 2.54 | 2.48 |
| 3 dirty rows | xterm 4.0.0 | 19.89 | 19.95 | 20.55 |
| 3 dirty rows | xterm2 5.4.0 | 26.41 | 26.40 | 25.95 |
| full screen, fresh | ghostty_dart_flutter | 6.55 | 6.39 | 5.77 |
| full screen, fresh | ghostty_dart_flutter (paragraphs) | 32.79 | 33.45 | 33.12 |
| full screen, fresh | xterm 4.0.0 | 22.85 | 22.49 | 22.52 |
| full screen, fresh | xterm2 5.4.0 | 27.55 | 27.87 | 26.44 |
| scroll (cat) | ghostty_dart_flutter | 1.24 | 1.28 | 1.15 |
| scroll (cat) | ghostty_dart_flutter (paragraphs) | 1.90 | 1.90 | 1.84 |
| scroll (cat) | xterm 4.0.0 | 6.17 | 6.42 | 6.72 |
| scroll (cat) | xterm2 5.4.0 | 6.97 | 7.08 | 7.29 |
| htop-like (20 % of cells) | ghostty_dart_flutter | 6.35 | 6.15 | 5.58 |
| htop-like (20 % of cells) | ghostty_dart_flutter (paragraphs) | 35.08 | 35.59 | 35.13 |
| htop-like (20 % of cells) | xterm 4.0.0 | 21.15 | 21.79 | 20.13 |
| htop-like (20 % of cells) | xterm2 5.4.0 | 25.48 | 27.42 | 25.26 |
| full screen, warm (cache replay) | ghostty_dart_flutter | 3.20 | 3.20 | 2.94 |
| full screen, warm (cache replay) | ghostty_dart_flutter (paragraphs) | 3.18 | 3.28 | 2.83 |
| full screen, warm (cache replay) | xterm 4.0.0 | 21.18 | 21.88 | 23.26 |
| full screen, warm (cache replay) | xterm2 5.4.0 | 27.95 | 27.93 | 28.37 |

What this run shows, and what it does not:

- **Cache replay is back to paragraph level.** 3.14 ms write + UI with
  the atlas against 3.16 with paragraphs (xterm 4.0.0: 21.84). The run of
  2026-11-10 measured 5.94 (5.97 in a same-code re-run on 2026-11-11):
  the eight-screen cycle (480 rows) did not fit the picture share of the
  budget next to the atlas, and least-recently-used eviction of a cycle
  longer than the cache records every row again. Atlas pages now grow by
  slot rows, atlas-row pictures are counted by their display list, and
  pictures, atlas and paragraphs share one 16 MiB pool (ADR 0012,
  amendment of 2026-11-11), so the whole cycle stays cached.
- **New text:** a full screen of new text costs 6.39 ms write + UI with
  the atlas (paragraphs 33.13; xterm 4.0.0 22.52, about 3.5× slower) and
  the htop-like screen 6.15 (paragraphs 35.13; xterm 4.0.0 21.15, 3.4×).
  Row recording does not lay out text: each row is one `drawRawAtlas`
  call (two when it mixes tinted and untinted glyphs) from an atlas of
  rasterised glyphs (ADR 0012).
- **Few changed rows and scrolling:** 3 dirty rows 0.88 ms (paragraphs
  2.48, xterm 4.0.0 19.94, about 23×), `cat` 1.24 (paragraphs 1.84, xterm
  6.42, about 5.2×).
- **ADR 0011 targets on this VM:** UI met for idle (0.14 ≤ 0.5), 3 dirty
  rows (0.88 ≤ 1) and the cache replay (3.14 ≤ 4); missed for a fresh
  full screen (6.39 > 4). Raster is missed in every scenario (software
  rasteriser).
- **Raster is software here, and the atlas costs more of it:** about 122–
  126 ms per frame with the atlas against 98–102 ms with paragraphs and
  134–155 ms for the xterm widgets (79–82 ms for them while scrolling).
  Mesa's software rasteriser redraws the whole 3600 × 2200 px window every
  frame, and each glyph is a textured quad; tinted quads go through
  Impeller's blend pipeline. Glyphs whose colour is exactly their
  luminance level's grey (the default foreground) are drawn untinted,
  which cut raster time by ~17 % in a same-run probe; a `cullRect` and the
  paint's anti-aliasing made no difference. On a GPU the ratio reverses:
  see "Indicative run on a macOS runner (Metal)" below.
- **Write** stays under 0.5 ms on average for `ghostty_dart_flutter`
  (parsing included), against up to 1.7 ms for the xterm widgets. Its
  **p99 is noise from the software rasteriser**, not the widget: 3.5 ms
  for a fresh full screen with the atlas against 0.49 with paragraphs, but
  2.6 for the paragraph path's cache replay and 3.5 for its `cat`. A probe
  (2026-11-11, ADR 0012 amendment) found no GC in any slow write and the
  same CPU time as in fast ones; the slow writes waited 4–8 ms for a CPU
  because the bench loop's write landed in the raster thread's present
  phase, where llvmpipe rasterises on every CPU. A short UI frame puts the
  write there; with `LP_NUM_THREADS=3` the atlas write p99 was 0.62 ms
  (paragraphs 0.70). Read write p99 on this VM as scheduling, not cost.
- **History** (2026-11-10): the first run measured 63.56 ms UI for the
  cache-replay scenario (then labelled "full screen, warm"); row
  paragraphs and the content-keyed picture cache brought it to 3.05, but
  a fresh full screen still cost 32.30 (xterm 4.0.0: 21.58). The glyph
  atlas was built for that case; its first default run (2026-11-10)
  measured fresh 6.52, htop 6.19, 3 rows 0.92 and a replay regression to
  5.94 (fixed above). A five-widget run of the atlas spike was killed for
  low memory while its driver summarised 90 timelines; the timelines are
  now summarised in the app, one at a time.
- In the CUP scenarios nothing scrolls. The scroll scenario does scroll,
  into the default scrollback (libghostty-vt's byte limit, xterm's 1,000
  lines); libghostty-vt 1.0.0's slower line-limited scrollback (upstream
  discussion ghostty-org/ghostty#15157; the fix, PR ghostty-org/ghostty#15173,
  merged into upstream `main` on 2026-11-10, is not in a 1.0.x release
  yet, checked that day) is not involved, since the controller uses the
  byte limit.

### Indicative run on a macOS runner (Metal)

`.github/workflows/bench-widget.yml` (manual dispatch) runs the same
benchmark on a GitHub-hosted `macos-latest` runner: Apple M1 (virtual),
macOS 26.7.2, Impeller on Metal, DPR 1.0. Its display is 1024 × 768, so
the window is 1024 × 642 logical px and the font is 7 px
(`--font-size=7`): still 200 × 60 cells, but fewer pixels than the VM's
DPR 2, 12 px run, so compare widgets within this table, not with the
table above. The GPU is virtualised and shared: indicative numbers.
2026-11-11, run 42996476721, 3 passes × 300 frames, all 900/900 frames.

| Scenario | Widget | write + UI avg | raster avg |
|---|---|---:|---:|
| full screen, fresh | ghostty_dart_flutter | **5.16** | **1.89** |
| full screen, fresh | ghostty_dart_flutter (paragraphs) | 32.54 | 5.55 |
| full screen, fresh | xterm 4.0.0 | 21.98 | 26.45 |
| full screen, fresh | xterm2 5.4.0 | 24.94 | 23.82 |
| htop-like | ghostty_dart_flutter | **4.67** | **1.79** |
| htop-like | ghostty_dart_flutter (paragraphs) | 34.66 | 5.83 |
| htop-like | xterm 4.0.0 | 17.93 | 24.26 |
| htop-like | xterm2 5.4.0 | 21.05 | 22.74 |
| 3 dirty rows | ghostty_dart_flutter | **1.05** | **1.98** |
| 3 dirty rows | ghostty_dart_flutter (paragraphs) | 2.77 | 4.23 |
| 3 dirty rows | xterm 4.0.0 | 21.64 | 29.48 |
| 3 dirty rows | xterm2 5.4.0 | 22.55 | 22.20 |
| scroll (cat) | ghostty_dart_flutter | **1.67** | **0.91** |
| scroll (cat) | ghostty_dart_flutter (paragraphs) | 2.29 | 1.45 |
| scroll (cat) | xterm 4.0.0 | 4.06 | 7.03 |
| scroll (cat) | xterm2 5.4.0 | 4.19 | 6.84 |
| cache replay | ghostty_dart_flutter | 2.98 | **1.72** |
| cache replay | ghostty_dart_flutter (paragraphs) | **2.81** | 4.20 |
| cache replay | xterm 4.0.0 | 21.29 | 26.79 |
| cache replay | xterm2 5.4.0 | 23.56 | 22.12 |

Idle: 0.20 ms UI for every widget; raster 1.94 (atlas), 5.93
(paragraphs), 25.04 and 19.49 (xterm, xterm2). On this GPU the atlas
rasterises 2–3× faster than paragraphs, the opposite of llvmpipe.
`test:grid-pixels` on Metal: 24 of 24 cases at 0 px, both text paths.

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
199**, again on 2026-11-11 after the cache-budget fix. The earlier run, paragraphs only (`GDK_SCALE=2 xvfb-run -a -s
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

## Firehose benchmark (CPU per MB under a flood)

What does it cost to show a program that floods the terminal, such as
`tree -C` over a huge directory or `cat` of a large log? The program sets
the pace there, so the figure of merit is not throughput but **process CPU
time per MB of output** (all threads: UI, raster, GPU driver, IO, GC), next
to the frames drawn and memory. `benchmarks/widget/lib/firehose_main.dart`
is a plain profile-mode app (no test binding, which schedules frames of its
own) that feeds a `VtTerminalController` the way a pty does and prints one
`FIREHOSE {json}` line per run.

### Run it

Linux only (it reads `/proc`), on a display:

```sh
mise run bench:firehose                       # 40 MB at 7 MB/s, 3 runs
mise run bench:firehose -- --rate 0 --runs 1  # as fast as it is taken
mise run bench:firehose -- --configs "no view,view" --pacing balanced  # one policy
xvfb-run -a -s "-screen 0 2560x1600x24" mise run bench:firehose   # headless
```

### Methodology

- **Stream** (`lib/src/firehose.dart`): `tree -C`-like lines after the pty's
  `onlcr`: box-drawing indentation, bold blue directories, green
  executables, CRLF; ~45 bytes per line, from `Random(42)`.
  `--dart-define=FIREHOSE_ASCII=true` draws the indentation in ASCII, to
  isolate the cost of box-drawing glyphs.
- **Feed:** a producer isolate posts 4 KiB chunks (a Linux pty read) to the
  UI isolate with a 256 KiB acknowledgement window (flutter_pty2 3.0.0's
  `outputWindowBytes`) at 7 MB/s by default, about what `tree -C` produced
  over 570,000 files on the maintainer's machine (2026-11-12). Each chunk
  is one `writeBytes`.
- **Configurations** (`--configs`, all three by default): `no view` (the
  controller alone, the floor), `blank` (the controller, plus a widget of
  the view's size that only fills a rectangle, repainted at the view's
  flood cadence: what a Flutter frame costs on this machine with no
  terminal in it) and `view` (`VtTerminalView`, 200 × 60, JetBrains Mono
  12 px, atlas path). On Linux the UI isolate runs on the platform thread,
  which also presents every frame through GTK, so `blank` is the per-frame
  floor no terminal widget can go under; `view` minus `blank` is the
  view's own cost. `blank` and `view` run once per `VtFloodPacing` policy
  (`--pacing`, default `smooth,balanced,efficient`); `blank` repaints with
  the same vsync pacing as the view's seams.
- **Reported:** wall time, process CPU (`/proc/self/stat`) and CPU per
  thread name (`/proc/self/task/*/stat`), frames and build/raster time per
  frame (`FrameTiming`), frame interval percentiles, RSS at start, peak
  (sampled every 50 ms) and end. RSS includes the harness's copies of the
  stream (three of 40 MB in the first run). `ui thread ms` is the main
  thread's CPU (UI isolate plus GTK), and `ui ms/frame over no view` is
  that minus the same run's `no view`, per frame. The `FIREHOSE_ENV` line
  adds `window px` (what the embedder presents each frame) and `display`
  (`x11` or `wayland`: on X11, Flutter's Linux embedder copies every frame
  through the CPU, `fl_view_renderer.cc` at the pinned engine) and
  `refresh Hz` (`display.refreshRate`; 0 under Xvfb, read as 60). Cadence:
  `frame gap jitter ms` is the standard deviation of the gaps between
  frame starts, `frame gap irregular %` the share of gaps that are not the
  median gap's whole number of vsyncs (the jumps a viewer sees), and
  `present gap ms p10/p50/p90` the gaps between raster finishes.
- **Harness cost:** the producer isolate (a `DartWorker` thread), its
  1 ms pacing timer (the `dart:io EventHandler` thread) and the message
  hop to the UI isolate are the harness's, in every configuration. A Dart
  CPU profile of `no view` (2026-11-12) puts 66 % of the UI isolate's time
  in `ghostty_terminal_vt_write` and the rest in the harness's port and
  stream handling; `VtTerminalController.writeBytes` adds under 0.1 ms
  per MB to the parser.

### Results (2026-11-12)

Ryzen 5 3600 (6 cores), Debian 13, Xvfb with Mesa llvmpipe (no GPU: the
`llvmpipe-#` threads are the software GPU and would not exist, as CPU, on
real hardware), Impeller (OpenGL ES), DPR 1, Flutter 3.47.9 profile build.
40 MB at 7 MB/s, three runs each.

| | before | after |
|---|---:|---:|
| process CPU, ms per MB (view) | 457–473 | 154–217 |
| the same without llvmpipe | ~103 | 32–41 |
| frames in 5.8 s | 177–181 | 56–88 |
| UI thread CPU, s | 1.86–1.88 | 0.76–0.97 |
| raster thread CPU, s | 1.73–1.79 | 0.22–0.34 |
| build per frame, ms | 3.0 | 1.5 |
| no view (floor), ms per MB | 16 | 16 |
| throughput with the view at `--rate 0`, MB/s | 25 | 49 |

"Before" is ghostty_dart_flutter 0.1.0; "after" adds box drawing in the
glyph atlas (ADR 0012, amendment 2026-11-12: raster-thread CPU per frame
9.8 → 4.3 ms, the ASCII stream's cost) and the flood frame rate (ADR 0011,
amendment 2026-11-12: about 30 fps while every row is replaced each frame).
For reference, raw `VtTerminal.write` of the same stream in AOT parses
212 MB/s in 4 KiB chunks, 5 ms of CPU per MB. On this machine the flood
paints every 50–80 ms instead of ~33 ms, because GTK presents each llvmpipe
frame on the UI thread; a run on a real GPU, and at 120/144 Hz, is still to
be recorded.

### Results, second round (2026-11-12)

Same machine and stream, DPR 2 (`GDK_SCALE=2`, window 3600 × 2200 px), Xvfb
(`display: x11`). Llvmpipe limits this machine to 8–20 frames a second
whatever the view does, so the frame-rate change below cannot show here;
what can is the cost per frame and per write:

| | `blank` | `view` |
|---|---:|---:|
| UI thread per frame over `no view`, ms | 15.7–17.1 | 17.0–18.3 |
| Dart (UI isolate) per frame, from a CPU profile, ms | — | 0.7–1.9 |

Nearly all the UI thread's cost per frame is the embedder presenting the
frame, which a blank frame pays too; the view adds 1–2 ms. In the demo app
(real shell, flutter_pty2, focused view, 64 MB at 10.2 MB/s, line by line),
the Dart profile of the UI isolate showed the controller notifying the
view's listeners on every write while a slow frame was pending (126 ms per
64 MB, plus 38 ms reading the grid size on every write); after this round
9–14 ms and 1–2 ms. Of what remains per write, `ghostty_terminal_vt_write` is
~4 ms per MB and flutter_pty2's per-read acknowledgement another ~4 ms per
MB (`pty_session_ack_output` wakes its reactor with a pipe write on every
call). ADR 0011's amendment "frame cost and sustained floods" has the
details.

### Results, vsync-aligned flood pacing (2026-11-12)

Same machine, Xvfb + llvmpipe, DPR 1 (window 1800 × 1100 px), 40 MB at
7 MB/s, three runs per policy. `before` is the wall-clock timer (25 ms, then
60 ms after a second); the policies are ADR 0011's amendment "vsync-aligned
flood pacing". Ranges over runs:

| | frames | gap p50, ms | jitter, ms | irregular % | ms/MB without llvmpipe |
|---|---:|---:|---:|---:|---:|
| view, before | 38–49 | 127–161 | 32–53 | 65–96 | 27–32 |
| view, smooth | 88–154 | 33–53 | 15–35 | 31–74 | 42–60 |
| view, balanced (default) | 86–104 | 56–66 | 10–28 | 29–78 | 41–47 |
| view, efficient | 62–90 | 66–87 | 13–48 | 19–79 | 34–42 |
| blank, balanced | 92–167 | 33–61 | 4–33 | 1–89 | 34–49 |

Here a view frame does not fit in a 33 ms period (software raster, then
GTK's present on the UI thread), so the policies converge near 15 fps; the
`blank` runs (4 of 6 at ≤ 15 % irregular gaps, p50 33.3 ms) show the
cadence when frames fit. The numbers that decide the default must come from
a real GPU:

```sh
mise run bench:firehose -- --configs "no view,blank,view" --pacing smooth,balanced,efficient --runs 3
```
