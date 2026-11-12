# 0010. First release and the publishing pipeline

**Status:** Accepted (2026-11-09). Supersedes the "release-please uses a GitHub App token" and "Publishing goes through the reusable workflow `dart-lang/setup-dart/.github/workflows/publish.yml`" lines of AGENTS.md. Research: `docs/internal/research/2026-11-09-publishing-pipeline.md` and `2026-11-09-user-docs.md` (2026-11-09).

## Context
- pub.dev accepts automated (OIDC) publishing only for packages that already exist, so the first upload is manual.
- The reusable `setup-dart` publish workflow runs `dart pub get` on the whole workspace. The workspace includes `benchmarks`, which needs Flutter, and with `use-flutter` that workflow installs an unpinned Flutter. Its safer three-job design (validate, package offline, publish the archive) exists only on `main`, with no release yet.
- release-please (`release-type: dart`) mishandles prerelease versions (issue #2400). It also starts at 1.0.0 unless the manifest is seeded.
- A GitHub App token would let release-please PRs trigger CI. It needs an App, a private key and two secrets. `GITHUB_TOKEN` plus an explicit `workflow_dispatch` needs no secret at all.
- pana 0.23.19 can score an FFI package with a downloading build hook at 160/160. By default it installs the latest dartdoc, unpinned.

## Decision
**First version.**
- The first version is **0.1.0**, not a prerelease.
- The maintainer publishes it manually with `dart pub publish` from a clean checkout of the tagged commit `ghostty_dart-v0.1.0`.
- Automated publishing is then enabled on pub.dev for the tag pattern `ghostty_dart-v{{version}}`, with `workflow_dispatch` allowed and the `pub.dev` GitHub environment required.

**`publish.yml` is our own workflow.** It copies the three-job design from setup-dart `main`:
1. Validate with the mise-pinned toolchain and `--enforce-lockfile`.
2. `dart pub publish --to-archive` offline.
3. Upload that exact archive from a job with `id-token: write`, in the `pub.dev` environment. The OIDC token is minted with `curl` from the Actions token endpoint (audience `https://pub.dev`) and registered with the mise-pinned, sha256-verified Dart (`dart pub token add --env-var`), exactly as setup-dart does. setup-dart itself is not used, because it downloads a Dart SDK without verifying its hash and would run it with the token in scope.

It runs on `ghostty_dart-v*` tag pushes and `workflow_dispatch`.

**release-please** runs in manifest mode, with the manifest seeded at 0.1.0:
- it finds the released 0.1.0 by its tag `ghostty_dart-v0.1.0`, so it does nothing until that tag exists; a `bootstrap-sha` is added afterwards only as a fallback;
- options `bump-patch-for-minor-pre-major` (in 0.x, `feat` and `fix` bump the patch and a breaking change bumps the minor, matching our semver rule and pub's caret semantics) and `signoff`;
- tags `ghostty_dart-v<version>`, with `separate-pull-requests` so the release branch is per component (`release-please--branches--main--components--ghostty_dart`), which the DCO check's bot exception is scoped to;
- the workflow token is `GITHUB_TOKEN`.

Because tags created with `GITHUB_TOKEN` do not trigger workflows, the release-please workflow dispatches `publish.yml` (`gh workflow run --ref <tag>`) and CI on the release PR branch. No App and no secrets.

**pana** runs from `tool/pana/`, a separate package with `pana` and `dartdoc` pinned exactly and a committed `pubspec.lock`:
- covered by `mise run cooldown`;
- runs in CI together with `dart pub publish --dry-run`;
- `tool/pana/run_pana.sh` scores the package's publish archive (`--to-archive`, unpacked), which is exactly what pub.dev receives, with `--exit-code-threshold 0` and `--dartdoc-command` pointing at the pinned dartdoc;
- `--dartdoc-version sdk` is not used: on Dart 3.13.7, `dart doc` rejects the `--sanitize-html` flag that pana passes (verified 2026-11-09). The default is not used either, because it would globally install an unpinned dartdoc.

**DCO** is checked by our own script on every PR: every non-merge commit needs a `Signed-off-by` matching its author. No third-party App. The only exception is release-please's own commits, and only on the `workflow_dispatch` run that `release-please.yml` starts on its release branch; a pull-request run never gets it. A `main` ruleset (PR required, CI/DCO/pana/secrets checks, admin bypass) makes the checks binding.

## Consequences
- The release PR's CI runs through a dispatch, not as a native PR check.
- Each published version still needs a human approval in the `pub.dev` environment.
- Nothing in the pipeline holds a long-lived secret.
- When setup-dart releases its three-job workflow, we can switch to it pinned by SHA, if it can skip the Flutter-only workspace member.

## Amendment (2026-11-12): several packages, and the first publish of `ghostty_dart_flutter`

The maintainer approved preparing the first publish of `ghostty_dart_flutter` (0.1.0). The pipeline above was written for `ghostty_dart` alone; it now releases a fixed allow-list of packages. No check is weaker than before.

**One allow-list, the tag selects the package.**
- `tool/release/lib.sh` lists the released packages: `ghostty_dart` and `ghostty_dart_flutter`. `ghostty_dart_xterm` joins only when its own first publish is prepared.
- A release tag is `<package>-v<X.Y.Z>`. Package names contain no `-`, so the split is unambiguous. Every script takes the package from the tag and refuses a package outside the list: `validate_tag.sh` (which also checks the pubspec's `name` now), `package.sh <tag> <archive>`, `check_archive.sh <archive> <sha256> <tag>`, `dispatch.sh` (tags and release PR branches), `release_ready.sh` and the DCO bot exception (`tool/dco_range.sh`, one release branch per listed package).
- `publish.yml` ("Publish to pub.dev") triggers on `ghostty_dart-v*` and `ghostty_dart_flutter-v*` and names the archive `<package>-<version>.tar.gz`. The upload job still checks the archive against the `package` job's sha256 and now against the tag's package and version.
- `test:release` keeps the list equal to the components and paths of `release-please-config.json`, the manifest's keys, `publish.yml`'s tag triggers and `release-please.yml`'s per-package outputs.

**The Flutter package is packaged with the plain Dart SDK.** With `--to-archive --skip-validation`, pub resolves nothing (`lib/src/command/lish.dart` at dart-lang/pub `ec276d10`, `_publicationFromEntrypoint` skips `acquireDependencies`), so the `flutter` SDK dependency is never looked up. Checked 2026-11-12: the pinned Dart 3.13.7 SDK, without Flutter on `PATH` or `FLUTTER_ROOT` and with no network (`unshare -rn`), wrote a `ghostty_dart_flutter` archive byte-identical (same sha256) to `flutter pub publish --to-archive --skip-validation` of Flutter 3.47.9. `--from-archive` only parses the archive's pubspec, so the upload job needs no Flutter either. Validation (`publish:dry-run`) keeps using `flutter pub publish --dry-run` for it, in the `validate` job, which has the full mise toolchain.

**release-please waits for every package's first tag.** release-please 17.6.0 finds a component's last release by the tag of its manifest version (`backfillReleasesFromTags`). For a component without that tag, `buildPullRequests` collects every commit since the shared `bootstrap-sha` that touches the package and builds a release on top of the manifest version: a bogus `ghostty_dart_flutter` 0.1.1 release PR before 0.1.0 exists. A per-component skip is not possible: release-please-action v5.0.0 passes `path` only to single-package mode, never to `Manifest.fromManifest` (`src/index.ts` at `45996ed1`), and reads the config through the API at `main`, so one run handles every configured component. So `release_ready.sh` lets `release-please.yml` run only when **every** listed package has a `<package>-v<X.Y.Z>` tag. Cost: from the merge that adds a package to the config until its manual tag, no release PR or tag is made for any package. That window is the first-publish procedure itself (minutes to hours); the checklist says to merge only when ready to publish. Rejected: one config file per component (duplicated shared options, the DCO sign-off source and the manifest shared between them, for a window that short).

**First publish of `ghostty_dart_flutter`.** Like `ghostty_dart`: merge, tag `ghostty_dart_flutter-v0.1.0` on the merge commit, let `publish.yml` validate and package, reject the upload, publish by hand from a fresh clone with `flutter pub publish` (the command docs.flutter.dev gives for packages, page updated 2026-11-03, read 2026-11-12), then enable automated publishing on pub.dev with the tag pattern `ghostty_dart_flutter-v{{version}}`. The `pub.dev` environment's deployment tag policy and the tag ruleset are extended to `ghostty_dart_flutter-v*` before the tag is pushed. The widget depends on the published `ghostty_dart: ^0.1.0` (its `lib/` has not changed since `ghostty_dart-v0.1.0`), and `ghostty_dart_xterm` now depends on `ghostty_dart_flutter: ^0.1.0`. Steps: `docs/internal/release-checklist.md`, "First publish of `ghostty_dart_flutter`".

## Amendment (2026-11-12, 2): the first publish of `ghostty_dart_xterm`

`ghostty_dart_flutter` 0.1.0 is on pub.dev, and the maintainer approved publishing the xterm adapter (ADR 0013) on 2026-11-12. It joins the pipeline exactly as the widget did; no check changes.

- `ghostty_dart_xterm` is the third package of the allow-list (`tool/release/lib.sh`), of `release-please-config.json` (component `ghostty_dart_xterm`) and the manifest (`0.1.0`), of `publish.yml`'s tag triggers (`ghostty_dart_xterm-v*`) and of `release-please.yml`'s outputs and dispatch steps. `test:release` keeps them equal, and its "refused" cases now use a name outside the list.
- It is scored and validated with the other two: `mise run pana`'s default list, `publish:dry-run` and the CI `pana and publish dry run` job. pana could not score it before the widget was on pub.dev (it resolves the archive's dependencies there); with `ghostty_dart_flutter` 0.1.0 published it gives 160/160.
- The pinned plain Dart SDK packages it too: `dart pub publish --to-archive --skip-validation` of Dart 3.13.7 without Flutter and without network wrote an archive byte-identical (same sha256) to `flutter pub publish --to-archive --skip-validation` of Flutter 3.47.9 (checked 2026-11-12).
- Its pub.dev screenshot is a golden of a real `TerminalView` (`test/screenshot/`, Linux only, regenerated by `mise run test:goldens:update`), rendered with `ghostty_dart_flutter`'s pinned JetBrains Mono read from that package's `test/fonts/` (sha256-checked), so the repository keeps one copy of the fonts. That test reaches outside the package, so `.pubignore` keeps it out of the archive.
- `release_ready.sh` again pauses release-please for every package from the merge until the adapter's first tag exists. The first version is published by hand as before: `docs/internal/release-checklist.md`, "First publish of `ghostty_dart_xterm`" (X1–X6).
