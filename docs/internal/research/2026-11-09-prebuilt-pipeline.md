# Research: native release pipeline for libghostty-vt prebuilt binaries

Researcher: stage 0. Date of every observation: **2026-11-09** unless stated.
Host: devbox, Linux x86_64 (Debian 13). Zig 0.17.1 via mise. Upstream source:
`.native-cache/src/libghostty-vt-1.0.0` (minisign- and sha256-verified tarball,
`native/upstream.json`). Scratch outputs: `$S` =
`/tmp/claude-1000/-home-titere-dev-libghostty-vt-flutter-version/58a05b62-74e9-4e6f-8897-0625310b3432/scratchpad`.

## 0. Cross-build matrix tried from Linux (`mise x -- bash tool/native/build.sh <target>`)

| Zig target | Result | Evidence |
|---|---|---|
| `aarch64-linux-android` | **FAIL** `error: configuration failed: AndroidNDKNotFound` (pkg/android-ndk/build.zig:41, called from pkg/simdutf/build.zig:36) | `$S/logs/aarch64-linux-android.log` |
| `arm-linux-androideabi` | FAIL, same error | `$S/logs/arm-linux-androideabi.log` |
| `x86_64-linux-android` | FAIL, same error | `$S/logs/x86_64-linux-android.log` |
| `aarch64-macos` | OK. Mach-O arm64 dylib, 2.17 MB | `.native-cache/out/aarch64-macos/lib/` |
| `x86_64-macos` | OK. Mach-O x86_64 dylib, 2.40 MB | `.native-cache/out/x86_64-macos/lib/` |
| `aarch64-ios` | **FAIL** `error: configuration failed: XcodeiOSSDKNotFound` | `$S/logs/aarch64-ios.log` |
| `aarch64-ios-simulator` | FAIL, same error | `$S/logs/aarch64-ios-simulator.log` |
| `x86_64-windows-gnu` | OK. `bin/ghostty-vt.dll` 2.52 MB plus `.pdb` 8.4 MB | `.native-cache/out/x86_64-windows-gnu/` |
| `aarch64-windows-gnu` | OK. PE32+ ARM64 DLL, 2.09 MB | `.native-cache/out/aarch64-windows-gnu/` |
| `aarch64-linux-gnu` | OK. 11.5 MB, not stripped | `.native-cache/out/aarch64-linux-gnu/` |
| `x86_64-linux-musl` | OK. 12.2 MB, `NEEDED libc.so` | `.native-cache/out/x86_64-linux-musl/` |
| `x86_64-linux-gnu.2.28` | OK | `.native-cache/out/x86_64-linux-gnu.2.28/` |
| `x86_64-linux-gnu -Dstrip=true` | OK. **2.35 MB**, compared with 12.2 MB unstripped | `$S/repro/strip.so` |

Each build takes about 3–5 min on 6 cores with a fresh Zig cache. Note that zig also
writes a local `.zig-cache/` inside the source dir (the configure line shows
`.zig-cache/o/<hash>/configurer`), so the "fresh cache" in `build.sh` only covers the global cache.

## 1. Android

**The NDK is required; Zig alone does not work.** I tried it (table above).
- Source: `pkg/android-ndk/build.zig` (upstream 1.0.0): "NB: This is a workaround until zig natively supports bionic cross-compilation (ziglang/zig#23906)".
- It locates the NDK via `ANDROID_NDK_HOME`, then `ANDROID_HOME`/`ANDROID_SDK_ROOT` (it picks the *latest* `ndk/<semver>`), then `~/Android/Sdk`.
- Only the NDK **sysroot** is used: headers, crt objects and bionic stub libs, through a generated `libc.txt`. The compiler stays Zig's clang.
- Host tag: `linux-x86_64`, `darwin-x86_64` or `windows-x86_64`.
- Upstream lists Android as tier 1 ("Built and tested in CI") in `PACKAGING-LIBGHOSTTY.md` §Platform Support. The tarball does not include upstream's CI workflow, so the NDK version upstream uses is unknown.
- **Pin `ANDROID_NDK_HOME` explicitly.** Never rely on `ANDROID_HOME`, because the "latest" auto-pick is non-deterministic.

**Does it link libc?** Yes, everywhere except freestanding/wasm. The Linux .so (`readelf -d .native-cache/out/x86_64-linux-gnu/lib/libghostty-vt.so.1.0.0`) shows:
```
NEEDED libm.so.6, libc.so.6, librt.so.1 ; SONAME libghostty-vt.so.1 ; FLAGS BIND_NOW
```
- Upstream comment, `src/build/GhosttyLibVt.zig`: "Vendored C++ dependencies are built in no-libcxx mode so consumers don't need libc++."
- So there is no libc++ dependency on Android either.

