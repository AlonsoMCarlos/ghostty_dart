# Research: Dart/Flutter publishing and community best practices (November 2026)

Date: 2026-11-09 (all sources read that day). **[V]** = verified at source, **[I]** = inferred.

## 1. Pub points (pana): 160 max
Sources: pana source on GitHub (master) and live score pages.

**Examples**
- `jni` 1.1.2: **160**. It supports Android, Windows and Linux only and still gets full platform points.
- `sqlite3` 3.9.1: **150**. It loses 10 points because it claims Web but its main library imports `dart:ffi`, so it is not Wasm-ready.
- `xterm` 4.0.0: **140**. It loses points on lints and outdated dependencies, and only 22% of its API is documented.

**Point breakdown**

| Category | Points | What counts |
|---|---|---|
| Conventions | 30 | See below |
| Documentation | 20 | ≥20% of the public API documented, plus an example |
| Platforms | 20 | Supporting Web without Wasm-readiness caps this at **10**. The number of platforms does not matter. |
| Static analysis | 50 | No errors, warnings, lints or formatting issues (pana runs `lints/core` plus our options) |
| Dependencies | 40 | See below |

- **Conventions:**
  - pubspec (10). The `description` must be 50–180 chars (pana suggests 60–180) and mostly ASCII. No git dependencies. The `repository` must be cloneable and contain a matching `pubspec.yaml`.
  - README (5) and CHANGELOG (5). The CHANGELOG must mention the current version. No `http:` links.
  - OSI-approved licence (10).
- **Dependencies:**
  - Constraints accept the latest versions (10).
  - Supports the latest SDK (10).
  - **`pub downgrade` analyses cleanly (20).**
- **Platform detection is only the import graph of `lib/<name>.dart`.** pana has no special handling for hooks.
  - So use `export 'src/ffi.dart' if (dart.library.js_interop) 'src/wasm.dart';`.
  - Never use `dart:html`.

**Relevant pubspec fields**
- `topics`: up to 5.
- `screenshots`: up to 10, ≤4 MB each, gif/webp allowed. The first one becomes the thumbnail.
- `funding`, `issue_tracker`, `documentation`.
- `false_secrets`.

## 2. Workspace and tooling
- **[V]** Pub workspaces exist since Dart 3.6; globs in `workspace:` need 3.11.
  - Setup: the root has `publish_to: none`, members have `resolution: workspace`, and there is a single lockfile.
- **[V]** melos 8.10.1 is now built on top of workspaces. It is optional.
- **[V] Lints:**
  - `lints` 6.1.0, `flutter_lints` 6.0.0, `very_good_analysis` 11.0.0.
  - Analyzer plugins are available since Dart 3.10.
  - `dart format` uses the "tall" style. `page_width` can be set in `analysis_options.yaml` (language version 3.7 or later).
- **[V]** Hook packages: `hooks` and `code_assets` 2.2.0 require Dart ≥3.10.
  - `code_assets` 2.2.0 came out on 2026-11-07, so it is still inside our 3-day cooldown.

## 3. Publishing
- **[V]** OIDC publishing from GitHub Actions:
  - The first publish is manual. After that, set a tag pattern per package (`<pkg>-v{{version}}`) and protect a `pub.dev` environment with required reviewers.
  - Use the reusable workflow `dart-lang/setup-dart/.github/workflows/publish.yml@v1`, which takes a `working-directory`. Its jobs are validate → package (no network) → publish.
  - Source: https://dart.dev/tools/pub/automated-publishing
- **[V]** pub.dev does not document provenance attestations.
- **[V]** release-please has a `dart` release type. In manifest mode its tags are `<component>-v<version>`.
  - **Tags created with `GITHUB_TOKEN` do not trigger workflows.** Use a GitHub App token.
- **[V]** A verified publisher needs a domain. You publish first from a Google account, then transfer the package; the transfer is irreversible.
- **[V]** A version can be retracted within 7 days.

## 4. CI checklist
- Matrix: Linux, macOS and Windows, plus web/wasm, each at min SDK and stable.
- Format and analysis:
  - `dart format --set-exit-if-changed`.
  - `dart analyze --fatal-infos`.
  - `dart pub downgrade && dart analyze`.
- Tests:
  - VM tests.
  - `dart test -p chrome -c dart2wasm`.
  - `flutter test`.
  - Golden tests on a single OS, using a bundled monospace font.
- Publishing checks:
  - `dart pub publish --dry-run` per package.
  - pana with `--exit-code-threshold 0` and `--project-root`.
  - API breakage: dart_apitool 0.23.2, `diff --version-check-mode fully`.
- Coverage: `flutter test --coverage`, uploaded to Codecov.
- Dependency updates: Renovate with `minimumReleaseAge: "3 days"` (the cooldown). Workspace support is unverified.
- Testing tools:
  - `benchmark_harness` 2.4.0 can run with the `--flavor aot|jit|wasm` flags.
  - `alchemist` 0.14.1 for goldens.
  - Dart has no native fuzzer: fuzz in C, and add property tests in Dart.

## 5. Native-assets specifics
Model: `sqlite3`.

- **Hook documentation.** sqlite3 has a dartdoc topic called "Build hook options" that documents every `user_define`:
  - `source`
  - `url_pattern` (for mirrors)
  - per-OS maps
