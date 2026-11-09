# 0008. Prebuilt binary release pipeline

**Status:** Accepted (2026-11-09). Supersedes the "repackage the upstream xcframework" line of ADR 0003; the rest of ADR 0003 stands.

## Context
ADR 0003 makes prebuilt binaries from our CI the default source of the build hook. The research is in `docs/internal/research/2026-11-09-prebuilt-pipeline.md` (2026-11-09). It found five things that change the plan.

- **Apple:** the upstream xcframework holds static libraries, but Dart build hooks need dynamic ones. On a macOS host, upstream links Apple dylibs with Apple's `ld`, and iOS needs the Xcode SDK.
- **Android:** upstream builds against the NDK sysroot (`ANDROID_NDK_HOME`). Zig defaults to API 29, while Flutter's minSdk is 24. Upstream already links with 16 KB pages.
- **Reproducibility:** the default builds embed temp paths in their DWARF. With `-Dstrip=true` they are bit-identical across runs, and about 5x smaller.
- **Linux:** Zig 0.17.1 defaults to glibc 2.31; pinning 2.28 costs nothing.
- **Immutability:** GitHub immutable releases stop a published tag or asset from ever changing.

## Decision
**Targets and asset file names.** These names are a frozen contract between the workflow and `PrebuiltTarget.fileName`.

| Asset | Zig target | Built on |
|---|---|---|
| `libghostty-vt-linux-x64.so` | `x86_64-linux-gnu.2.28` | ubuntu-24.04 |
| `libghostty-vt-linux-arm64.so` | `aarch64-linux-gnu.2.28` | ubuntu-24.04 |
| `ghostty-vt-windows-x64.dll` | `x86_64-windows-gnu` | ubuntu-24.04 |
| `ghostty-vt-windows-arm64.dll` (best effort) | `aarch64-windows-gnu` | ubuntu-24.04 |
| `libghostty-vt-android-arm64.so` | `aarch64-linux-android.24` | ubuntu-24.04 + NDK |
| `libghostty-vt-android-arm.so` | `arm-linux-androideabi.24`, NEON + VFPv3-D16 | ubuntu-24.04 + NDK |
| `libghostty-vt-android-x64.so` | `x86_64-linux-android.24` | ubuntu-24.04 + NDK |
| `libghostty-vt-macos-arm64.dylib` | `aarch64-macos` | macos-15, pinned Xcode |
| `libghostty-vt-macos-x64.dylib` | `x86_64-macos` | macos-15, pinned Xcode |
| `libghostty-vt-ios-arm64.dylib` | `aarch64-ios` | macos-15, pinned Xcode |
| `libghostty-vt-ios-arm64-simulator.dylib` | `aarch64-ios-simulator` | macos-15, pinned Xcode |
| `libghostty-vt-ios-x64-simulator.dylib` | `x86_64-ios-simulator` | macos-15, pinned Xcode |

**Build settings.**
- Every build uses `-Doptimize=ReleaseFast -Dstrip=true`, from the minisign-verified upstream tarball, offline with `--system` deps.
- Minimum platform versions are Android API 24, iOS 14 and macOS 13. Upstream's floor is iOS 13, but the arm64 iOS simulator only exists from iOS 14 (first CI run, 2026-11-09); Flutter itself requires iOS 15, so no app loses anything. The hook fails with a clear message when the app targets something lower.
- The NDK is r28c (`28.2.13676358`), the one Flutter 3.47.9 pins. It is downloaded from dl.google.com and verified against a sha256 pinned in the repo plus Google's SHA-1. `ANDROID_NDK_HOME` is always set explicitly.

**Pipeline.**
- **Build.** A reusable workflow (`native-build.yml`) builds every target. Its build jobs have `contents: read`, no secrets, no write token and no `actions/cache`. Tarballs and the NDK are verified and extracted into a fresh directory on every run, so a poisoned cache cannot feed a build.
- **Provenance.** The same reusable workflow attests every asset and `SHA256SUMS` with `actions/attest`, in a dedicated job that is the only one with `id-token`/`attestations` write. Because the signer is a reusable workflow, this is SLSA Build L3. `native:pin` checks that the signer is `native-build.yml`.
- **Canonical bytes.** The verify job publishes the canonical `SHA256SUMS`. Smoke and release jobs check their copies against it, so the bytes released are the bytes that were compared and tested.
- **PR validation.** The release workflow also runs on pull requests that touch the native pipeline: it builds, verifies and smoke-tests, but does not attest or release.
- **Reproducibility check.** Each non-Apple target is built twice in independent jobs, and the release fails if the hashes differ.
- **Verification.** Format checks run on every binary: architecture, exported `ghostty_*` symbols, no unexpected `NEEDED` or imports, Android LOAD alignment ≥ 16 KB, Mach-O min OS.
- **Smoke tests.** Our full Dart test suite runs against the downloaded binary on real runners: Linux x64/arm64, macOS arm64/x64, Windows x64/arm64.
- **Release.** A single job, gated by the protected `native-release` environment and holding only `contents: write`, publishes the GitHub release with `gh` (draft, upload, publish, not marked latest). GitHub immutable releases are enabled on the repo.
- **Tags.** Tags are `native-v<upstream version>-r<n>`; the first is `native-v1.0.0-r1`. Immutable releases forbid reusing a tag, so a rebuild bumps `r`. A ruleset protects `native-v*`.
- **Pinning.** `mise run native:pin <tag>` verifies the attestations and writes the hashes into `prebuilt.dart`. That reaches users through a normal reviewed PR.

**Hook.**
- Downloads have connect and idle timeouts, a size cap, and one retry on transient errors.
- A 404 or a failed connection fails with instructions for `url_pattern`, `path` and `system`.

**Not adopted (overkill for now):**
- extra cosign or minisign signatures on top of the attestations;
- slsa-github-generator;
- Android emulator tests in the release pipeline;
- musl prebuilts;
- harden-runner (yet another third-party action in the trust base).

## Consequences
- Users need no toolchain on any listed platform. Every asset can be traced to a workflow run (`gh attestation verify`) and checked by rebuilding it.
- About 750 MB of NDK download per release run (cached).
- The Apple build depends on a pinned Xcode on GitHub's macOS images. When the image drops that Xcode, we bump the pin.
- A bad release is never edited. We cut a new `-r<n>` and pin it.
