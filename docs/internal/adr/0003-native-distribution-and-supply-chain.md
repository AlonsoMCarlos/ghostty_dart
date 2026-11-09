# 0003. Native library distribution and supply chain

**Status:** Accepted (2026-11-09)

## Context
Dart build hooks (stable since Dart 3.10) only support dynamic linking. Upstream publishes signed source, an xcframework and wasm, but no Linux/Windows/Android binaries. Build-time code runs with the user's permissions; this machine suffered a real supply-chain compromise via a Rust `build.rs` (2026-08-20). Users of our package face the same class of risk from our hook.

## Decision
- **Default:** the hook downloads prebuilt binaries produced by **our** CI from the minisign-verified upstream tarball, and verifies each against a **sha256 pinned in the published package source**. Binaries carry SLSA provenance (`actions/attest-build-provenance`).
- For Apple and web, repackage the official upstream artefacts (xcframework slices, `-small.wasm`) after verifying their signatures; still pinned by sha256.
- **Opt-in `user_defines`** (documented in a dartdoc topic "Build hook options"):
  - `source: prebuilt | system | zig` — `system` uses an installed `libghostty-vt.so.1` (pkg-config/SONAME); `zig` builds from the pinned tarball with Zig 0.17.x and an empty `ZIG_GLOBAL_CACHE_DIR`.
  - `url_pattern` for mirrors / air-gapped builds; `path` for a local binary.
- The hook makes **no network access other than the pinned download**, never resolves anything unpinned, and fails closed on hash mismatch.
- Dependencies: committed `pubspec.lock`, Renovate with `minimumReleaseAge: 3 days`, lockfile diffs reviewed in every PR.
- Platforms: Linux x64/arm64, macOS x64/arm64, Windows x64, Android arm64/arm/x64, iOS arm64 (+ simulator), Web (wasm). Windows arm64 best-effort (not tested upstream).

## Consequences
- Users need no Zig toolchain by default; paranoid users can build or bring their own library.
- We own a release pipeline for native binaries per upstream version.
