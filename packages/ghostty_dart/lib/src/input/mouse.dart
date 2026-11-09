/// Mouse events (`mouse/event.h`, `mouse/encoder.h`): actions, buttons,
/// tracking modes, output formats, the immutable [VtMouseEvent] and the
/// [MouseEncoderSize] geometry that a `MouseEncoder` uses to turn pixels
/// into cells.
///
/// Pure Dart: no `dart:ffi`, so a future web backend can reuse it.
library;

import '../core/enum_codec.dart';
import '../core/modifiers.dart';

/// What a mouse event reports (`GhosttyMouseAction`).
enum MouseAction {
  /// A button was pressed.
  press(0),

  /// A button was released.
  release(1),

  /// The pointer moved (with or without a button held).
  motion(2),

  /// An action added by a later libghostty-vt release.
  unknown(null);

  const MouseAction(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyMouseAction` values to [MouseAction] and back.
final mouseActionCodec = RawEnumCodec<MouseAction>(
  MouseAction.values,
  raw: (v) => v._raw,
  unknown: MouseAction.unknown,
);

/// A mouse button (`GhosttyMouseButton`).
///
/// "No button" (e.g. plain motion) is a `null` [VtMouseEvent.button], not a
/// member. Buttons 4 and 5 are the vertical scroll wheel, 6 and 7 the
/// horizontal one.
enum MouseButton {
  /// A button the platform could not identify (`GHOSTTY_MOUSE_BUTTON_UNKNOWN`,
  /// value 0). Not to be confused with [unknown].
  unidentified(0),

  /// The primary (usually left) button.
  left(1),

  /// The secondary (usually right) button.
  right(2),

  /// The middle button (often the wheel click).
  middle(3),

  /// Button 4: wheel up.
  four(4),

  /// Button 5: wheel down.
  five(5),

  /// Button 6: wheel left.
  six(6),

  /// Button 7: wheel right.
  seven(7),

  /// Button 8 (often "back").
  eight(8),

  /// Button 9 (often "forward").
  nine(9),

  /// Button 10.
  ten(10),

  /// Button 11.
  eleven(11),

  /// A button added by a later libghostty-vt release.
  unknown(null);

  const MouseButton(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyMouseButton` values to [MouseButton] and back.
final mouseButtonCodec = RawEnumCodec<MouseButton>(
  MouseButton.values,
  raw: (v) => v._raw,
  unknown: MouseButton.unknown,
);

/// Which mouse events a program asked to receive
/// (`GhosttyMouseTrackingMode`; DEC modes 9, 1000, 1002 and 1003).
enum MouseTrackingMode {
  /// Mouse reporting is off (the default).
  none(0),

  /// X10 mode (DEC 9): button presses only.
  x10(1),

  /// Normal mode (DEC 1000): presses and releases.
  normal(2),

  /// Button-event mode (DEC 1002): also motion while a button is held.
  button(3),

  /// Any-event mode (DEC 1003): all motion.
  any(4),

  /// A mode added by a later libghostty-vt release.
  unknown(null);

  const MouseTrackingMode(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyMouseTrackingMode` values to [MouseTrackingMode] and
/// back.
final mouseTrackingModeCodec = RawEnumCodec<MouseTrackingMode>(
  MouseTrackingMode.values,
  raw: (v) => v._raw,
  unknown: MouseTrackingMode.unknown,
);

/// How mouse reports are encoded (`GhosttyMouseFormat`; DEC modes 1005,
/// 1006, 1015 and 1016).
enum MouseFormat {
  /// The original X10 encoding, `CSI M Cb Cx Cy` (the default).
  x10(0),

  /// UTF-8 coordinates (DEC 1005).
  utf8(1),

  /// SGR, `CSI < b ; x ; y M/m` (DEC 1006). The one most programs use.
  sgr(2),

  /// URxvt, `CSI b ; x ; y M` (DEC 1015).
  urxvt(3),

  /// SGR with pixel coordinates instead of cells (DEC 1016).
  sgrPixels(4),

  /// A format added by a later libghostty-vt release.
  unknown(null);

  const MouseFormat(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyMouseFormat` values to [MouseFormat] and back.
final mouseFormatCodec = RawEnumCodec<MouseFormat>(
  MouseFormat.values,
  raw: (v) => v._raw,
  unknown: MouseFormat.unknown,
);

/// One mouse event, as input to `MouseEncoder.encode`.
///
/// An immutable value. The position is in surface-space pixels (relative to
/// the top-left corner of the terminal view, padding included); the encoder
/// converts it to cells with its [MouseEncoderSize].
///
/// ```dart
/// const click = VtMouseEvent(
///   action: MouseAction.press,
///   button: MouseButton.left,
///   x: 42,
///   y: 17,
/// );
/// ```
///
/// Named `VtMouseEvent` because `MouseEvent` clashes with the web DOM type.
final class VtMouseEvent {
  /// Creates a mouse event at ([x], [y]) pixels.
  const VtMouseEvent({
    required this.action,
    this.button,
    this.modifiers = KeyModifiers.none,
    required this.x,
    required this.y,
  });

  /// Press, release or motion.
  final MouseAction action;

  /// The button pressed or released, or `null` for none (plain motion).
  final MouseButton? button;

  /// The keyboard modifiers held during the event.
  final KeyModifiers modifiers;

  /// The horizontal position in surface pixels. Stored as a 32-bit float
  /// natively.
  final double x;

  /// The vertical position in surface pixels. Stored as a 32-bit float
  /// natively.
  final double y;

  /// A copy with the given fields replaced. Use [clearButton] to set
  /// [button] to `null`.
  VtMouseEvent copyWith({
    MouseAction? action,
    MouseButton? button,
    bool clearButton = false,
    KeyModifiers? modifiers,
    double? x,
    double? y,
  }) => VtMouseEvent(
    action: action ?? this.action,
    button: clearButton ? null : (button ?? this.button),
    modifiers: modifiers ?? this.modifiers,
    x: x ?? this.x,
    y: y ?? this.y,
  );

  @override
  bool operator ==(Object other) =>
      other is VtMouseEvent &&
      other.action == action &&
      other.button == button &&
      other.modifiers == modifiers &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(action, button, modifiers, x, y);

  @override
  String toString() =>
      'VtMouseEvent(${action.name}, ${button?.name ?? 'no button'}, '
      '$modifiers, $x, $y)';
}

/// The rendered terminal geometry a `MouseEncoder` uses to convert pixel
/// positions into cells (`GhosttyMouseEncoderSize`). All values in pixels.
///
/// The encoder's default before you set one is a 1×1 pixel screen with 1×1
/// pixel cells and no padding.
final class MouseEncoderSize {
  /// Creates a geometry. [cellWidth] and [cellHeight] must be at least 1;
  /// every value must be at most 2^24 (16777216) pixels, and the screen at
  /// most 65535 cells wide and high. Validated when passed to the encoder
  /// ([RangeError]).
  const MouseEncoderSize({
    required this.screenWidth,
    required this.screenHeight,
    required this.cellWidth,
    required this.cellHeight,
    this.paddingTop = 0,
    this.paddingBottom = 0,
    this.paddingLeft = 0,
    this.paddingRight = 0,
  });

  /// The full surface width, padding included.
  final int screenWidth;

  /// The full surface height, padding included.
  final int screenHeight;

  /// The width of one cell. Must be non-zero.
  final int cellWidth;

  /// The height of one cell. Must be non-zero.
  final int cellHeight;

  /// Padding above the grid.
  final int paddingTop;

  /// Padding below the grid.
  final int paddingBottom;

  /// Padding left of the grid.
  final int paddingLeft;

  /// Padding right of the grid.
  final int paddingRight;

  @override
  bool operator ==(Object other) =>
      other is MouseEncoderSize &&
      other.screenWidth == screenWidth &&
      other.screenHeight == screenHeight &&
      other.cellWidth == cellWidth &&
      other.cellHeight == cellHeight &&
      other.paddingTop == paddingTop &&
      other.paddingBottom == paddingBottom &&
      other.paddingLeft == paddingLeft &&
      other.paddingRight == paddingRight;

  @override
  int get hashCode => Object.hash(
    screenWidth,
    screenHeight,
    cellWidth,
    cellHeight,
    paddingTop,
    paddingBottom,
    paddingLeft,
    paddingRight,
  );

  @override
  String toString() =>
      'MouseEncoderSize(${screenWidth}x$screenHeight, '
      'cell ${cellWidth}x$cellHeight, padding '
      '$paddingTop/$paddingRight/$paddingBottom/$paddingLeft)';
}
