// Ported from package:xterm 4.0.0 (lib/src/core/cursor.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'cell.dart';

/// The text style new text is written with (the SGR pen): colours as
/// [CellColor] values and [CellAttr] bits. Not the cursor's shape.
class CursorStyle {
  /// The foreground colour, a [CellColor] value.
  int foreground;

  /// The background colour, a [CellColor] value.
  int background;

  /// The [CellAttr] bits.
  int attrs;

  /// Creates a style; all zero is the default style.
  CursorStyle({this.foreground = 0, this.background = 0, this.attrs = 0});

  /// A shared default style. Mutable, as in xterm: do not change it.
  static final empty = CursorStyle();

  /// Sets bold.
  void setBold() {
    attrs |= CellAttr.bold;
  }

  /// Sets faint.
  void setFaint() {
    attrs |= CellAttr.faint;
  }

  /// Sets italic.
  void setItalic() {
    attrs |= CellAttr.italic;
  }

  /// Sets underline.
  void setUnderline() {
    attrs |= CellAttr.underline;
  }

  /// Sets blink.
  void setBlink() {
    attrs |= CellAttr.blink;
  }

  /// Sets inverse video.
  void setInverse() {
    attrs |= CellAttr.inverse;
  }

  /// Sets invisible.
  void setInvisible() {
    attrs |= CellAttr.invisible;
  }

  /// Sets strikethrough.
  void setStrikethrough() {
    attrs |= CellAttr.strikethrough;
  }

  /// Clears bold.
  void unsetBold() {
    attrs &= ~CellAttr.bold;
  }

  /// Clears faint.
  void unsetFaint() {
    attrs &= ~CellAttr.faint;
  }

  /// Clears italic.
  void unsetItalic() {
    attrs &= ~CellAttr.italic;
  }

  /// Clears underline.
  void unsetUnderline() {
    attrs &= ~CellAttr.underline;
  }

  /// Clears blink.
  void unsetBlink() {
    attrs &= ~CellAttr.blink;
  }

  /// Clears inverse video.
  void unsetInverse() {
    attrs &= ~CellAttr.inverse;
  }

  /// Clears invisible.
  void unsetInvisible() {
    attrs &= ~CellAttr.invisible;
  }

  /// Clears strikethrough.
  void unsetStrikethrough() {
    attrs &= ~CellAttr.strikethrough;
  }

  /// Whether the style is bold.
  bool get isBold => (attrs & CellAttr.bold) != 0;

  /// Whether the style is faint.
  bool get isFaint => (attrs & CellAttr.faint) != 0;

  /// Whether the style is italic (sic: xterm's name).
  bool get isItalis => (attrs & CellAttr.italic) != 0;

  /// Whether the style is underlined.
  bool get isUnderline => (attrs & CellAttr.underline) != 0;

  /// Whether the style is blinking.
  bool get isBlink => (attrs & CellAttr.blink) != 0;

  /// Whether the style is inverse video.
  bool get isInverse => (attrs & CellAttr.inverse) != 0;

  /// Whether the style is invisible.
  bool get isInvisible => (attrs & CellAttr.invisible) != 0;

  /// Sets the foreground to named colour [color] (0–15).
  void setForegroundColor16(int color) {
    foreground = color | CellColor.named;
  }

  /// Sets the foreground to palette colour [color] (0–255).
  void setForegroundColor256(int color) {
    foreground = color | CellColor.palette;
  }

  /// Sets the foreground to the RGB colour [r], [g], [b].
  void setForegroundColorRgb(int r, int g, int b) {
    foreground = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  /// Resets the foreground to the default colour.
  void resetForegroundColor() {
    foreground = 0; // | CellColor.normal;
  }

  /// Sets the background to named colour [color] (0–15).
  void setBackgroundColor16(int color) {
    background = color | CellColor.named;
  }

  /// Sets the background to palette colour [color] (0–255).
  void setBackgroundColor256(int color) {
    background = color | CellColor.palette;
  }

  /// Sets the background to the RGB colour [r], [g], [b].
  void setBackgroundColorRgb(int r, int g, int b) {
    background = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  /// Resets the background to the default colour.
  void resetBackgroundColor() {
    background = 0; // | CellColor.normal;
  }

  /// Resets colours and attributes to the default.
  void reset() {
    foreground = 0;
    background = 0;
    attrs = 0;
  }
}

/// A mutable cell position.
class CursorPosition {
  /// The column.
  int x;

  /// The row.
  int y;

  /// Creates a position at column [x], row [y].
  CursorPosition(this.x, this.y);
}
