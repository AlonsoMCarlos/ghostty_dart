# AGENTS.md

Guide for AI coding agents and human contributors working in this repository. `CLAUDE.md` imports this file.

## What this project is

Dart and Flutter bindings for **[libghostty-vt](https://lib.ghostty.org/vt/)** 1.x, the terminal emulation engine of Ghostty (stable C ABI since 1.0.0, 2026-11-06), on every platform we can support. On top of them, an API-compatible replacement for [`package:xterm`](https://pub.dev/packages/xterm) 4.0.0 that is much faster.

**Goal: publish on pub.dev and become the terminal package the Flutter community reaches for.** Every change is judged by whether it moves a published, high-quality, trustworthy package closer.

## Packages (pub workspace)

```
packages/
  ghostty_dart/           Pure Dart. ffigen bindings + idiomatic API. FFI backend (native) and
                        wasm backend (web) behind one interface. hook/build.dart ships the library.
  ghostty_dart_flutter/   Flutter widget: renderer, keyboard/mouse/IME input, selection, scrolling.
  ghostty_dart_xterm/        API-compatible adapter for package:xterm 4.0.0 on top of the two above.
apps/demo/              Flutter app: flutter_pty on desktop, a fake shell on the web. The live web demo
                        (GitHub Pages, --wasm) waits for ghostty_dart's wasm backend.
benchmarks/             Reproducible benchmarks vs xterm 4.0.0, xterm2, flterm. benchmarks/widget/ is the
                        Flutter frame-time benchmark (integration_test + flutter drive --profile).
native/                 upstream.json (pinned libghostty-vt version + hashes), CI build scripts.
tool/                   Repo scripts: lib.sh (shared bash helpers), check_cooldown, check_translations, check_dco +
                        dco_range, release/ (publish helpers),
                        native/ (binary pipeline), pana/ (pinned pana + dartdoc), test/ (tests of the scripts).
docs/                   User docs (en + es). docs/internal/ = ADRs and research (English only).
```

Dependency direction is one-way: `ghostty_dart_xterm → ghostty_dart_flutter → ghostty_dart → libghostty-vt`. `ghostty_dart` never imports Flutter.

## Decisions already made (read before proposing alternatives)

ADRs in `docs/internal/adr/`. Research with sources in `docs/internal/research/`.

- **0001** Target libghostty-vt **1.x only**, pinned in `native/upstream.json`. Check `ghostty_version()` at load.
- **0002** Own bindings; three packages as above. Existing bindings (`libghostty`/`flterm`, `ghostty_vte`) are references, not dependencies.
- **0003** Prebuilt binaries from our CI, verified by sha256 pinned in source. Opt-in `user_defines`: `source: prebuilt | system | zig`, `url_pattern`, `path`.
- **0004** `ghostty_dart_xterm` is a thin adapter. We never claim "drop-in" without the compatibility suite proving it.
- **0005** English code and docs; user-facing docs are bilingual en/es.
- **0006** Native lifetime and public API conventions. Details are in `docs/internal/architecture/ghostty_dart-conventions.md`, which **every change to `ghostty_dart` must follow**. It covers the handle base, the finalizer rules, callables, borrowed views and epochs, tolerant enums, the naming rules (§11), and the analyzer audit that keeps `dart:ffi` out of the public API.
- **0007** Package names are `ghostty_dart*`. Every README carries the "unofficial, not affiliated" notice and does not use the Ghostty logo.
- **0008** Prebuilt release pipeline: 12 assets named in `native/prebuilt_assets.json`, stripped and bit-reproducible (non-Apple built twice and compared), SLSA L3 attestations from `native-build.yml`, immutable releases tagged `native-v<version>-r<n>`, hashes pinned into `prebuilt.dart` through a reviewed PR (`native:pin`).
- **0009** The package names are kept without asking the Ghostty maintainers first (supersedes that line of 0007).
- **0010** First release and publishing: 0.1.0 uploaded manually first, own `publish.yml`, release-please with `GITHUB_TOKEN` + dispatch, pana and dartdoc pinned.
- **0011** `ghostty_dart_flutter` architecture: pty-agnostic `VtTerminalController` + `VtTerminalView` (`Vt` prefix); one repaint-isolated render box with a cached picture per row (content-keyed, so scrolling reuses pictures), run paragraphs at `col * cellWidth`, cursor overlay; keys through libghostty's encoder, IME through a delta text input client, shortcuts that never take Ctrl+V/Ctrl+A; mouse via `MouseEncoder`/`SelectionGesture`; scrolling owned by libghostty; semantics only while accessibility is on. Goldens Linux only (`golden` tag).

If a change contradicts an ADR, write a new ADR that supersedes it. Do not silently diverge.

## Toolchain: mise is the standard

- **[mise](https://mise.jdx.dev) manages every tool.** `mise install` at the repo root installs the exact versions in `mise.toml`: Flutter 3.47.9 (which bundles Dart 3.13.7), Zig 0.17.1, minisign, jq, plus actionlint and shellcheck (`lint:ci`).
  - Checksums are recorded in `mise.lock`. Commit both files.
  - `minimum_release_age = "3d"` enforces the cooldown for tools.
  - Never install project tools globally or via ad-hoc downloads. Add them to `mise.toml`.
  - System packages mise cannot provide: `libclang-dev` (ffigen only, from the distro), plus the Android SDK and Xcode for mobile app builds. Release builds pin the NDK sysroot (`tool/native/fetch_ndk.sh`) and the Xcode version (`native/toolchain.json`).
- Dart SDK constraint `^3.11.0`. `package:test` and workspace globs need 3.11.
- CI runs on the minimum and on the mise-pinned stable.
- Pub workspaces: the root `pubspec.yaml` has `publish_to: none` and `workspace:`; members have `resolution: workspace`. No melos unless a real need appears.
- Native: libghostty-vt 1.0.0, pinned in `native/upstream.json`, with Zig 0.17.x.
  - `tool/native/build.sh` builds offline, using upstream's deps tarball via `--system`, a fresh Zig cache, and `unshare -rn` where available.
  - `tool/native/fetch_upstream.sh` verifies the minisign signature *and* the pinned sha256.
  - `tool/native/build_host.sh` builds for the host (`x86_64-linux-gnu`, `aarch64-macos`, `x86_64-windows-gnu`: upstream's tier-1 Windows ABI) and stages the library under its bundled name, plus the headers, in `.native-cache/host/`.
  - `tool/native/release_asset.sh <asset>` builds one prebuilt release asset from `native/prebuilt_assets.json` (ADR 0008: `-Dstrip=true`, fresh caches, sources re-verified and extracted fresh every time) into `.native-cache/release/`.
  - `tool/native/check_binary.dart` checks each asset's format, architecture, exports (against the headers), dependencies and platform floors with its own bounded ELF/PE/Mach-O reader. `tool/native/pin_prebuilt.dart` pins a release into `prebuilt.dart` after verifying its attestations. Both are tested by `test:tool`.
  - The scripts are bash and run on Linux, macOS (bash 3.2, `shasum`) and Windows (Git Bash). Shared helpers live in `tool/native/lib.sh`. Do not use GNU-only tools (`sha256sum`, `find -printf`, `mapfile`) outside Linux-only paths.
- Bindings: ffigen 23 (Dart API config in `packages/ghostty_dart/tool/ffigen.dart`, `@Native`).
  - The generated `lib/src/ffi/bindings.g.dart` is committed and never edited by hand.
- Local development: the root `pubspec.yaml` sets `hooks: user_defines: ghostty_dart: source: path` with `path: .native-cache/host/`. A directory `path` makes the hook pick the target OS's bundled library name inside it, so the same pubspec works on every host.
- CI: `.github/workflows/ci.yml` runs `deps`, `native:host`, `native:check --host` and `check` on ubuntu-latest, macos-latest (arm64) and windows-latest. A Linux `pana` job runs `deps`, `pana` and `publish:dry-run`. `dco.yml` checks every PR commit's `Signed-off-by` (`tool/check_dco.sh`).
- Package releases (ADR 0010): `release-please.yml` (manifest mode, `GITHUB_TOKEN`) opens release PRs and, because its tags do not trigger workflows, dispatches `ci.yml` on the release PR and `publish.yml` on the new tag. `publish.yml` validates the tag against pubspec and CHANGELOG, builds the archive offline (`--to-archive`), and uploads exactly that archive via OIDC from the protected `pub.dev` environment. Steps of `release-please.yml` and `dco.yml` that install no tools call their scripts directly; each script still has a mirror mise task for local use.
- Native releases: `.github/workflows/native-release.yml` (tag `native-v<version>-r<n>`, manual dry run, or any PR touching the native pipeline) calls the reusable `native-build.yml` (read-only build jobs, no caches, a/b reproducibility check, format checks, attestation job), smoke-tests on six real runners, and publishes only after approval in the `native-release` environment. PRs never attest or publish. A `secrets` job runs gitleaks (pinned release binary, sha256 verified) over the full history and the working tree.

## Commands

**`mise run <task>` is the interface.** CI and humans run the same tasks. `mise tasks` lists them.

```sh
mise install            # tools
mise run deps           # flutter pub get --enforce-lockfile
mise run native:host    # libghostty-vt for this machine -> .native-cache/host/ (needed by test)
mise run native:build   # libghostty-vt for any zig target (default x86_64-linux-gnu)
mise run ffigen         # regenerate bindings
mise run format
mise run analyze        # format check + dart analyze --fatal-infos
mise run test           # runs inside packages/ghostty_dart, so the build hook runs
mise run test:flutter   # flutter test in packages/ghostty_dart_flutter (spike tag excluded)
mise run test:spike     # letterSpacing/metrics spikes on host fonts (manual, not in CI)
mise run test:goldens:update  # regenerate the widget goldens + doc/screenshot.png (Linux; review the diff)
mise run deps:no-flutter  # resolve without the Flutter members, exactly as locked (arm64 smoke runners)
mise run cooldown       # no locked dependency younger than 3 days
mise run check          # everything CI runs (analyze, test, test:flutter, demo:test, bench:widget:test, test:tool, test:release, cooldown, lint:ci, docs:translations)
mise run pana           # pub.dev score of the publish archive, pinned pana + dartdoc; must be 160/160 (network)
mise run publish:dry-run  # validate the publish archive (run on committed changes)
mise run docs:translations  # Spanish translations in sync with their English source
mise run lint:ci        # actionlint + shellcheck
mise run test:tool      # tests of the release tools and repo hygiene (nothing ignored, secret or >1 MiB is tracked)
mise run native:release-asset <asset>  # one ADR 0008 asset -> .native-cache/release/
mise run native:check <asset> [file]   # verify a release asset
mise run native:ndk     # pinned Android NDK sysroot (Linux only)
mise run native:pin <tag>              # pin a published release into prebuilt.dart (verifies attestations)
mise run bench:parser   # parser throughput vs xterm 4.0.0 / xterm2_core (benchmarks/README.md)
mise run bench:widget [device] [--frames=n] [--passes=n] [--renderer=impeller|skia]  # frame times vs xterm/xterm2; needs a display
mise run bench:widget:test  # the frame benchmark harness, headless
mise run demo:test      # demo app tests (fake shell, wiring)
mise run demo:run [device] [--fake]  # run the demo (default linux; --fake: the web's fake shell)
mise run demo:build-linux   # needs clang, cmake, ninja-build, pkg-config, libgtk-3-dev
mise run demo:build-web     # stops with a message until ghostty_dart has a wasm backend
```

When you add a workflow step, add a mise task for it. A task listed here must work.

Four members need the Flutter SDK: `packages/ghostty_dart_flutter`, `apps/demo`, `benchmarks/widget`, and `benchmarks/` (it depends on `xterm` 4.0.0, whose pubspec requires Flutter). Resolving the workspace therefore needs Flutter's Dart (the one mise installs); `mise run deps:no-flutter` drops those four members where only plain Dart exists. Use `mise run deps` (`flutter pub get`): plain `dart pub get` only finds the Flutter SDK when `FLUTTER_ROOT` is set, which is not guaranteed (it fails on the Linux CI runner).

## Code rules

### General
- Everything in English: identifiers, comments, dartdoc, commit messages.
- Lints: `package:lints/recommended.yaml`, plus `strict-casts`, `strict-inference` and `strict-raw-types`. `public_member_api_docs` is on in every published package. A published package carries a self-contained `analysis_options.yaml` (it ships in the archive) that mirrors the root rules; `tool/test/analysis_options_test.dart` keeps them in sync.
- Formatting: `dart format` with the default tall style. Zero analyzer infos.
- Document every public member. Target ≥80% dartdoc coverage (pana requires 20%). Each doc says *what* and *why*, gives one example for main entry points, and documents ownership and lifetime for handles.
- Comments explain non-obvious *why*. No commented-out code and no TODOs without an issue link.

### `ghostty_dart` (bindings)
- **Target:** `lib/ghostty_dart.dart` will use a conditional export (`if (dart.library.js_interop)`) once the wasm backend exists. Until then it is native-only, and web must not be claimed.
- Never use `dart:html`. Claiming web without being Wasm-ready costs pana platform points (see sqlite3 at 150/160).
- One `VtBackend` interface. The FFI and wasm implementations must pass the same test suite.
- Ownership mirrors the C API:
  - Every `_new` has a matching `_free`. Wrappers implement `Finalizable`, attach a `NativeFinalizer`, and have an idempotent `dispose()` that detaches it.
  - On web, use `Finalizer` plus `dispose()`.
- Borrowed handles (render-state rows and cells, grid refs) are valid only until the next mutating call. Never let them escape an iteration scope.
- Callbacks use `NativeCallable.isolateLocal`. They fire synchronously inside `vt_write`. Close them in `dispose()`.
- `isLeaf: true` only for calls that can never call back into Dart.
- Hot paths:
  - Bulk byte input via `Uint8List`, with no `String` round-trip.
  - Read cells in batches; never make one FFI call per cell per frame from Dart if a batched read exists.
  - Use zero-copy views (`asTypedList`, `.address`). On wasm, rebuild the `memory.buffer` view whenever memory grows.
- Map C results to Dart exceptions in one place. `GHOSTTY_UNSUPPORTED` becomes `UnsupportedError`.

### `ghostty_dart_flutter` (widget)
- Repaint only dirty rows, using the render state's `next_dirty`.
- Draw style runs, not cells. Cache paragraphs per run.
- A `drawRawAtlas` glyph atlas is the planned v2 path. Land it only with benchmark evidence.
- Must work on Skia and Impeller, and on the web renderers (CanvasKit, skwasm) once `ghostty_dart` has its wasm backend; until then the package declares native platforms only.
- Input:
  - Keys are encoded by libghostty's key encoder, including the Kitty protocol.
  - The widget must not steal shell shortcuts by default. Ctrl+V and Ctrl+A go to the shell.
  - IME and mobile soft keyboards are first-class, with tests.

### `ghostty_dart_xterm` (compat adapter)
- Mirror the public API of `xterm` 4.0.0 exactly: names, parameters, defaults and callback signatures. When in doubt, read xterm.dart's source (MIT) and match it.
- `COMPATIBILITY.md` is generated by `tool/` from the xterm 4.0.0 API. Every member is ✅ same, ⚠️ differs, ❌ missing (planned) or 🚫 won't support (with the reason).
- Port xterm.dart's tests into `packages/ghostty_dart_xterm/test/compat/`. A failing compat test is a bug, not a flaky test.
- Additions beyond xterm are additive only (e.g. `writeBytes`). They must never change the behaviour of an existing xterm member.

## Testing

- Every behaviour change ships with tests, on both backends where they apply.
- Golden tests run on Linux CI only, with a bundled monospace font. In `ghostty_dart_flutter` they carry the `golden` tag, which `dart_test.yaml` skips off Linux; regenerate them with `mise run test:goldens:update`.
- Use VT conformance fixtures (vttest-style byte streams) for the adapter.
- Use property tests with random byte streams. Fuzzing belongs upstream in C.
- Benchmarks use `benchmark_harness`, with `--flavor aot` and `wasm`. A PR claiming a perf win includes before/after numbers.

## Supply chain: non-negotiable

This machine had a real compromise via build-time code (2026-08-20). Our build hook runs on users' machines, so it is held to the same standard.

- The hook only downloads the pinned artefact for the target, verifies its sha256 against the value in source, and **fails closed**. It never runs downloaded code at build time and never resolves anything unpinned.
- Never commit `pubspec_overrides.yaml`, secrets, signing material or build output. `.gitignore` blocks them and `tool/test/repo_hygiene_test.dart` (`test:tool`) fails if one is tracked anyway. Published packages carry a `.pubignore` that keeps test-only assets out of the archive.
- Every `pubspec.lock` is committed: the workspace's and `tool/pana/`'s.
- Never run `dart pub upgrade` blindly. Review every lockfile diff.
- Do not adopt any dependency version published less than 3 days ago (cooldown).
  - `mise run cooldown` checks every committed lockfile, and fails closed if it parses no or too few entries.
  - Hold back a too-new transitive version with a root `dependency_overrides` entry, with a dated comment. Remove it once the version has aged.
  - Prefer fixing an SDK pin conflict without an override. Flutter's `flutter_test` pins exact versions (Flutter 3.47.9: `test_api 0.7.12`), and every workspace member resolves together, so `ghostty_dart`'s dev dependencies stay on `test ^1.31.1` and `analyzer ^13.3.0` (`test` 1.32 and later and `analyzer` 14 need a newer `test_api`). Raise them together with the pinned Flutter.
- Prefer zero dependencies in `ghostty_dart`. Every new dependency needs a justification in the PR.
- Before using a library's API, read its source in `~/.pub-cache`. Do not create throwaway projects that compile unpinned code.
- Pin GitHub Actions by commit SHA.
- Native binaries are built only in CI, with provenance attestations (ADR 0008, `native-release.yml`). Non-Apple assets are built twice and must be bit-identical.

## Docs and language

- User-facing docs are bilingual. `X.md` is in English and is the source of truth; `X.es.md` sits next to it.
- The English file carries `**English** | [Español](X.es.md)` near the top (after the title and badges; within its first 20 lines). The Spanish file starts with `<!-- source: X.md@<blob sha> -->` on line 1 and the reverse switcher on line 2. Use absolute GitHub URLs in files rendered on pub.dev.
- The sha is the **blob** sha of the English text the translation matches (`git hash-object X.md`), which survives squash and rebase merges. `mise run docs:translations` (part of `check`) warns when a translation is stale and fails when a header is missing or malformed. Update both files in the same PR.
- Bilingual files:
  - every package `README`;
  - `CONTRIBUTING`;
  - `CODE_OF_CONDUCT` (official Contributor Covenant 3.0 translation);
  - `SECURITY`;
  - `MIGRATING_FROM_XTERM`;
  - the docs site.
- English only: CHANGELOG, ADRs, `docs/internal/`, dartdoc.
- Spanish must be correct: full accents and punctuation (¿ ¡), neutral and technical. Keep code identifiers in English.
- README order (banner, demo and "migrating from xterm" apply to the widget and adapter packages only):
  1. banner;
  2. badges;
  3. language switcher;
  4. demo GIF and live-demo link;
  5. three value bullets;
  6. platform table;
  7. minimal quick start (install + one short example);
  8. migrating from xterm;
  9. benchmarks;
  10. honest comparison;
  11. supply chain;
  12. docs link.
- Images use absolute URLs so they render on pub.dev.
- Tone: factual and respectful toward xterm.dart, flterm and other projects. No unverified performance claims; every number links to a reproducible benchmark.

## Publishing and releases

- pana target: **160/160 for every package**. `mise run pana` scores the extracted publish archive with pana and dartdoc pinned in `tool/pana/` (`--dartdoc-command`, never an unpinned global dartdoc), with `--exit-code-threshold 0`.
- pubspec:
  - `description` of 60–180 ASCII characters;
  - `repository` pointing at the package subdirectory;
  - `issue_tracker`;
  - up to 5 `topics`;
  - `screenshots` for the widget packages;
  - `funding`, once the project has a funding URL (none yet).
- Conventional Commits with DCO sign-off (`git commit -s`), checked on every PR by `tool/check_dco.sh`. release-please in manifest mode cuts the releases.
- Tags are `<package>-v<version>`. Publishing uses our own `.github/workflows/publish.yml` (validate, offline `--to-archive`, OIDC upload with SHA-pinned setup-dart) behind the protected `pub.dev` environment. The first version of each package is uploaded manually (`docs/internal/release-checklist.md`).
- release-please uses `GITHUB_TOKEN` and dispatches CI and `publish.yml` explicitly. No GitHub App, no secrets (ADR 0010).
- Semver: start at `0.1.0`; while in `0.x`, a minor bump means breaking. Check breaking changes with `dart_apitool diff`.
- The CHANGELOG entry must match the pubspec version.
- Package skills: each published package ships `skills/<pkg>-<topic>/SKILL.md`. For example, `ghostty_dart_xterm-migrate-from-xterm` and `ghostty_dart-usage`.

## Working style for agents

- Verify against real documentation or source (with date) before deciding. Do not rely on memory for API details of Dart, Flutter or libghostty-vt.
- The C headers at the pinned tag are the source of truth for the native API.
- Make technical decisions yourself, record the reason (ADR, or a PR description for small ones) and report briefly. Ask the maintainer only about product direction.
- Do not commit or push unless asked. Never publish to pub.dev without explicit approval: a published version is permanent.
- Keep this file current. When a decision, command or layout changes, update `AGENTS.md` in the same change.