- **Binary integrity.** It pins sha256 hashes in the package source and attaches SLSA L3 provenance with `actions/attest-build-provenance`.
- **[V] How `user_defines` work:**
  - Only the root pubspec can set them.
  - A hook reads them through `input.userDefines`.
- **[V] SwiftPM:**
  - It is the default for Flutter apps since 3.44.
  - It does not affect hook-only packages that have no `flutter.plugin` section.
- **[V] Security advisories:**
  - There is no `dart pub audit`; advisories come from GHSA during `pub get`.
  - Use Dart ≥3.13.7, which blocks the compromised eMudhra CA keys.

## 6. Community appeal: what successful packages do

| Repo | Patterns worth copying |
|---|---|
| riverpod | Badges; Docusaurus site with 11 locales, `es` among them; `benchmarks/`; `examples/` |
| flutter_rust_bridge | Quick start in one line; `AGENTS.md`, `CLAUDE.md`, `SECURITY.md`; all-contributors |
| sqlite3.dart | Build hooks with prebuilt binaries; `UPGRADING_TO_V3.md` |
| dio (cfug) | **Bilingual pairs: `README.md` + `README-ZH.md` with a language switcher**, `CONTRIBUTING-ZH.md`, `AGENTS-ZH.md`, `COMPATIBILITY_POLICY.md` |
| flame | **Live web examples**; versioned docs |
| very_good_cli | `.github/` set: issue forms, `CODEOWNERS`, `dependabot.yaml`, `labels.yml`; release-please |
| ghostty-web (coder) | xterm.js-compatible; "Try it" demo; GIF. **But no API-support table, no migration guide and no compatibility suite** (see §7) |

**Recommended README order:**
1. Banner.
2. Badges: pub version, pub points, CI, coverage, licence, "xterm API N/M", "libghostty-vt 1.0".
3. Language switcher EN | ES.
4. A 10-second GIF and a live demo link.
5. Three value bullets.
6. Platform table.
7. A 3-line quick start.
8. "Migrating from xterm".
9. Benchmarks with a chart.
10. An honest comparison with `xterm`, `xterm2`, `flterm` and `ghostty_vte_flutter`.
11. Supply-chain section.
12. Link to the docs site.

Images must use absolute URLs so they render on pub.dev.

## 7. Lessons from ghostty-web: drop-in claims
- Coder's own migration PR (coder/coder#31326) says **"not a drop-in"** and lists the gaps:
  - Content Security Policy issues.
  - No OSC handler API.
  - Link clicks bypass `onOpenLink`.
  - Ctrl+V pastes instead of sending `^V`.
  - The custom key handler's return value is inverted (#192).
  - `onRender` never fires.
  - Different default colours.
- HN criticism (item 46110842): disparaging xterm.js wording that had to be withdrawn, benchmarks promised but never published, and demo bugs in Firefox and iOS Safari.
- **What we do differently:**
  - Never claim "drop-in" without evidence.
  - Ship `COMPATIBILITY.md` with a member-by-member table (✅ / ⚠️ / ❌ / 🚫).
  - Port xterm.dart's MIT-licensed tests as a compatibility suite in CI.
  - Ship `MIGRATING_FROM_XTERM.md`, using Coder's list as a behaviour checklist.
  - Publish reproducible benchmarks before announcing.
  - Test the web demo in Firefox, Safari iOS and Chrome.
  - Speak respectfully about `xterm.dart`.

## 8. Community files and growth
- **Code of conduct:** Contributor Covenant 3.0 (2025), which has an official Spanish translation.
- **Repo files:** `SECURITY.md` plus GitHub Private Vulnerability Reporting.
  - A terminal parses hostile input, so the security policy matters: OSC 52 and OSC 8 have had security fixes.
- **Contributions:** DCO (no CLA); conventional commits; `FUNDING.yml`; GitHub Discussions rather than a Discord at first.
- **Flutter Favorite** still exists. Criteria:
  - verified publisher;
  - git tag matching the published version;
  - not beta;
  - good docs.
- **Launch channels:**
  - a PR to awesome-libghostty;
  - Show HN, with benchmarks and a demo ready;
  - r/FlutterDev, with no marketing tone;
  - Bluesky;
  - a courteous issue in xterm.dart.
- **Bilingual docs:**
  - Keep `README.es.md` next to `README.md`; pub.dev shows only `README.md`.
  - Put a switcher at the top of both.
  - Translations carry `<!-- source: README.md@<sha> -->`, and CI compares that sha with the last commit touching the English file. This follows the PHP doc guide and the Linux kernel's `checktransupdate.py`.
  - Docs site: Starlight or Docusaurus, both of which support i18n (`es/`).
- **AI conventions:**
  - **Package skills are official** (https://dart.dev/tools/pub/package-skills, 2026-11-02): `skills/<pkg>-<topic>/SKILL.md` is published with the package and installed with `dart run skills@ get`. `.agents/skills/` holds maintainer-only skills.
  - `AGENTS.md` at the repo root is common practice (dio, very_good_cli, flutter_rust_bridge, ghostty-web, libghostty-rs).
  - `llms.txt` is not a convention.
- **Other context:**
  - Dart macros were cancelled in Jan 2025.
  - Wasm is still opt-in (`--wasm`) in Flutter 3.47.
  - Impeller is the default renderer on desktop since 3.47.