**NDK version options** (as of 2026-11-09):
- Flutter 3.47.9 (our mise pin) pins `ndkVersion = '28.2.13676358'` (r28c) and `minSdkVersion = 24`.
  - Source: `$(mise where flutter)/packages/flutter_tools/lib/src/android/gradle_utils.dart:63,69`.
- The ubuntu-24.04 runner image `20261101.360.1` preinstalls NDK `27.3.13750724` (default; `ANDROID_NDK_HOME`/`ANDROID_NDK_ROOT`), `29.0.14206865` and `30.0.16248370` (`ANDROID_NDK_LATEST_HOME`). It does **not** ship 28.2.
  - Source: https://raw.githubusercontent.com/actions/runner-images/main/images/ubuntu/Ubuntu2404-Readme.md (fetched 2026-11-09).
- Google's repository manifest (`https://dl.google.com/android/repository/repository2-3.xml`, fetched 2026-11-09) publishes **SHA-1 only**:
  - `28.2.13676358` → `android-ndk-r28c-linux.zip`, sha1 `a7b54a5de87fecd125a17d54f73c446199e72a64`
  - `27.3.13750724` → `android-ndk-r27d-linux.zip`, sha1 `22105e410cf29afcf163760cc95522b9fb981121`
  - `30.0.16248370` → `android-ndk-r30-linux.zip`, sha1 `5107f898313790e449e87eee2183d9a20602dee9`
- developer.android.com/ndk/downloads (fetched 2026-11-09) gives "Latest LTS Version (r30)", 738,633,529 bytes, the same SHA-1.

