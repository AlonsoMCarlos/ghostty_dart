/// Small terminal enums shared by several modules (`types.h`, `terminal.h`).
library;

import 'enum_codec.dart';

/// The shape of the cursor (`GhosttyCursorStyle`).
///
/// Programs change it with DECSCUSR (`CSI Ps SP q`).
///
/// Named `VtCursorStyle` because `CursorStyle` clashes with
/// `package:xterm`'s `CursorStyle`, which the xterm adapter mirrors.
enum VtCursorStyle {
  /// A vertical bar (DECSCUSR 5, 6).
  bar(0),

  /// A filled block (DECSCUSR 1, 2).
  block(1),

  /// An underline (DECSCUSR 3, 4).
  underline(2),

  /// A hollow block, e.g. for an unfocused terminal.
  blockHollow(3),

  /// A shape added by a later libghostty-vt release. Draw it as [block].
  unknown(null);

  const VtCursorStyle(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyCursorStyle` values to [VtCursorStyle] and back.
final vtCursorStyleCodec = RawEnumCodec<VtCursorStyle>(
  VtCursorStyle.values,
  raw: (style) => style._raw,
  unknown: VtCursorStyle.unknown,
);

/// Which screen buffer is active (`GhosttyTerminalScreen`).
enum TerminalScreen {
  /// The primary (normal) screen, which has scrollback.
  primary(0),

  /// The alternate screen used by full-screen programs; no scrollback.
  alternate(1),

  /// A screen added by a later libghostty-vt release.
  unknown(null);

  const TerminalScreen(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyTerminalScreen` values to [TerminalScreen] and back.
final terminalScreenCodec = RawEnumCodec<TerminalScreen>(
  TerminalScreen.values,
  raw: (screen) => screen._raw,
  unknown: TerminalScreen.unknown,
);
