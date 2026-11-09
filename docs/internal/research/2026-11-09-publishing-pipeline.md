# R1. Publishing `ghostty_dart` to pub.dev: pana, OIDC, release-please, DCO

Researcher: stage 0, run `20261109-first-release`. Date: **2026-11-09**. Every source below was read that day.
**[V]** = verified at the source (API, source code or a local run). **[I]** = inferred.
This builds on `docs/internal/research/2026-11-09-community-practices.md`. Corrections to it are marked **(corrects prior)**.

---

## 1. pana scoring today

### Version
- **[V]** pana **0.23.19** was published on 2026-09-01. That is 69 days ago, so it is past the cooldown, and it is the latest version. It requires SDK `^3.11.0`. Sources: `https://pub.dev/api/packages/pana` and the 0.23.19 archive's pubspec.
- **[V]** pub.dev itself runs pana 0.23.19 with Dart 3.13.7 and Flutter 3.47.8. That is the `panaRuntimeInfo` in `https://pub.dev/api/packages/<pkg>/metrics` for sqlite3, jni and objective_c.
- **[V]** Dart stable is 3.13.7 (2026-10-22). Beta is 3.15.0-118.1.beta. Source: `storage.googleapis.com/dart-archive/channels/{stable,beta}/release/latest/VERSION`.

### Sections: 160 points in total
Source **[V]**: the `metrics` API (section ids and points) and pana 0.23.19's `lib/src/report/*.dart`.

| id | Max | Contents |
|---|---|---|
| `convention` | 30 | Valid pubspec (10), README (5), CHANGELOG (5), OSI licence (10) |
| `documentation` | 20 | ≥20% of the API has dartdoc (10), plus an example (10) |
| `platform` | 20 | Platform support. Claiming Web without being Wasm-ready caps this at 10. |
| `analysis` | 50 | Errors, warnings, lints and formatting |
| `dependency` | 40 | Latest versions accepted (10), latest SDK supported (10), `pub downgrade` analyses cleanly (20) |

There is no longer a separate null-safety section; null safety is now only a tag (`is:null-safe`).

### Real packages that use build hooks: current scores
Source **[V]**: `https://pub.dev/api/packages/<p>/metrics` and `/score`, 2026-11-09.

| Package | Hook | Score | Points lost |
|---|---|---|---|
| `sqlite3` 3.9.1 | `hook/build.dart` downloads prebuilt binaries (`downloadIntoOutputDirectoryShared`) | **150** | platform 10/20, because it claims Web but `lib/sqlite3.dart` imports `dart:ffi` (not Wasm-ready). Analysis 50/50 and conventions 30/30. |
| `objective_c` 9.6.3 | `hook/build.dart` (compiles C) | **150** | documentation 10/20, "No example found". Platform **20/20**. |
| `jni` 1.1.2 | Flutter plugin | 160 | none |
| `ffi`, `hooks`, `code_assets` 2.2.0 | (pure Dart) | 160 | none |
| `native_toolchain_c` 0.19.6 | — | 150 | missing example |

**Conclusion [V]:** a pure-Dart `dart:ffi` package with a downloading hook and no Web claim gets platform 20/20 (objective_c), and nothing in the scoring penalises the downloading hook (sqlite3 gets 50/50 analysis and 30/30 conventions). **160/160 is reachable.** The points that can be lost are the example and documentation, analysis, and dependency downgrade.

### Does pana run the hook?
- **[V] No.** In 0.23.19 `lib/` there is no reference to `hook`, `native_assets` or running tests. pana only does the following:
  - `pub get`, `pub upgrade`, `pub downgrade` and `pub outdated`. These only resolve and download; they never run hooks.
  - `dart analyze`. Since 0.23.17 it runs with analyzer **plugins disabled**.
  - dartdoc.
- **[V] pana needs network:**
  - pub resolution;
  - `pub global activate dartdoc`, unless `--dartdoc-version sdk` is passed;
  - a git clone of `repository` to verify it;
  - URL checks;
  - downloading `lints/core.yaml` from GitHub, as a fallback only.
- **[V] It counts only diagnostics in `lib/`, `bin/` and `pubspec.yaml`** (`isAnalysisTarget`, `utils.dart:329`).
  - So `hook/build.dart` is **not** scored. Our CI's `dart analyze --fatal-infos` is what keeps it clean.

### Conventions and other requirements (pana 0.23.19 `template.dart`) [V]
- **`description`**: 50–180 characters is the scored range (pana suggests 60–180), and at most 10% may be non-ASCII.
  - Ours is **150** characters of ASCII, so it passes.