**Cleanest pinned option.** Download `https://dl.google.com/android/repository/android-ndk-r28c-linux.zip` (matches Flutter's NDK) with curl. Check it against **both** a sha256 that we pin in the repo (computed once; TOFU, because Google only publishes SHA-1) and Google's SHA-1, then unzip and set `ANDROID_NDK_HOME`. That is about 740 MB per run; cache it with `actions/cache` keyed on the sha256.
- The zero-download alternative: use the preinstalled `/usr/local/lib/android/sdk/ndk/27.3.13750724` by explicit path, and fail if it is missing. The runner image is already in our TCB.
- Use `nttld/setup-ndk` (v1.6.0, 2026-02-11) **only if** we accept a third-party action. It is not needed.

**API level (important).**
- Zig 0.17.1's default Android API level is **29** (`lib/std/Target.zig`: `.android = switch (arch) { .riscv64 => 35, else => 29 }`).
- Flutter's default minSdk is **24**. A library linked against API-29 bionic stubs can reference symbols that are missing on API 24–28 devices, which makes `dlopen` fail there.
- **Build with an explicit API, e.g. `-Dtarget=aarch64-linux-android.24`.** The syntax is the trailing `.N` on the ABI; see the Zig test `"aarch64-linux.3.10...4.4.1-android.30"` in `lib/std/Target/Query.zig:731`.
- Below API 29 Zig uses emulated TLS through compiler-rt, which needs libc (`Target.zig:2324`). We already link libc. **Not built here: no NDK.** Must be verified in CI.
- The hook can read `input.config.code.android.targetNdkApi`. If it is lower than our build API, fail with a clear message.

**armv7 CPU.**
- `-Dcpu=baseline` for `arm` is Zig's `arm.cpu.baseline` = `{ .v7a }` only, with no NEON or VFP features (`lib/std/Target/arm.zig:1947`).
- Android armeabi-v7a devices all have NEON. Consider `-Dcpu=baseline+neon+vfp3d16` (unverified; needs a test build).

**16 KB pages (Android 15+).** Upstream already handles it: `src/build/GhosttyLibVt.zig:309-311`:
```zig
if (lib.rootModuleTarget().abi.isAndroid()) {
    // Support 16kb page sizes, required for Android 15+.
    lib.link_z_max_page_size = 16384; // 16kb
```
- Not observable here (no NDK). For reference, the non-Android ELF builds show `aarch64-linux-gnu` LOAD align `0x10000` and `x86_64-linux-gnu` `0x1000`.
- **CI must assert** that every `readelf -lW` LOAD `Align` is ≥ `0x4000` for all three Android ABIs, including x86_64. The Play requirement covers all 64-bit ABIs.

**SONAME/filename on Android.** The ELF SONAME will be `libghostty-vt.so.1` (upstream `SharedVersion`: "SONAME only includes the major version").
- Flutter copies our bundled file into `jniLibs/<abi>/` under the asset's file name. We ship it as `libghostty-vt.so` (`bundledLibraryName`). APK packaging only requires `lib*.so`.
- A SONAME differing from the file name is not a load error for `dlopen` by path/name. Nothing depends on us via `DT_NEEDED`.
- Optional: pass `-Wl,-soname` to make them equal; upstream has no option for that. Not required; verify with a smoke test on an emulator.

## 2. Apple

**The xcframework is static.**
- The zip is *not* in `.native-cache`; I did not download it.
- `build.zig:223-238` plus `GhosttyLibVt.xcframework()` builds the slices from `initStaticAppleUniversal()`, whose libraries come from `initStatic(...)`: "Build static libraries for all available Apple platforms. Always builds a macOS universal (arm64 + x86_64) fat binary."
- Slices: `macos_universal` (lipo'd `libghostty-vt.a`), `ios` (aarch64, iOS 13.0) and `ios_simulator` (aarch64, `cpu_model = apple_a17`).
- So ADR 0003's "repackage the xcframework slices" **does not work**: hooks need dylibs. Build the dylibs ourselves (supersede that ADR line).

**macOS dylibs cross-build from Linux.** Both built.
- Parsed with a small Mach-O reader (`$S/tools/macho.py`), because `otool`/`llvm-objdump` are absent:
```
aarch64: LC_ID_DYLIB @rpath/libghostty-vt.1.dylib current 1.0.0 compat 1.0.0
         LC_BUILD_VERSION macos minos 13.0.0 sdk 27.0.0
         LC_LOAD_DYLIB /usr/lib/libSystem.B.dylib ; LC_CODE_SIGNATURE present (zig ad-hoc)
x86_64:  same IDs, minos 13.0.0, no LC_CODE_SIGNATURE
```
- **On a macOS host, upstream switches linkers.** `initShared` uses `initLibApple()` (Apple `ld` via `xcrun --sdk <macosx|iphoneos|iphonesimulator> clang`, `pkg/apple-sdk/native_link.zig`):
  - upstream: "producing the platform load commands expected by Apple distribution, this lets the static archive's libSystem symbol override take effect. Cross-compiled macOS dylibs continue through Zig."
  - It also sets `-current_version`/`-compatibility_version`, `-exported_symbols_list` = `_ghostty_*` and `-dead_strip`.
  - **Recommendation:** build *all* Apple dylibs on a macOS runner, for consistency with what upstream tests, and pin the Xcode version (`xcode-select`). The Linux cross-build is a fallback only.

**iOS needs the Xcode SDK** (`XcodeiOSSDKNotFound`, above). Build it on macOS: `-Dtarget=aarch64-ios` and `-Dtarget=aarch64-ios-simulator`.
- `Config.zig:940`: iOS min = 13.0; macOS min = 13.0 (`osVersionMin`). Flutter 3.47.9 asks for iOS 15 / macOS 13 (`flutter_tools/.../ios/native_assets.dart:14 targetIOSVersion = 15`, `macos/native_assets.dart:14 targetMacOSVersion = 13`), so we are compatible.
- An **x86_64 iOS simulator** (Intel Macs) slice is possible: Flutter maps `DarwinArch.x86_64 → Architecture.x64` for iOS. Decide its scope; `x86_64-ios-simulator` is untested.

**install_name.**
- Upstream: `@rpath/libghostty-vt.1.dylib`, plus `headerpad_max_install_names = true` (needed for rewriting).
- Flutter rewrites it with `install_name_tool -id @rpath/<name>.framework/<name>` and codesigns (`flutter_tools/lib/src/isolated/native_assets/macos/native_assets_host.dart:100`, `macos/native_assets.dart:173`; iOS: `copyNativeCodeAssetsIOS`, which also lipo's the archs).
- So the shipped install_name does not matter for Flutter, but the headerpad does. Plain `dart` (macOS JIT/AOT) dlopens by absolute path.

## 3. iOS device vs simulator in the hook (`code_assets` 2.1.0, locked; 2.2.0 held back in the root `dependency_overrides`)

`~/.pub-cache/hosted/pub.dev/code_assets-2.1.0/lib/src/code_assets/`:
```dart
// config.dart
IOSCodeConfig get iOS            // throws StateError unless targetOS == OS.iOS
final class IOSCodeConfig { IOSSdk get targetSdk; int get targetVersion; }
MacOSCodeConfig get macOS        // int targetVersion
AndroidCodeConfig get android    // int targetNdkApi
// ios_sdk.dart
final class IOSSdk { static const iPhoneOS = IOSSdk._('iphoneos');
                     static const iPhoneSimulator = IOSSdk._('iphonesimulator'); String type; }
```
- Use it like this: `if (code.targetOS == OS.iOS && code.iOS.targetSdk == IOSSdk.iPhoneSimulator) …`.
- `PrebuiltTarget(os, architecture).fileName` currently gives `libghostty-vt-ios-arm64.dylib` for both device and simulator, so they **collide**. `PrebuiltTarget` needs a third discriminator. (`OS.name` is lowercase: `ios`, `macos`; checked in `code_assets-2.1.0/lib/src/code_assets/os.dart`.)
- Architecture names: `arm`, `arm64`, `ia32`, `riscv64`, `x64`, … (`architecture.dart`).

## 4. Linux glibc baseline

- **The Zig 0.17.1 default glibc for x86_64/aarch64 `-linux-gnu` is 2.31**. Source: `lib/std/Target.zig`, default_min `else => .{ .major = 2, .minor = 31 }`; 32-bit time targets use 2.34.
- Versioned imports actually used (`readelf --dyn-syms -W | grep -o 'GLIBC_[0-9.]*' | sort -uV`):

| Build | GLIBC versions referenced | Max |
|---|---|---|
| x86_64-linux-gnu (default 2.31) | 2.2.5 2.3 2.4 2.10 2.14 2.27 2.29 | **2.29** (`log@GLIBC_2.29`, `exp@GLIBC_2.29`) |
| x86_64-linux-gnu.2.28 | 2.2.5 2.3 2.4 2.10 2.14 2.27 | **2.27** (`log`/`exp` fall back to `@GLIBC_2.2.5`) |
| aarch64-linux-gnu (default) | 2.17 2.27 2.29 | 2.29 |

- The symbols are basic: malloc family, mmap/mremap/madvise, `shm_open`/`shm_unlink` (librt), `preadv`/`readv`, `realpath`, `getenv`, libm `log`/`exp`/`round`/`trunc`.
- **Pinning `.2.28` is free** and widens support to Debian 10 / RHEL 8 / Ubuntu 18.10+. Zig keeps the max at 2.27.
- **musl** builds fine (`NEEDED libc.so`). However, `code_assets` has no libc dimension: `grep -ri musl\|glibc code_assets-2.1.0 hooks-2.2.0` → nothing. So the hook cannot tell Alpine from glibc and would need a heuristic (e.g. check `/lib/ld-musl-*`).
  - Upstream lists musl as tier 1.
  - My assessment: low value until the Dart SDK on Alpine is a real use case. Users can use `source: path`/`system`.

## 5. Windows

- `x86_64-windows-gnu` and `aarch64-windows-gnu` both cross-build from Linux.
- Imports (`objdump -p bin/ghostty-vt.dll | grep 'DLL Name'`, x64): `KERNEL32.dll`, `ntdll.dll`, `api-ms-win-crt-{environment,heap,private,runtime,stdio,string}-l1-1-0.dll`. ARM64 (strings, because objdump lacks arm64 PE support) adds `api-ms-win-crt-math`. There are only system DLLs and the UCRT api-sets, which are built into Windows 10+. No libwinpthread or libgcc.
- Exports: 209 `ghostty_*` on Windows; the Linux .so has 209 `ghostty_*@@GHOSTTY_VT_1.0`.
- Ship only the `.dll`. The `.pdb` (8.4 MB) could be a separate release asset; not needed by the hook.
- `windows-11-arm` exists as a hosted runner for a smoke test (§7).

## 6. Reproducibility

Two default builds of `x86_64-linux-gnu`, the same day and the same machine, both through `build.sh`:
```
run1 .so abf2e7ea0fac0e252eb435b9b7789abb4f497adf23c9bd477260cac95bbe16df
run2 .so 8763d0b5810ecf3c49f8a1d9f4471675541f09a633464acac6b386a529c7d9b9   <- DIFFER
objcopy --strip-debug: both fc7b154a92a7cb6334abd48646e943164efc70528cbf285e140d6cb43cb83c67   <- IDENTICAL
objcopy --strip-all:   both 6db6da65bc7c5d7744c41f559cce020cc944213f60b480d05acfdd4f6978dffc
diff <(strings run1.so) <(strings run2.so):  /tmp/tmp.QHY6tSjRbi vs /tmp/tmp.iVIu6mvhgs ;
    o/fc94e1a0.../options.zig vs o/5603a565.../options.zig  (DWARF paths)
```
- **The code is bit-identical. Only the DWARF debug info differs**, because `build.sh` uses a random `mktemp -d` Zig cache and DWARF embeds cache paths.
- Absolute source paths (`/home/<user>/...`) are embedded as well, so builds would also differ across machines and runners.
- `-Dstrip=true` build: 2,353,176 bytes, `strings | grep -cE '/tmp/|/home/'` = **0**, 0 debug sections. Second stripped build, for comparison: see the addendum at the end.
- **Recommendation:** release with `-Dstrip=true`. It is 5× smaller downloads, has no path leakage, and is expected to be reproducible across runs and machines. If debug info is wanted, use a fixed cache path (e.g. `/tmp/ghostty-zig-cache`) and a fixed checkout path, and/or ship separate debug files.
- Mach-O and PE reproducibility not tested here. The Apple `ld` path also embeds a UUID and the Xcode version. Check them in CI.

## 7. CI runners and actions (verified 2026-11-09)

**Hosted runner labels for public repos**: https://docs.github.com/en/actions/reference/runners/github-hosted-runners

- Linux x64: `ubuntu-24.04`, `ubuntu-22.04`, `ubuntu-26.04`, `ubuntu-latest` (= 24.04), `ubuntu-slim`.
- Linux arm64: `ubuntu-24.04-arm`, `ubuntu-22.04-arm`, `ubuntu-26.04-arm`.
- Windows x64: `windows-2025`, `windows-2025-vs2026`, `windows-2022`, `windows-latest` (= 2025).
- Windows arm64: `windows-11-arm`, `windows-11-vs2026-arm`.
- macOS Intel: `macos-15-intel`, `macos-26-intel`.
  - `macos-13` was retired on 2025-12-04 (https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/).
- macOS arm64: `macos-15`, `macos-26`, `macos-latest` (= macos-26), `xcode-27`.
  - macOS 14 is unsupported since 2026-11-02, per a secondary source (runner-images release note via newreleases.io).

**Actions.** "Latest release ≥3 days old", from `gh api repos/<o>/<r>/releases`. Tags are dereferenced with `gh api repos/<o>/<r>/git/ref/tags/<t>`, plus `git/tags/<sha>` when annotated:

| Action | Tag (published) | Commit SHA |
|---|---|---|
| actions/checkout (already in ci.yml) | v7.0.1 (2026-07-20) | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| actions/cache (already in ci.yml) | v6.1.0 | `55cc8345863c7cc4c66a329aec7e433d2d1c52a9` |
| jdx/mise-action (already in ci.yml) | v5.2.6 | `f5be966e4a917d54244728e6a5fdcd1d93a35e6c` |
| actions/attest | v4.2.2 (2026-08-04) | `1e69f48acb82d1966a394da916b4c1698aa569d6` |
| actions/attest-build-provenance | v4.2.2 (2026-08-06) | `4d101475d8b20a2381f78447822ac1eab6504dd8` |
| actions/attest-sbom | v4.1.0 (2026-03-18) | `c604332985a26aa8cf1bdc465b92731239ec6b9e` |
| actions/upload-artifact | v7.0.2 (2026-10-07) | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| actions/download-artifact | v8.0.2 (2026-10-07) | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
| step-security/harden-runner | v2.22.3 (2026-10-27); v2.22.4 is 2026-11-06, **too new** | `46b06cea07f9e64621fdf066ba77ac6915163d43` |
| ossf/scorecard-action | v2.5.0 (2026-10-12), annotated | `fa7117db83c52d787ae5a89f350999701505d78e` |
| github/codeql-action (SARIF upload for Scorecard) | v4.39.3 (2026-11-04, 5 days old), annotated | `33d7b85da1a04171e211befe2c739303b9a4c066` (v4.39.2 = `1fc58d04a4d4374f921bdac573c3811c240f9c26`) |
| nttld/setup-ndk (not recommended) | v1.6.0 (2026-02-11), annotated | `ed92fe6cadad69be94a966a7ee3271275e62f779` |
| slsa-framework/slsa-github-generator (not recommended, see §9) | v2.1.0 (2025-02-24) | `f7dd8c54c2067bafc12ca7a55595d5ee9b75204a` |

- **`actions/attest-build-provenance` v4 "is simply a wrapper on top of `actions/attest`"**; "new implementations should use `actions/attest`" (its README, 2026-11-09). **Use `actions/attest`.** With no `sbom-path`/predicate inputs it creates SLSA provenance. It also takes `subject-checksums: SHA256SUMS`, which suits us: one attestation covers every binary.
- Permissions per the `actions/attest` README: `id-token: write`, `attestations: write`, `artifact-metadata: write`.
  - The last one is "necessary to create the artifact storage record". That record only applies with `push-to-registry`, but the README lists it as required, so include it.
  - Add `contents: write` for `gh release create/upload`.
- Attestations work in public repos on any plan. The repo is `AlonsoMCarlos/ghostty_dart`, `visibility: PUBLIC` (`gh repo view`).
- For the release itself, use `gh release create native-v1.0.0 --draft --verify-tag …` then `gh release upload` then `gh release edit --draft=false`. The `gh` CLI is preinstalled on runners. No third-party action is needed.

**User verification** (gh 2.103.3 `gh attestation verify --help`):
```sh
gh attestation verify libghostty-vt-linux-x64.so --repo AlonsoMCarlos/ghostty_dart \
  --signer-workflow AlonsoMCarlos/ghostty_dart/.github/workflows/native-release.yml \
  --source-ref refs/tags/native-v1.0.0 --deny-self-hosted-runners
gh release verify native-v1.0.0 -R AlonsoMCarlos/ghostty_dart           # immutable release attestation
gh release verify-asset native-v1.0.0 ./libghostty-vt-linux-x64.so -R AlonsoMCarlos/ghostty_dart
```
Sources: https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/verifying-the-integrity-of-a-release (2026-11-09).

## 8. `hook/build.dart` issues for real-world prebuilt downloads (list only; nothing fixed)

1. **No timeouts.** `HttpClient()` has `connectionTimeout = null` (dart-sdk 3.13.7 `lib/_http/http.dart:1301`), and there is no read or overall deadline. A stalled connection hangs the build.
   - hooks_runner 1.5.0 only bounds the *lock wait*, at `singleHookTimeout ?? Duration(minutes: 5)` (`build_runner.dart:84,454`).
2. **The `.part` race is NOT a real problem under hooks_runner.** `_runHookForPackageCached` wraps the hook in `runUnderDirectoriesLock([outputDirectoryShared.parent, outputDirectory.parent])` (`hooks_runner-1.5.0/lib/src/build_runner/build_runner.dart:448`). The hooks 2.2.0 docs say: "The invoker of the hook will ensure concurrent invocations wait on each other." File names also differ per target.
   - A stale `.part` from a crash is harmless: `openWrite()` truncates. It is left on disk after a non-200 response or an exception, though.
3. **Proxy.** It works. `HttpClient` defaults to `findProxyFromEnvironment` (`http_impl.dart:2795`), and hooks_runner forwards `http_proxy`/`https_proxy`/`no_proxy` (both cases) into the hook env (`build_runner.dart:583-590`).
   - *Not* forwarded: `SSL_CERT_FILE`/custom CA variables. Corporate TLS-intercepting proxies will fail with a TLS error. The documented escape hatch is `url_pattern`/`source: path`.
4. **Redirects.** They are followed. `followRedirects = true` and `maxRedirects = 5` by default (`http_impl.dart:1491,1493`), and `isRedirect` covers 301/302/303/307/308 for GET (`http_impl.dart:647`).
   - Verified: `curl -sI https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/...` → `HTTP/2 302`, `location: https://release-assets.githubusercontent.com/...`.
   - The https-only check applies to the initial URL only. A redirect to `http:` would be followed, but the sha256 still protects integrity.
5. No retry and no size cap: a malicious mirror can stream unbounded bytes to disk before the hash check fails.
6. iOS device/simulator file name collision (§3). Android needs an API-level check (§1).
7. Error UX: non-200 throws `HttpException('HTTP 404')` without the "use `source: path`/`url_pattern`" hint that the missing-hash branch gives.
8. Download size: default upstream builds keep DWARF (12 MB Linux .so). Releasing with `-Dstrip=true` (2.35 MB) helps every user (§6).

## 9. CI/CD best practice for releasing compiled binaries (state as of 2026-11-09)

### Job and permission split (recommend)
- Workflow-level `permissions: {}`. **Build jobs** get `contents: read` only, no secrets, `persist-credentials: false`. They upload binaries plus a per-target sha256 with `actions/upload-artifact`.
- One **`release` job** (`needs:` all builds and smoke tests) with `contents: write`, `id-token: write`, `attestations: write` and `artifact-metadata: write`. It downloads the artifacts, writes `SHA256SUMS`, attests, creates the draft release, uploads and publishes.
- **A protected `environment: native-release` with required reviewers (the maintainer)** on the release job. It is cheap and makes a tag push alone insufficient to publish. Recommended.
  - Currently there are no environments (`gh api repos/AlonsoMCarlos/ghostty_dart/environments` → empty).
  - Required reviewers are available for public repos.
- The hash pinning into `prebuilt.dart` stays a **human PR** generated from `SHA256SUMS`: a script prints the Dart map. It is never a bot commit with write tokens.

### Immutable releases (recommend: enable)
- GA since 2025-10-28 (https://github.blog/changelog/2025-10-28-immutable-releases-are-now-generally-available/).
- Once published, "the assets and associated Git tag cannot be changed"; a deleted immutable release's tag name cannot be reused. Title and notes stay editable.
- GitHub auto-generates a **release attestation**, verifiable with `gh release verify` / `gh release verify-asset`.
- Source: https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/immutable-releases (2026-11-09).
- **Draft-then-publish is the documented flow:** "create the release as a draft, attach all assets, and then publish … This ensures that all assets are in place before the release becomes immutable."
- It applies to future releases only.
- Enable it under repo Settings → General → Releases → "Enable release immutability", or via REST `PUT /repos/{owner}/{repo}/immutable-releases` (admin). Current state: `gh api repos/AlonsoMCarlos/ghostty_dart/immutable-releases` → `{"enabled":false,"enforced_by_owner":false}`.
- Consequence: a bad `native-v1.0.0` can never be re-uploaded. Fixes go out as `native-v1.0.0-r2` (or a build suffix), and `defaultUrlPattern` must carry that release tag independently of the upstream version. **Design the tag scheme for this now.**

### SLSA provenance
- Use `actions/attest` (§7), with `subject-checksums: SHA256SUMS` or `subject-path`.
- GitHub: artifact attestations alone = **SLSA v1.0 Build L2**. "Using reusable workflows can meet Build Level 3" because they isolate the build from the caller (https://docs.github.com/en/actions/concepts/security/artifact-attestations, https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/increase-security-rating, 2026-11-09).
- **Recommend L3:** put build + attest in a reusable workflow in the same repo (`.github/workflows/native-build.yml`, `on: workflow_call`), called from `native-release.yml`. Users then verify with `--signer-workflow …/native-build.yml`.
  - Caveat: the attest step must run inside the reusable workflow, and both workflows need `id-token: write` and `attestations: write`.
  - Attest in each build job, which then needs those two permissions (still no `contents: write`), or in a reusable release job.
- `slsa-framework/slsa-github-generator` (last release v2.1.0, 2025-02-24) is overkill and stale compared with native attestations.
- **SBOM** (`actions/attest-sbom` or `actions/attest` with `sbom-path`): low value. The library has no runtime dependencies beyond libc. Its statically linked third-party code is listed by upstream in `deps/libghostty-vt-third-party.json` (with `"use": "linked"`).
  - Optional, cheap: convert that JSON to SPDX and attest it. Mark it *nice-to-have*, not v1.

### Checksums and signing
- Publish `SHA256SUMS` as a release asset; it is also the attestation subject.
- The real trust anchor is the sha256 pinned in the published Dart package. Sigstore attestations plus the immutable-release attestation already cover "who built this".
- **Extra cosign/minisign signing is overkill.** minisign would add a long-lived private key, i.e. a secret, which contradicts the no-secrets design.

### Reproducibility check
- With `-Dstrip=true` the Linux builds should be bit-identical (§6).
- Recommended: a second, independent build job for the **Linux/Android/Windows** targets on a different runner (e.g. `ubuntu-24.04-arm` cross-building the same zig targets). The release job compares the sha256 of both and fails on mismatch before publishing. Cost: about 2× the build minutes on free public runners.
- For Apple, compare two macOS builds only if the Apple `ld` output proves deterministic; otherwise log the difference and do not block. The UUID is derived from content, but the Xcode version matters.

### Smoke tests before publishing (recommend)
- **Real OS, run `ghostty_version()` plus the Dart suite with `source: path`:**
  - `ubuntu-24.04` (x64), `ubuntu-24.04-arm`, `macos-15-intel` (x64), `macos-26` (arm64), `windows-2025` (x64), `windows-11-arm` (arm64; best-effort, `continue-on-error`).
  - `mise run test` already works with `source: path` on 3 OSes (ci.yml). Point `path` at the downloaded artifact instead of a local build.
  - glibc floor: optionally run the x64 .so in a `debian:10` / `rockylinux:8` container with a tiny C or Python `ctypes` loader, since Dart is not needed to load it.
- **Format checks for targets we cannot run** (Android ×3, iOS ×2), all with binutils `readelf` on Linux:
  - ELF class/machine;
  - `SONAME`;
  - `NEEDED` ⊆ {libc, libm, libdl, liblog?};
  - LOAD `Align ≥ 0x4000`;
  - all 209 `ghostty_*` exported;
  - undefined symbols resolvable at API 24 (link-check against NDK `sysroot/usr/lib/<triple>/24/libc.so` stubs).
- For Mach-O, use `xcrun vtool -show-build` / `otool -l` on the macOS runner: `LC_BUILD_VERSION` platform `IOS` vs `IOSSIMULATOR` and minos, plus the install name.
- Android emulator tests (`reactivecircus/android-emulator-runner`) are possible on Linux runners with KVM. They are **overkill for v1**: the format checks plus a later integration test in the demo app are enough.

### Hardening
- `concurrency: { group: native-release-${{ github.ref }}, cancel-in-progress: false }` (never cancel a release half-way). Set `timeout-minutes` on every job: builds 30, release 15.
- `persist-credentials: false` on every checkout (already the ci.yml convention).
- **Pin runner images by label version** (`ubuntu-24.04`, `macos-26`, `windows-2025`), never `-latest`. Exact image builds (`20261101.360.1`) cannot be pinned on hosted runners. Record `ImageVersion` from the runner in the release notes.
- `step-security/harden-runner` (free Community tier for public repos on hosted runners; full egress blocking on Linux only, audit-only on Windows/macOS):
  - It is optional but a reasonable fit: the builds are offline except for the NDK, mise and upstream download, so an `egress-policy: block` allowlist is short.
  - It is third-party code running first in every job, which adds to the TCB. **Mark it optional.** If adopted, use v2.22.3 (`46b06cea…`) and start in `audit`.
- Artifact retention: `retention-days: 7` on intermediate artifacts. The release assets are the durable copy.
- OpenSSF Scorecard: worth adding as a separate weekly workflow (`ossf/scorecard-action` v2.5.0, `publish_results: true`, needs `id-token: write` + `security-events: write` for the SARIF upload via `github/codeql-action/upload-sarif`).
  - It is cheap, gives a README badge, and checks exactly the practices we claim. Not part of this task's critical path.

### Tags and triggers
- Trigger: `on: push: tags: ['native-v*']` plus `workflow_dispatch` (a dry run without the release job, or with `--draft` only).
- Add `--verify-tag` on `gh release create` so the tag must already exist.
- **Tag ruleset** for `refs/tags/native-v*`: restrict creation, update and deletion to the maintainer (bypass list) and block force-push/update.
  - Currently none exist (`gh api repos/AlonsoMCarlos/ghostty_dart/rulesets` → empty).
  - With immutable releases on, the tag is also locked once the release is published.
- Also protect `main` with a ruleset (Scorecard reads rulesets with the default token).

### Concrete set recommended for this project
**Do:**
- reusable build workflow (SLSA L3) + release job split;
- `actions/attest` with `SHA256SUMS`;
- immutable releases;
- `native-release` environment with reviewer;
- tag ruleset `native-v*`;
- `-Dstrip=true`;
- double build + hash compare (non-Apple);
- real-OS smoke tests on 6 runners;
- readelf/vtool checks for Android/iOS;
- pinned runner labels;
- timeouts and concurrency;
- artifact retention 7 days;
- `gh` CLI for releases;
- NDK r28c pinned by sha256 (or preinstalled 27.3 by path).

**Optional:** Scorecard workflow; harden-runner (audit); SPDX SBOM from upstream's third-party JSON.

**Overkill:** cosign/minisign re-signing; slsa-github-generator; Android emulator tests in the release pipeline; musl prebuilts (for now).

## Addendum (2026-11-09): second stripped build

Second `tool/native/build.sh x86_64-linux-gnu -Dstrip=true` (new random Zig cache):
```
strip.so  7c4f793ac4735c9ab196b25f2894ac0879d67324c1d67605017ee314c2645444
strip2.so 7c4f793ac4735c9ab196b25f2894ac0879d67324c1d67605017ee314c2645444   <- IDENTICAL
```
**Stripped Linux builds are bit-reproducible across runs.** Cross-machine is expected (no paths embedded) but not tested here.
`.native-cache/out/x86_64-linux-gnu` was rebuilt afterwards with default flags; `.native-cache/host/` was never touched.
