**English** | [Español](SECURITY.es.md)

# Security policy

## Supported versions

| Version | Supported |
|---|---|
| `ghostty_dart` 0.1.x | ✅ |
| Native binaries `native-v1.0.0-r1` (libghostty-vt 1.0.0) | ✅ |

While the package is in 0.x, only the latest minor version receives fixes.
A fix in a native binary ships as a new `native-v<version>-r<n>` release
plus a new package version that pins the new hashes.

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting:
**[open a report](https://github.com/AlonsoMCarlos/ghostty_dart/security/advisories/new)**
(the "Report a vulnerability" button on the Security tab).

Please do not report vulnerabilities in public issues, pull requests or
discussions. There is no security email address.

## Scope

In scope:

- the Dart API of the packages in this repository;
- the build hook: downloading, hash verification and the `user_defines`
  options;
- the CI and release pipeline, and the prebuilt binaries it publishes;
- how the bindings handle hostile terminal input. A terminal parses
  untrusted output, so issues around OSC 52 clipboard access, OSC 8
  hyperlinks, title reports and similar sequences are in scope when the
  bindings are involved.

Out of scope here: bugs in libghostty-vt itself, such as a parser crash
that reproduces from C. Report those to Ghostty, which also accepts private
reports: <https://github.com/ghostty-org/ghostty/security/advisories/new>.
If you are not sure where a problem lies, report it here; we will
coordinate with upstream and re-release the binaries when a fix lands.

## What to expect

This is a project with a single maintainer, so responses are best effort.
The aim is to acknowledge a report within 7 days and to keep you informed
until it is resolved, but there is no guaranteed response time. Once a fix
is released, the advisory is published with credit to you, unless you
prefer otherwise.

## Verifying the prebuilt binaries

Three independent checks protect the native library:

1. **Pinned hashes.** The build hook checks every download against the
   sha256 pinned in
   [`lib/src/native/prebuilt.dart`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/lib/src/native/prebuilt.dart)
   and fails the build on a mismatch. You can also run
   `sha256sum -c SHA256SUMS` against the files of the
   [release](https://github.com/AlonsoMCarlos/ghostty_dart/releases/tag/native-v1.0.0-r1).
   `SHA256SUMS` is not signed itself; the trust comes from the hashes in
   the published package source and from the attestations.
2. **Build provenance.** Every binary has a GitHub artefact attestation of
   the CI run that built it:

   ```sh
   gh attestation verify libghostty-vt-linux-x64.so \
     --repo AlonsoMCarlos/ghostty_dart
   ```

3. **Reproducible builds.** All binaries except the Apple ones are
   bit-reproducible: rebuild one with `mise run native:release-asset <asset>`
   and compare the hash. The build starts from the upstream tarball, whose
   minisign signature is checked against the key in
   [`native/upstream.json`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/native/upstream.json).

If you prefer not to download anything, `source: path` and `source: system`
let you provide your own library. See the
[Build hook options](https://pub.dev/documentation/ghostty_dart/latest/topics/build-hook-options-topic.html)
topic.