- **`repository`**: it must be cloneable, and the clone must contain a `pubspec.yaml` with `name: ghostty_dart`, a `version` and **no `publish_to`**.
  - Checked with `gh api`: the repo is **public**, and the member pubspec has no `publish_to`. The root pubspec does have `publish_to: none`, but its name is `ghostty_dart_workspace`, so it is not the matching file.
- **CHANGELOG**: it must mention the current version string.
  - Ours mentions `0.1.0-dev.1`. If the version changes to `0.1.0`, the heading must change with it.
- **Licence**: it must be OSI-approved. Ours is MIT, so it passes.
- **README**: it must exist and must not use `http:` links. Ours has none.
- **Example**: any file under `example/`. Ours has `example/main.dart`.
- **Dartdoc**: coverage must be at least 20% for the 10 points. AGENTS.md targets ≥80%, and `public_member_api_docs` is on.
- **Not scored**: `topics` (only turned into `topic:` tags), `funding`, `screenshots`.
  - pana validates screenshots if they are present.
  - `topics`: pub.dev allows at most 5; ours has 5.

### Pitfall: `analysis_options.yaml` in the archive
- `packages/ghostty_dart/analysis_options.yaml` does `include: ../../analysis_options.yaml`. That file is **not in the published archive**.
- pana passes `include:` through (`updatePassthroughOptions`).
  - Diagnostics in `analysis_options.yaml` are not scored, so **no points are lost [V]**.
  - But the published package ships a dangling include. The analysis would also lose `strict-*` and our extra lints on pub.dev **[I]**.
- Recommendation:
  - make the package's options self-contained, with `include: package:lints/recommended.yaml`;
  - add `lints` as a package dev_dependency. pana 0.23.19 keeps hosted dev_dependencies during analysis (CHANGELOG 0.23.19).

## 2. Running pana reproducibly, with pinned dependencies

### Recommendation
- Create a separate tool package, **`tool/pana/`**, with:
  - `publish_to: none`;
  - **no `resolution: workspace`**;
  - `dependencies: pana: 0.23.19` (exact);
  - a committed `tool/pana/pubspec.lock`.
- Run it as `dart pub get --enforce-lockfile -C tool/pana`, then `dart run tool/pana/bin/…` or `dart run pana` from that directory.
- Add a `mise run pana` task, plus a CI step.
- **Why not a workspace member:**
  - pana pins `analyzer >=13 <15` and brings about 25 dependencies (http, html, markdown, …) into the single workspace lockfile that `ghostty_dart`'s development resolves against.
  - A separate lock isolates them.
- **Is the nesting legal?**
  - dart.dev/tools/pub/workspaces (page updated 2026-05-15) only errors on a stray pubspec *between* the workspace root and a member. `tool/pana/` is not on a member's path, so it is legal **[V]**.
  - A package without `resolution: workspace` resolves on its own **[I]**.
- **`tool/check_cooldown.dart` must also check `tool/pana/pubspec.lock`.** Today it only reads the root lock, at line 12 **[V]**.

### Avoiding unpinned code inside pana
- **By default pana runs `dart pub global activate dartdoc`**, which installs the latest dartdoc, unpinned (`sdk_env.dart:557-590`) **[V]**.
  - **Pass `--dartdoc-version sdk`**, which uses the pinned SDK's `dart doc` instead.
- pana's dependency checks (`pub upgrade` and `pub downgrade`) resolve the newest and oldest versions.
  - They ignore our root `dependency_overrides`, because pana strips `dependency_overrides`, `workspace` and `resolution` (`sdk_env.dart:643-683`).
  - So pana will download `code_assets` 2.2.0 (published 2026-11-06), but it only analyses it and never runs it **[V]**.
  - This is acceptable, and it is identical to what pub.dev does.

### Flutter
- Flutter is not needed for a pure-Dart package. pana uses the Dart SDK that runs it.
- Without `--flutter-sdk` or `FLUTTER_ROOT`, it only logs a warning (`sdk_env.dart:161-168`) **[V]**.
- Under mise, the Dart in use is Flutter 3.47.9's bundled Dart 3.13.7.
  - Optionally pass `--flutter-sdk "$(dirname "$(dirname "$(command -v flutter)")")"` to silence the warning.

