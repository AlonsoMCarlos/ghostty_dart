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
