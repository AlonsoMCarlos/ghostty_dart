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
apps/demo/              Flutter app; also deployed as the live web demo (GitHub Pages, --wasm).
benchmarks/             Reproducible benchmarks vs xterm 4.0.0, xterm2, flterm.
native/                 upstream.json (pinned libghostty-vt version + hashes), CI build scripts.
tool/                   Repo scripts (translation sync check, compatibility table generator).
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
- **0007** Package names are `ghostty_dart*`. Every README carries the "unofficial, not affiliated" notice and does not use the Ghostty logo.
- **0006** Native lifetime and public API conventions. Details are in `docs/internal/architecture/ghostty_dart-conventions.md`, which **every change to `ghostty_dart` must follow**. It covers the handle base, the finalizer rules, callables, borrowed views and epochs, tolerant enums, the naming rules (§11), and the analyzer audit that keeps `dart:ffi` out of the public API.

If a change contradicts an ADR, write a new ADR that supersedes it. Do not silently diverge.

## Toolchain: mise is the standard

- **[mise](https://mise.jdx.dev) manages every tool.** `mise install` at the repo root installs the exact versions in `mise.toml`: Flutter 3.47.9 (which bundles Dart 3.13.7), Zig 0.17.1 and minisign.
  - Checksums are recorded in `mise.lock`. Commit both files.
  - `minimum_release_age = "3d"` enforces the cooldown for tools.
  - Never install project tools globally or via ad-hoc downloads. Add them to `mise.toml`.
  - System packages mise cannot provide: `libclang-dev` (ffigen only, from the distro), plus the Android SDK and Xcode for mobile builds.
- Dart SDK constraint `^3.11.0`. `package:test` and workspace globs need 3.11.
- CI runs on the minimum and on the mise-pinned stable.
- Pub workspaces: the root `pubspec.yaml` has `publish_to: none` and `workspace:`; members have `resolution: workspace`. No melos unless a real need appears.
- Native: libghostty-vt 1.0.0, pinned in `native/upstream.json`, with Zig 0.17.x.
  - `tool/native/build.sh` builds offline, using upstream's deps tarball via `--system`, a fresh Zig cache, and `unshare -rn` where available.
  - `tool/native/fetch_upstream.sh` verifies the minisign signature *and* the pinned sha256.
- Bindings: ffigen 23 (Dart API config in `packages/ghostty_dart/tool/ffigen.dart`, `@Native`).
  - The generated `lib/src/ffi/bindings.g.dart` is committed and never edited by hand.
- Local development: the root `pubspec.yaml` sets `hooks: user_defines: ghostty_dart: source: path` to the locally built library.

## Commands

**`mise run <task>` is the interface.** CI and humans run the same tasks. `mise tasks` lists them.

```sh
mise install            # tools
dart pub get            # workspace deps
mise run native:build   # libghostty-vt for host Linux x64 (arg: zig target)
mise run ffigen         # regenerate bindings
mise run format
mise run analyze        # format check + dart analyze --fatal-infos
mise run test
mise run cooldown       # no locked dependency younger than 3 days
mise run check          # everything CI runs
```

When you add a workflow step, add a mise task for it. A task listed here must work.

## Code rules

### General
- Everything in English: identifiers, comments, dartdoc, commit messages.
- Lints: `package:lints/recommended.yaml`, plus `strict-casts`, `strict-inference` and `strict-raw-types`. `public_member_api_docs` is on in every published package.
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
- Must work on Skia, Impeller and the web renderers.
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
- Golden tests run on Linux CI only, with a bundled monospace font.
- Use VT conformance fixtures (vttest-style byte streams) for the adapter.
- Use property tests with random byte streams. Fuzzing belongs upstream in C.
- Benchmarks use `benchmark_harness`, with `--flavor aot` and `wasm`. A PR claiming a perf win includes before/after numbers.

## Supply chain: non-negotiable

This machine had a real compromise via build-time code (2026-08-20). Our build hook runs on users' machines, so it is held to the same standard.

- The hook only downloads the pinned artefact for the target, verifies its sha256 against the value in source, and **fails closed**. It never runs downloaded code at build time and never resolves anything unpinned.
- `pubspec.lock` is committed.
- Never run `dart pub upgrade` blindly. Review every lockfile diff.
- Do not adopt any dependency version published less than 3 days ago (cooldown).
  - `mise run cooldown` checks the lockfile.
  - Hold back a too-new transitive version with a root `dependency_overrides` entry, with a dated comment. Remove it once the version has aged.
- Prefer zero dependencies in `ghostty_dart`. Every new dependency needs a justification in the PR.
- Before using a library's API, read its source in `~/.pub-cache`. Do not create throwaway projects that compile unpinned code.
- Pin GitHub Actions by commit SHA.
- Native binaries are built only in CI, with provenance attestations.

## Docs and language

- User-facing docs are bilingual. `X.md` is in English and is the source of truth; `X.es.md` sits next to it.
- Both files start with `**English** | [Español](X.es.md)` (and the reverse in the Spanish file).
- Each Spanish file starts with `<!-- source: X.md@<sha> -->`. Update both files in the same PR, or the CI warning stays.
- Bilingual files:
  - every package `README`;
  - `CONTRIBUTING`;
  - `CODE_OF_CONDUCT` (official Contributor Covenant 3.0 translation);
  - `SECURITY`;
  - `MIGRATING_FROM_XTERM`;
  - the docs site.
- English only: CHANGELOG, ADRs, `docs/internal/`, dartdoc.
- Spanish must be correct: full accents and punctuation (¿ ¡), neutral and technical. Keep code identifiers in English.
- README order:
  1. banner;
  2. badges;
  3. language switcher;
  4. demo GIF and live-demo link;
  5. three value bullets;
  6. platform table;
  7. 3-line quick start;
  8. migrating from xterm;
  9. benchmarks;
  10. honest comparison;
  11. supply chain;
  12. docs link.
- Images use absolute URLs so they render on pub.dev.
- Tone: factual and respectful toward xterm.dart, flterm and other projects. No unverified performance claims; every number links to a reproducible benchmark.

## Publishing and releases

- pana target: **160/160 for every package**. Run pana in CI with `--exit-code-threshold 0`.
- pubspec:
  - `description` of 60–180 ASCII characters;
  - `repository` pointing at the package subdirectory;
  - `issue_tracker`;
  - up to 5 `topics`;
  - `screenshots` for the widget packages;
  - `funding`.
- Conventional Commits with DCO sign-off (`git commit -s`). release-please in manifest mode cuts the releases.
- Tags are `<package>-v<version>`. Publishing goes through the OIDC reusable workflow `dart-lang/setup-dart/.github/workflows/publish.yml`, behind the protected `pub.dev` environment.
- release-please uses a GitHub App token, because `GITHUB_TOKEN` tags do not trigger workflows.
- Semver: start at `0.1.0`; while in `0.x`, a minor bump means breaking. Check breaking changes with `dart_apitool diff`.
- The CHANGELOG entry must match the pubspec version.
- Package skills: each published package ships `skills/<pkg>-<topic>/SKILL.md`. For example, `ghostty_dart_xterm-migrate-from-xterm` and `ghostty_dart-usage`.

## Working style for agents

- Verify against real documentation or source (with date) before deciding. Do not rely on memory for API details of Dart, Flutter or libghostty-vt.
- The C headers at the pinned tag are the source of truth for the native API.
- Make technical decisions yourself, record the reason (ADR, or a PR description for small ones) and report briefly. Ask the maintainer only about product direction.
- Do not commit or push unless asked. Never publish to pub.dev without explicit approval: a published version is permanent.
- Keep this file current. When a decision, command or layout changes, update `AGENTS.md` in the same change.
