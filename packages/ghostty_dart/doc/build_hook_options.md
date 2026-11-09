`package:ghostty_dart` gets its native library, libghostty-vt 1.x, from a
[build hook](https://dart.dev/tools/hooks) (`hook/build.dart`). By default it
downloads a prebuilt binary for the target and verifies it, so no toolchain
is needed. These options change where the library comes from.

## Where options go

Options are `user_defines` in the `pubspec.yaml` at the root of your
application or workspace, not in a dependency's pubspec:

```yaml
hooks:
  user_defines:
    ghostty_dart:
      source: prebuilt   # the default; also: path, system
```

| Option | Values | Default | Used by |
|---|---|---|---|
| `source` | `prebuilt`, `path`, `system` | `prebuilt` | always |
| `url_pattern` | an `https` URL pattern | the GitHub release | `prebuilt` |
| `path` | a library file or a directory | none (required) | `path` |

Any other `source` value fails the build with the list of valid ones.

## `source: prebuilt` (default)

The hook downloads the binary for the build target from the GitHub release
[`native-v1.0.0-r1`](https://github.com/AlonsoMCarlos/ghostty_dart/releases/tag/native-v1.0.0-r1)
of this repository and checks it against the sha256 pinned in the package
source (`lib/src/native/prebuilt.dart`). A different hash fails the build:
the hook fails closed and never runs downloaded code.

The release has 12 binaries:

| OS | Architectures | Minimum version |
|---|---|---|
| Linux | x64, arm64 | glibc 2.28 |
| macOS | arm64, x64 | macOS 13 |
| Windows | x64, arm64 (arm64 is best effort) | — |
| Android | arm64, arm, x64 | API 24 |
| iOS | arm64 (device); arm64 and x64 (simulator) | iOS 14 |

A build that targets a lower Android API level, iOS or macOS version fails
with a message that states the floor. On Android, raise `minSdk` in
`android/app/build.gradle(.kts)` to 24. For iOS and macOS the version comes
from what your build tool passes to build hooks. Otherwise provide your own
library with `source: path` or `source: system`.

Downloads are cached in the hook's shared output directory, keyed by the
pinned hash, so a new package version never reuses an old file.

### `url_pattern`: mirrors and internal stores

`url_pattern` replaces the GitHub download URL, for example to use an
artefact store inside your network:

```yaml
hooks:
  user_defines:
    ghostty_dart:
      url_pattern: https://mirror.example/ghostty/$TAG/$FILENAME
```

These placeholders are substituted:

| Placeholder | Value | Example |
|---|---|---|
| `$TAG` | the release tag | `native-v1.0.0-r1` |
| `$VERSION` | the libghostty-vt version | `1.0.0` |
| `$FILENAME` | the asset name for the target (required) | `libghostty-vt-linux-x64.so` |

The default is
`https://github.com/AlonsoMCarlos/ghostty_dart/releases/download/$TAG/$FILENAME`.
A pattern without `$FILENAME` is rejected, since every target would fetch
the same file. The URL must be `https`. The mirror must serve the exact
release files: the pinned sha256 is verified whatever the URL.

The asset names are:

```text
libghostty-vt-linux-x64.so             libghostty-vt-linux-arm64.so
ghostty-vt-windows-x64.dll             ghostty-vt-windows-arm64.dll
libghostty-vt-macos-arm64.dylib        libghostty-vt-macos-x64.dylib
libghostty-vt-android-arm64.so         libghostty-vt-android-arm.so
libghostty-vt-android-x64.so           libghostty-vt-ios-arm64.dylib
libghostty-vt-ios-arm64-simulator.dylib
libghostty-vt-ios-x64-simulator.dylib
```

To fill a mirror, download them together with `SHA256SUMS` from the
release page and check them (see [Verifying binaries](#verifying-binaries)).

### Network limits

Every download has:

- a 30-second connect timeout and a 60-second idle timeout (no data
  received);
- a 10-minute limit for one whole attempt, redirects included;
- a 64 MiB size cap (a binary is a few MiB);
- redirects only to `https` URLs, at most 5;
- one retry, after 2 seconds, on transient errors: connection errors,
  timeouts and HTTP 5xx. Other errors, including TLS failures, are not
  retried.

Error messages name the URL and suggest `url_pattern`, `path` and `system`.

### Proxies

The hook honours the `HTTPS_PROXY` and `NO_PROXY` environment variables
(and their lowercase forms), as `dart:io`'s `HttpClient` does.

A TLS-intercepting proxy re-signs connections with its own certificate
authority, which the hook does not trust unless the operating system's
trust store does. The download then fails with a TLS error, which is not
retried. Either point `url_pattern` at a mirror that the build can reach
with the system trust store, or use `source: path`.

## `source: path`

Uses a library you provide: one you built, or one copied into an
air-gapped build environment. `path` is required:

```yaml
hooks:
  user_defines:
    ghostty_dart:
      source: path
      path: third_party/libghostty-vt/
```

`path` is resolved relative to the pubspec that declares it, and may be:

- **the library file itself**, for example
  `path/to/libghostty-vt.so.1.0.0`;
- **a directory** that holds it under its bundled name: `libghostty-vt.so`
  (Linux, Android), `libghostty-vt.dylib` (macOS, iOS) or `ghostty-vt.dll`
  (Windows). One directory entry then works on every host OS.

The hook copies the library into the build under its bundled name and
re-runs when the file changes. Nothing is downloaded and no hash is
checked, so you are responsible for what the file contains. Use a
libghostty-vt 1.x build: before creating the first native object, the
bindings check the loaded version and throw `IncompatibleLibraryException`
for any other major version, or for a pre-release build of 1.0.0.

To build libghostty-vt from the upstream source yourself, see the scripts
in [`tool/native/`](https://github.com/AlonsoMCarlos/ghostty_dart/tree/main/tool/native)
(they verify the upstream tarball's minisign signature and pinned sha256,
and use Zig 0.17).

## `source: system`

Loads a libghostty-vt 1.x installed on the system, through the dynamic
loader's normal search path: `libghostty-vt.so.1` on Linux and Android,
`libghostty-vt.1.dylib` on macOS and iOS, `ghostty-vt.dll` on Windows.
Nothing is bundled with your app, so the library must be present on every
machine that runs it. This suits Linux distributions that package
libghostty-vt.

## Air-gapped builds

A build without network access needs either:

- `source: path`, pointing at libraries you copied in; or
- `url_pattern`, pointing at an `https` store inside the network that
  holds the release files unchanged.

The pinned hashes keep the second option safe: a tampered mirror fails the
build.

## Verifying binaries

The hook already verifies each download against the hash pinned in the
package source (`prebuiltSha256` in
[`lib/src/native/prebuilt.dart`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/lib/src/native/prebuilt.dart)).
To check the release files yourself, with checksums, build provenance
attestations and a reproducible rebuild, follow
[Verifying the prebuilt binaries](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/SECURITY.md#verifying-the-prebuilt-binaries)
in the security policy, which also says how to report a vulnerability.