### Workspace members
- Supported since pana issues #1369 and #1394, both closed in 2024: pana strips `resolution` and `workspace` before resolving.
- Since 0.23.18 (#1619, closed 2026-08-06), git-based root detection is gone.
  - With **`--project-root <repo>`**, pana copies the whole tree.
  - Without it, pana copies only the package directory.
- **Run without `--project-root`.** That copies only the package, which mirrors what pub.dev analyses (the archive). Our package references nothing outside itself except the analysis include above **[I]**.

### Flags in 0.23.19 (`bin/pana.dart`) [V]
| Flag | Effect |
|---|---|
| `--exit-code-threshold N` | Exits non-zero if (max − granted) > N. Use `0`. |
| `--json` / `-j` | Prints the JSON report, with `scores.grantedPoints/maxPoints` |
| `--dartdoc-version sdk` | Uses the SDK's `dart doc` (see above) |
| `--no-dartdoc` | Skips the documentation coverage check |
| `--project-root` | Copies the whole tree (see above) |
| `--flutter-sdk`, `--dart-sdk` | SDK paths |
| `--hosted` | Analyses a package downloaded from pub.dev |

- **`--no-warning` is deprecated and has no effect** (hidden flag, "Deprecated has no effect"). Do not use it.

**Command:**
```sh
dart run pana --dartdoc-version sdk --exit-code-threshold 0 packages/ghostty_dart
```
It runs from `tool/pana`, with the package path given as absolute or relative. It needs network access.

## 3. Automated publishing (OIDC) from GitHub Actions
Main source: dart.dev/tools/pub/automated-publishing (page updated 2026-05-15) **[V]**.

### Requirements on pub.dev
- **[V] The first publish is manual.** The docs say you "can only automate publishing of existing packages".
  - The maintainer runs `dart pub publish`, which opens a Google OAuth flow in the browser.
  - The pub `--help` of Dart 3.13.7 offers no non-interactive first-publish path.
- **[V] The names are free.** `https://pub.dev/api/packages/{ghostty_dart,ghostty_dart_flutter,ghostty_dart_xterm}` all return **404**.
- **[V] Admin settings** (`pub.dev/packages/ghostty_dart/admin`, "Automated publishing"):
  - repository `AlonsoMCarlos/ghostty_dart`;
  - **tag pattern `ghostty_dart-v{{version}}`**. Monorepos use one pattern per package; the pattern must contain `{{version}}`, which must equal the pubspec version;
  - "Require GitHub Actions environment" set to `pub.dev`.
- **[V] What pub.dev accepts** (pub-dev source, `app/lib/package/backend.dart:2279-2315`, last commit 2026-11-03):
  - only `push` and `workflow_dispatch` events (`release` events are rejected);
  - only when the OIDC token has `ref_type == tag`.
  - Two admin toggles control the events: `isPushEventEnabled` (default **true**) and `isWorkflowDispatchEventEnabled` (default **false**; the checkbox reads "Enable publishing from `workflow_dispatch` events").
- **[V] Verified publisher:** you cannot publish a new package straight to a publisher. Publish it from a Google account, then transfer it; the transfer is irreversible. Source: dart.dev/tools/pub/publishing, updated 2026-05-15.

### The reusable workflow `dart-lang/setup-dart/.github/workflows/publish.yml`

**Release `v1.8.1` (2026-08-28)**
- [V] The tags are **lightweight**:
  - `refs/tags/v1.8.1` points to commit `6afc89df92d6eb3834022f73cd65adc8cdfcb92d`;
  - `v1` points to the same commit.
- In that release, `publish.yml` is a **single job** with `id-token: write`. It runs:
  1. checkout;
  2. setup-dart;
  3. `flutter-actions/setup-flutter` (version `latest`, channel `stable`, so Flutter is unpinned);
  4. `dart pub get`;
  5. `--dry-run`;
  6. `dart pub publish -f`.
- Its only inputs are `environment` and `working-directory`.

**Not yet released, on `main` at `a1d8526c926344e01ba48a7368788c05ac98cb29` (2026-10-31, 9 days old)**
- PR #203 (2026-10-22) split it into **three jobs**:
  1. `validate` (`permissions: {}`): pub get and `--dry-run`.
  2. `package` (`permissions: {}`): `dart pub publish --to-archive --skip-validation` run under `unshare -n`, so with no network.
  3. `publish` (`id-token: write`, with `environment`): only setup-dart, then `dart pub publish --from-archive --force`. There is no checkout and no pub get.
- PR #206 (2026-10-31) added more inputs: `sdk` (default `stable`), `use-flutter` (default **true**) and `test-run`.
- **(corrects prior)** The prior note described the three-job design as `@v1`. In fact it exists only on `main`, unreleased.
- **[V]** `--to-archive` and `--from-archive` are hidden flags but accepted by Dart 3.13.7. Locally, `dart pub publish --dry-run --to-archive=…` is accepted, while an unknown flag fails with "Could not find an option".

**Pinning and permissions**
- **[V] Pinning by SHA:** reusable workflows accept `@<full-sha>`. The caller must grant `permissions: id-token: write`, because a reusable workflow cannot raise permissions above its caller's.
- Inside the workflow, setup-dart sets up the OIDC token. The docs say "the token is created and configured in the `dart-lang/setup-dart` step".

**Conflicts with our rules and our workspace [I, important]**
- `dart pub get` in a workspace member resolves the **whole workspace**. That includes `benchmarks` → `xterm` → Flutter. So:
  - `use-flutter: false` breaks resolution (AGENTS.md notes it fails on the Linux runner);
  - `use-flutter: true` installs an **unpinned latest Flutter** through a third-party action.
- It also uses `dart pub get` without `--enforce-lockfile`.

**Options**
- **(a) Use `publish.yml@a1d8526…` (main) with `use-flutter: true` and `sdk: 3.13.7`.**
  - This is the "strongly encouraged" path.
  - The cost is accepting unpinned Flutter in the `validate` job. That job has no permissions, and pub get does not run hooks, so the risk is limited.
  - The `publish` job, which holds the token, does not use Flutter.
- **(b) Recommended: our own `publish.yml` that copies the three-job design.**
  - `validate` runs mise (Flutter 3.47.9 pinned), `flutter pub get --enforce-lockfile`, then `dart pub publish --dry-run`.
  - `package` runs `--to-archive` offline.
  - `publish` has `environment: pub.dev` and `id-token: write`, and uses `dart-lang/setup-dart@6afc89df92d6eb3834022f73cd65adc8cdfcb92d # v1.8.1` with `sdk: 3.13.7`, then `--from-archive --force`.
  - It is fully pinned. dart.dev documents a custom workflow as valid.

### Protected `pub.dev` environment [V]
Source: docs.github.com, deployments-and-environments.
- **Required reviewers** are available on public repos on the Free plan. Up to 6 can be listed, and one approval is enough.
  - If "Prevent self-review" is on, a solo maintainer cannot approve their own run. **Leave it off.**
- **Deployment branches and tags:** select "Selected branches and tags" with the tag pattern `ghostty_dart-v*`.
  - The rule is matched against `GITHUB_REF`. A `*` does not match `/`.
- The `environment` must match the one on pub.dev. Then nobody with push access can get around it by editing the workflow (automated-publishing page).

## 4. release-please (manifest mode, Dart)

### Versions and SHAs [V]
| Item | Version and date | SHA |
|---|---|---|
| `googleapis/release-please-action` | **v5.0.0**, 2026-04-22. The tag is lightweight. Breaking: it runs on node24. It bundles **release-please 17.6.0** (from its `package-lock.json`). | `45996ed1f6d02564a971a2fa1b5860e934307cf7` |
| `v5` | Annotated tag object `0dfd8538…`, which points to the same commit | `45996ed1f6d02564a971a2fa1b5860e934307cf7` |
| `actions/create-github-app-token` | **v3.3.0**, 2026-10-12. The tag is lightweight, and `v3` is the same commit. | `64ab729a6294000f5aa4a4bc0b73d1f32bc45510` |

- create-github-app-token v3 inputs: `client-id` (`app-id` is **deprecated**), `private-key`, `owner`, `repositories`, `permission-*`.

### Dart support [V]
Source: release-please `src/strategies/dart.ts` and `src/updaters/dart/pubspec-yaml.ts`, at v17.6.0 and on main.
- `release-type: dart` updates `CHANGELOG.md` and the `version:` line in `pubspec.yaml`.
- The component name defaults to the pubspec `name`.

**Bug, still open: prerelease versions get mangled.**
- The regex is `^version: ([0-9.]+)\+?(.*$)`. For `0.1.0-dev.1` it treats `-dev.1` as a build number and writes **`<new>+-dev.1`**.
- The bug is filed as issue **#2400** (open since 2024-10-11). Fix PRs #2406 and #2703 are still open. The file has not changed since 2022.
- **⇒ Never keep a prerelease version in `pubspec.yaml` while release-please owns it.**

### Initial version [V]
- When the manifest has no entry for a package, `initialReleaseVersion()` returns **1.0.0** (`base.ts:744-749`).
- **We must seed `.release-please-manifest.json` with `{"packages/ghostty_dart": "0.1.0"}`**, or set `initial-version`.

### Configuration (`release-please-config.json`) [V]
Source: schema `schemas/config.json` and `docs/manifest-releaser.md` at v17.6.0.
```json
{
  "release-type": "dart",
  "include-component-in-tag": true,
  "tag-separator": "-",
  "bump-minor-pre-major": true,
  "bump-patch-for-minor-pre-major": true,
  "signoff": "ghostty_dart release bot <…@users.noreply.github.com>",
  "bootstrap-sha": "<sha of the 0.1.0 publish commit>",
  "packages": { "packages/ghostty_dart": {} }
}
```
- `include-component-in-tag` defaults to `true`, and the default tag form is `<component>-v<version>`. So the tag is `ghostty_dart-v0.1.1`, which matches the pub.dev pattern.
- `bump-minor-pre-major`: in 0.x, a BREAKING CHANGE bumps the minor, which matches AGENTS.md's "minor = breaking".
- `bump-patch-for-minor-pre-major`: in 0.x, `feat` bumps the patch. Without it, `feat` would also bump the minor, which is acceptable but noisy. **[I]** Recommend turning it on.
- Prereleases go through `"versioning": "prerelease"` plus `"prerelease": true` and `prerelease-type`. **But** the Dart updater bug above makes this unusable for pubspec.
- `signoff`: a top-level string. It adds `Signed-off-by:` to release-please's commits, which the DCO check needs.

### Tokens and triggers
- **[V]** Resources created with `GITHUB_TOKEN` do not start new runs. The exceptions are `workflow_dispatch` and `repository_dispatch` (docs.github.com, "GITHUB_TOKEN").
- So a tag or release that release-please creates with `GITHUB_TOKEN` does not trigger `on: push: tags`. Also, CI does not run on its release PR.

**Option A: GitHub App**
- Tokens expire after one hour, and access is limited to one repository.
- **[I]** I could not verify that a tag created through the Releases API triggers `push: tags`. Sources only show it in practice (openai-ruby#334).
- The maintainer must set up, by hand:
  1. Create a GitHub App under the personal account:
     - webhook off;
     - permissions **Contents: Read & write** and **Pull requests: Read & write** (Metadata: read is mandatory);
     - **Issues: Read & write**, so it can create the `autorelease: pending/tagged` labels **[I]**;
     - **Workflows: write** only if release PRs will ever touch `.github/workflows` (they won't).
  2. Install it only on `AlonsoMCarlos/ghostty_dart`.
  3. Store the repo variable `RELEASE_APP_CLIENT_ID` and the repo secret `RELEASE_APP_PRIVATE_KEY`.
     - Better: make them environment secrets of a `release` environment limited to `main`.
  4. In the workflow, mint a token with `create-github-app-token@64ab729…` and pass it to `release-please-action@45996ed…` as `token`.

**Option B: no App (simplest secure fallback) [V for the mechanics]**
1. release-please runs with `GITHUB_TOKEN` (`contents: write`, `pull-requests: write`).
2. When its output says a release was created, a step runs `gh workflow run publish.yml --ref ghostty_dart-v<version>`. That needs `actions: write`.
3. `workflow_dispatch` always creates a run. Running on a tag ref gives the token `ref_type=tag`.
4. On pub.dev, **turn on "Enable publishing from workflow_dispatch events"**.
- Cost: CI does not run on release PRs created with `GITHUB_TOKEN`.
  - **[I]** It can be dispatched the same way, because `ci.yml` already has `workflow_dispatch`, or the maintainer can close and reopen the PR.
- There is no long-lived secret at all.

**Option C: a PAT**
- A fine-grained PAT works, but it is a long-lived secret tied to the user. **Not recommended.**

**Recommendation:**
- **B** for the first releases: there are no secrets, and pub.dev accepts it.
- **A** if CI on release PRs becomes annoying.
- The publish step is gated by the `pub.dev` environment in both cases.

## 5. DCO
- The **DCO GitHub App** (`dcoapp/app`) is still maintained: last push 2026-11-08, 352 stars.
  - Its last tagged release is v1.0.0, from 2022.
  - It is the norm in CNCF and Linux Foundation projects, and it supports remediation commits.
  - It is a third-party app with repo access. **[V]** Source: the repo and its README.
- **Recommended: our own check, with no app.**
  - A `dco` job in `ci.yml`:
    - on `pull_request`, never `pull_request_target`;
    - `permissions: contents: read`;
    - `actions/checkout` pinned, with `fetch-depth: 0` and `persist-credentials: false`.
  - It runs `mise run dco`, which calls `tool/check_dco.sh "$BASE_SHA" "$HEAD_SHA"`.
    - The SHAs come from `github.event.pull_request.base.sha` and `.head.sha`, passed through `env:`, never interpolated into the script.
  - The script loops over `git rev-list --no-merges base..head`. For each commit it reads `%an <%ae>` and `%(trailers:key=Signed-off-by,valueonly)`, and fails unless one trailer equals the author.
  - A line in CONTRIBUTING explains `git commit -s` and how to fix commits (`git rebase --signoff`).
- GitHub's repo setting "Require contributors to sign off on web-based commits" covers web commits only. Turn it on as well.
- The release-please `signoff` option (§4) keeps its own commits compliant.

## 6. Pre-release versus 0.1.0, dry-run, naming

### First version
- **Publish `0.1.0`, not `0.1.0-dev.1`.**
  1. A published version is permanent (dart.dev/tools/pub/publishing: "a published package lasts forever"). A `-dev.1` adds a version without telling users anything that `0.x` does not already say.
  2. pub "prefers stable releases when available", so users must explicitly opt in to prereleases (same page).
  3. The release-please Dart updater breaks on prerelease versions (#2400).
  4. ADR and AGENTS.md: "start at `0.1.0`".
- The safety net: a version can be **retracted within 7 days** (same page).
- Change `pubspec.yaml` and the CHANGELOG heading to `0.1.0` together, because pana checks that the CHANGELOG mentions the current version.

### `dart pub publish --dry-run` in CI
- **Yes:** one step per publishable package (`mise run publish:dry-run`).
- **[V]** A local run today, with Dart 3.13.7 from `packages/ghostty_dart`:
  - "**0 warnings and 1 hint**", with an archive of 429 KB;
  - the hint is "Non-dev dependencies are overridden in ../../pubspec.yaml". That comes from our cooldown overrides of `code_assets` and `native_toolchain_c`. It is expected, and it disappears once they age and are removed.
  - The run left the git tree clean.
- Hints do not fail the command; warnings do.
- The archive includes `test/` and `tool/ffigen.dart`. That is acceptable. Optionally add a `.pubignore` for large fixtures.

### "Unofficial" naming and pub.dev policy
- **[V]** pub.dev/policy says:
  - "Publishers are solely responsible for the packages and package names they use";
  - trademark holders file complaints through "report package", and pub.dev does not mediate;
  - squatting is "solely to reserve a name". **Do not publish empty `ghostty_dart_flutter` or `ghostty_dart_xterm` placeholders.**
- There is no rule against descriptive or nominative names. Our "unofficial, not affiliated" notice and the absence of the logo are consistent with ADR 0007 and ADR 0009.
- The policy also requires following Google's brand guidelines for the Dart and Flutter names.
  - A `*_dart` suffix is widespread **[I]**.

## Action list for the plan
1. Set `version: 0.1.0` and the CHANGELOG heading to `## 0.1.0`.
2. Make `packages/ghostty_dart/analysis_options.yaml` self-contained.
3. Add `tool/pana/` (exact `pana: 0.23.19` plus a lock), extend `check_cooldown.dart` to cover it, and add the tasks `mise run pana` (`--dartdoc-version sdk --exit-code-threshold 0`) and `mise run publish:dry-run`, plus CI steps.
4. Add `.github/workflows/publish.yml`: our own three-job version (option 3b), triggered by `push: tags: ['ghostty_dart-v*']` and `workflow_dispatch`, with `environment: pub.dev`.
5. Add release-please: config and manifest seeded with `0.1.0` and `bootstrap-sha`, `bump-minor-pre-major`, `signoff`, and token option B.
6. Add the `dco` job and `tool/check_dco.sh`.
7. **Manual steps for the maintainer:**
   - first `mise exec -- dart pub publish` from `packages/ghostty_dart`, on the release commit;
   - create the tag `ghostty_dart-v0.1.0`;
   - pub.dev admin: repository, the pattern `ghostty_dart-v{{version}}`, the required environment `pub.dev`, and the workflow_dispatch toggle if using option B;
   - GitHub: the `pub.dev` environment with a required reviewer and a tag rule, and the web sign-off setting;
   - optionally, transfer the package to a verified publisher (irreversible).
8. Update AGENTS.md with the new tasks and flow, and add an ADR for the custom publish workflow and the token choice.
