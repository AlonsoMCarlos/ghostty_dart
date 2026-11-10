/// Pure mappings between Flutter pointer state and libghostty-vt values,
/// used by the pointer layer (ADR 0011). Never exported.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

/// The keyboard modifiers held now, from [HardwareKeyboard] (pointer
/// events carry none).
KeyModifiers currentKeyModifiers([HardwareKeyboard? keyboard]) {
  final keys = keyboard ?? HardwareKeyboard.instance;
  return KeyModifiers(
    shift: keys.isShiftPressed,
    ctrl: keys.isControlPressed,
    alt: keys.isAltPressed,
    superKey: keys.isMetaPressed,
  );
}

/// Whether [modifiers] make a drag select a block (rectangle) instead of
/// running text.
///
/// Ghostty's convention (`isRectangleSelectState` in
/// `src/surface_mouse.zig` at tag `vt-1.0.0`): Option (Alt) on Apple platforms,
/// Ctrl+Alt or Super+Alt elsewhere, where Alt+drag usually moves the
/// window.
bool isRectangleSelect(KeyModifiers modifiers, TargetPlatform platform) {
  final apple =
      platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  if (!modifiers.hasAlt) return false;
  return apple || modifiers.hasCtrl || modifiers.hasSuper;
}

/// The mouse button for one Flutter button bit ([kPrimaryButton] and so
/// on), or `null` for a bit that has no terminal button.
MouseButton? mouseButtonOf(int buttonBit) => switch (buttonBit) {
  kPrimaryButton => MouseButton.left,
  kSecondaryButton => MouseButton.right,
  kMiddleMouseButton => MouseButton.middle,
  kBackMouseButton => MouseButton.eight,
  kForwardMouseButton => MouseButton.nine,
  _ => null,
};

/// The button bits of [buttons] that have a terminal button, lowest
/// first.
Iterable<int> buttonBits(int buttons) sync* {
  for (var bit = 1; bit <= kForwardMouseButton; bit <<= 1) {
    if (buttons & bit != 0 && mouseButtonOf(bit) != null) yield bit;
  }
}

/// The terminal button of the lowest held button in [buttons], or `null`
/// when none is held (the button a motion report carries).
MouseButton? heldButtonOf(int buttons) {
  for (final bit in buttonBits(buttons)) {
    return mouseButtonOf(bit);
  }
  return null;
}

/// The Flutter cursor for a pointer shape a program asked for with OSC 22
/// (CSS cursor names). [text] is used for [MouseShape.text].
MouseCursor mouseCursorForShape(
  MouseShape shape, {
  MouseCursor text = SystemMouseCursors.text,
}) => switch (shape) {
  MouseShape.text => text,
  MouseShape.defaultShape || MouseShape.unknown => SystemMouseCursors.basic,
  MouseShape.contextMenu => SystemMouseCursors.contextMenu,
  MouseShape.help => SystemMouseCursors.help,
  MouseShape.pointer => SystemMouseCursors.click,
  MouseShape.progress => SystemMouseCursors.progress,
  MouseShape.wait => SystemMouseCursors.wait,
  MouseShape.cell => SystemMouseCursors.cell,
  MouseShape.crosshair => SystemMouseCursors.precise,
  MouseShape.verticalText => SystemMouseCursors.verticalText,
  MouseShape.alias => SystemMouseCursors.alias,
  MouseShape.copy => SystemMouseCursors.copy,
  MouseShape.move => SystemMouseCursors.move,
  MouseShape.noDrop => SystemMouseCursors.noDrop,
  MouseShape.notAllowed => SystemMouseCursors.forbidden,
  MouseShape.grab => SystemMouseCursors.grab,
  MouseShape.grabbing => SystemMouseCursors.grabbing,
  MouseShape.allScroll => SystemMouseCursors.allScroll,
  MouseShape.colResize => SystemMouseCursors.resizeColumn,
  MouseShape.rowResize => SystemMouseCursors.resizeRow,
  MouseShape.nResize => SystemMouseCursors.resizeUp,
  MouseShape.eResize => SystemMouseCursors.resizeRight,
  MouseShape.sResize => SystemMouseCursors.resizeDown,
  MouseShape.wResize => SystemMouseCursors.resizeLeft,
  MouseShape.neResize => SystemMouseCursors.resizeUpRight,
  MouseShape.nwResize => SystemMouseCursors.resizeUpLeft,
  MouseShape.seResize => SystemMouseCursors.resizeDownRight,
  MouseShape.swResize => SystemMouseCursors.resizeDownLeft,
  MouseShape.ewResize => SystemMouseCursors.resizeLeftRight,
  MouseShape.nsResize => SystemMouseCursors.resizeUpDown,
  MouseShape.neswResize => SystemMouseCursors.resizeUpRightDownLeft,
  MouseShape.nwseResize => SystemMouseCursors.resizeUpLeftDownRight,
  MouseShape.zoomIn => SystemMouseCursors.zoomIn,
  MouseShape.zoomOut => SystemMouseCursors.zoomOut,
};

/// The pointer cursor over the terminal.
///
/// Follows Ghostty (`keyToMouseShape` in `src/surface_mouse.zig` at
/// tag `vt-1.0.0`): a drag that would make a block selection shows a crosshair,
/// Shift (which selects instead of reporting) shows the I-beam, and
/// otherwise the program's shape wins. One difference: while the program
/// tracks the mouse and keeps the default text shape, the arrow is shown,
/// so the user sees that clicks go to the program. [text] replaces the
/// I-beam (the view's `mouseCursor`).
MouseCursor terminalMouseCursor({
  required bool tracking,
  required MouseShape shape,
  required KeyModifiers modifiers,
  required TargetPlatform platform,
  MouseCursor text = SystemMouseCursors.text,
}) {
  final selects = !tracking || modifiers.hasShift;
  if (selects && isRectangleSelect(modifiers, platform)) {
    return SystemMouseCursors.precise;
  }
  if (modifiers.hasShift) return text;
  if (tracking && shape == MouseShape.text) return SystemMouseCursors.basic;
  return mouseCursorForShape(shape, text: text);
}
