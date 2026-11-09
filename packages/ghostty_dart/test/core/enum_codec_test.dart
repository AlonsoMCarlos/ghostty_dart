import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/expect_support.dart';

enum _Sparse {
  a(-5),
  b(1000),
  unknown(null);

  const _Sparse(this.raw);
  final int? raw;
}

/// Checks that [codec] maps exactly [expected] (member -> raw constant) and
/// sends every other value to [unknown].

void main() {
  test('sparse codecs fall back to a map', () {
    final codec = RawEnumCodec<_Sparse>(
      _Sparse.values,
      raw: (v) => v.raw,
      unknown: _Sparse.unknown,
    );
    expect(codec.decode(-5), _Sparse.a);
    expect(codec.decode(1000), _Sparse.b);
    expect(codec.decode(0), _Sparse.unknown);
  });

  test('duplicate raw values are rejected', () {
    expect(
      () => RawEnumCodec<_Sparse>(
        _Sparse.values,
        raw: (v) => v == _Sparse.unknown ? null : 1,
        unknown: _Sparse.unknown,
      ),
      throwsArgumentError,
    );
  });

  test('VtCursorStyle matches GhosttyCursorStyle', () {
    expectCodec(
      vtCursorStyleCodec,
      VtCursorStyle.values,
      VtCursorStyle.unknown,
      {
        VtCursorStyle.bar: GhosttyCursorStyle.GHOSTTY_CURSOR_STYLE_BAR,
        VtCursorStyle.block: GhosttyCursorStyle.GHOSTTY_CURSOR_STYLE_BLOCK,
        VtCursorStyle.underline:
            GhosttyCursorStyle.GHOSTTY_CURSOR_STYLE_UNDERLINE,
        VtCursorStyle.blockHollow:
            GhosttyCursorStyle.GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW,
      },
    );
  });

  test('TerminalScreen matches GhosttyTerminalScreen', () {
    expectCodec(
      terminalScreenCodec,
      TerminalScreen.values,
      TerminalScreen.unknown,
      {
        TerminalScreen.primary:
            GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_PRIMARY,
        TerminalScreen.alternate:
            GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_ALTERNATE,
      },
    );
  });

  test('UnderlineStyle matches GhosttySgrUnderline', () {
    expectCodec(
      underlineStyleCodec,
      UnderlineStyle.values,
      UnderlineStyle.unknown,
      {
        UnderlineStyle.none: GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE,
        UnderlineStyle.single: GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_SINGLE,
        UnderlineStyle.double: GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOUBLE,
        UnderlineStyle.curly: GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_CURLY,
        UnderlineStyle.dotted: GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOTTED,
        UnderlineStyle.dashed: GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DASHED,
      },
    );
  });

  test('PointSpace matches GhosttyPointTag', () {
    expectCodec(pointSpaceCodec, PointSpace.values, PointSpace.unknown, {
      PointSpace.active: GhosttyPointTag.GHOSTTY_POINT_TAG_ACTIVE,
      PointSpace.viewport: GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT,
      PointSpace.screen: GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN,
      PointSpace.history: GhosttyPointTag.GHOSTTY_POINT_TAG_HISTORY,
    });
  });

  test('OptimizeMode matches GhosttyOptimizeMode', () {
    expectCodec(optimizeModeCodec, OptimizeMode.values, OptimizeMode.unknown, {
      OptimizeMode.debug: GhosttyOptimizeMode.GHOSTTY_OPTIMIZE_DEBUG,
      OptimizeMode.releaseSafe:
          GhosttyOptimizeMode.GHOSTTY_OPTIMIZE_RELEASE_SAFE,
      OptimizeMode.releaseSmall:
          GhosttyOptimizeMode.GHOSTTY_OPTIMIZE_RELEASE_SMALL,
      OptimizeMode.releaseFast:
          GhosttyOptimizeMode.GHOSTTY_OPTIMIZE_RELEASE_FAST,
    });
  });
}
