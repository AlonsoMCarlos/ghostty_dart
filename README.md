**English** | [Español](README.es.md)

# ghostty_dart

Dart and Flutter packages built on
[libghostty-vt](https://lib.ghostty.org/vt/) 1.x, the terminal emulation
engine of [Ghostty](https://ghostty.org), with its stable C ABI. The goal is
a fast, trustworthy terminal stack for Dart and Flutter, on every platform
we can support.

> [!NOTE]
> **Unofficial.** This is an independent project. It is not affiliated
> with, endorsed by or sponsored by the Ghostty project or Hack Club.
> "Ghostty" is a trademark of its respective owners and is used here only
> to describe what these packages bind to.

## Packages

| Package | What it is | Status |
|---|---|---|
| [`ghostty_dart`](packages/ghostty_dart) | Pure Dart bindings: the whole libghostty-vt 1.0 C API, with prebuilt, pinned and attested native binaries | [![pub package](https://img.shields.io/pub/v/ghostty_dart.svg)](https://pub.dev/packages/ghostty_dart) |
| [`ghostty_dart_flutter`](packages/ghostty_dart_flutter) | A Flutter terminal widget: rendering, keyboard, mouse, IME, selection and scrolling | [![pub package](https://img.shields.io/pub/v/ghostty_dart_flutter.svg)](https://pub.dev/packages/ghostty_dart_flutter) |
| [`ghostty_dart_xterm`](packages/ghostty_dart_xterm) | An adapter with the public API of [`xterm`](https://pub.dev/packages/xterm) 4.0.0, with a generated [compatibility list](packages/ghostty_dart_xterm/COMPATIBILITY.md) and a [migration guide](packages/ghostty_dart_xterm/MIGRATING_FROM_XTERM.md) | [![pub package](https://img.shields.io/pub/v/ghostty_dart_xterm.svg)](https://pub.dev/packages/ghostty_dart_xterm) |

Web support (a wasm backend) is planned too. Until it exists, the packages
run on native platforms only; see the
[platform table](packages/ghostty_dart/README.md#platforms).

## Repository

- [`packages/`](packages): the packages above.
- [`apps/demo/`](apps/demo): a Flutter app that runs your shell in
  `ghostty_dart_flutter`'s terminal view (Linux, macOS, Windows).
- [`benchmarks/`](benchmarks): reproducible benchmarks against xterm 4.0.0
  and xterm2: parser throughput, and frame times of the widgets.
- [`native/`](native) and [`tool/native/`](tool/native): the pinned
  upstream version and the scripts that build the native binaries in CI.
- [`docs/internal/`](docs/internal): architecture decision records and
  research notes.

## Contributing and security

- [Contributing](CONTRIBUTING.md): setup, commit rules and the supply-chain
  rules. [`AGENTS.md`](AGENTS.md) has the full project guide.
- [Code of conduct](CODE_OF_CONDUCT.md).
- [Security policy](SECURITY.md): report vulnerabilities privately, never
  in a public issue.

## License

MIT, see [LICENSE](LICENSE). libghostty-vt is also MIT licensed (Copyright
(c) 2024 Mitchell Hashimoto, Ghostty contributors).
