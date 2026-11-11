// Ported from package:xterm 4.0.0 (lib/src/core/platform.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// The platform a `Terminal` behaves as. The input handlers read it, for
/// example to leave Option+letter alone on macOS.
enum TerminalTargetPlatform {
  /// No particular platform.
  unknown,

  /// Android.
  android,

  /// iOS.
  ios,

  /// Fuchsia.
  fuchsia,

  /// Linux.
  linux,

  /// macOS.
  macos,

  /// Windows.
  windows,

  /// The web.
  web,
}
