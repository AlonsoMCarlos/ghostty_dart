// Ported from package:xterm 4.0.0 (lib/src/ui/terminal_text_style.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'package:flutter/widgets.dart';

const _kDefaultFontSize = 13.0;

const _kDefaultHeight = 1.2;

const _kDefaultFontFamily = 'monospace';

const _kDefaultFontFamilyFallback = [
  'Menlo',
  'Monaco',
  'Consolas',
  'Liberation Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
];

/// The font of a `TerminalView`: size, line height, family and fallbacks.
///
/// `TerminalView` passes [toTextStyle] to `ghostty_dart_flutter`'s view,
/// which measures its cells from it and snaps them to device pixels, so a
/// cell can differ slightly in size from xterm's for the same font.
class TerminalStyle {
  /// A style; the defaults are 13 px, line height 1.2, the generic
  /// `monospace` family and a list of common monospace fallbacks.
  const TerminalStyle({
    this.fontSize = _kDefaultFontSize,
    this.height = _kDefaultHeight,
    this.fontFamily = _kDefaultFontFamily,
    this.fontFamilyFallback = _kDefaultFontFamilyFallback,
  });

  /// The size, height and families of [textStyle], with the defaults for
  /// what it leaves unset.
  factory TerminalStyle.fromTextStyle(TextStyle textStyle) {
    return TerminalStyle(
      fontSize: textStyle.fontSize ?? _kDefaultFontSize,
      height: textStyle.height ?? _kDefaultHeight,
      fontFamily:
          textStyle.fontFamily ??
          textStyle.fontFamilyFallback?.first ??
          _kDefaultFontFamily,
      fontFamilyFallback:
          textStyle.fontFamilyFallback ?? _kDefaultFontFamilyFallback,
    );
  }

  /// The font size in logical pixels.
  final double fontSize;

  /// The line height, as a multiple of [fontSize].
  final double height;

  /// The font family.
  final String fontFamily;

  /// The families tried, in order, for glyphs [fontFamily] lacks.
  final List<String> fontFamilyFallback;

  /// A [TextStyle] with this font and the given colours and attributes.
  TextStyle toTextStyle({
    Color? color,
    Color? backgroundColor,
    bool bold = false,
    bool italic = false,
    bool underline = false,
  }) {
    return TextStyle(
      fontSize: fontSize,
      height: height,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      color: color,
      backgroundColor: backgroundColor,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: underline ? TextDecoration.underline : TextDecoration.none,
    );
  }

  /// A copy with the given fields replaced.
  TerminalStyle copyWith({
    double? fontSize,
    double? height,
    String? fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    return TerminalStyle(
      fontSize: fontSize ?? this.fontSize,
      height: height ?? this.height,
      fontFamily: fontFamily ?? this.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
    );
  }
}
