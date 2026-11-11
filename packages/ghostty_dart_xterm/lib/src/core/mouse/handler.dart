// Ported from package:xterm 4.0.0 (lib/src/core/mouse/handler.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import '../buffer/cell_offset.dart';
import '../platform.dart';
import '../state.dart';
import 'button.dart';
import 'button_state.dart';
import 'mode.dart';
import 'reporter.dart';

/// A mouse button press or release (or a wheel step) at a cell, with the
/// terminal's state, as a [TerminalMouseHandler] receives it.
class TerminalMouseEvent {
  /// The button that is pressed or released.
  final TerminalMouseButton button;

  /// The current state of the button.
  final TerminalMouseButtonState buttonState;

  /// The position of button state change.
  final CellOffset position;

  /// The state of the terminal.
  final TerminalState state;

  /// The platform of the terminal.
  final TerminalTargetPlatform platform;

  /// Creates a mouse event; every field is required.
  TerminalMouseEvent({
    required this.button,
    required this.buttonState,
    required this.position,
    required this.state,
    required this.platform,
  });
}

/// The default mouse handler: a [ClickMouseHandler] then an
/// [UpDownMouseHandler], which together report what the program's
/// [MouseMode] asks for.
///
/// It is a `const`, so `identical(terminal.mouseHandler,
/// defaultMouseHandler)` tells whether a terminal uses it; `TerminalView`
/// then reports the mouse with libghostty's encoder instead (ADR 0013).
const defaultMouseHandler = CascadeMouseHandler([
  ClickMouseHandler(),
  UpDownMouseHandler(),
]);

/// Translates a [TerminalMouseEvent] into the text to send to the program.
abstract class TerminalMouseHandler {
  /// Allows subclasses to have `const` constructors.
  const TerminalMouseHandler();

  /// Returns the report for [event], or `null` when this handler does not
  /// report it.
  String? call(TerminalMouseEvent event);
}

/// A [TerminalMouseHandler] that tries each of its handlers in order and
/// returns the first non-null result.
class CascadeMouseHandler implements TerminalMouseHandler {
  final List<TerminalMouseHandler> _handlers;

  /// Creates a handler that tries each of the handlers in order.
  const CascadeMouseHandler(this._handlers);

  @override
  String? call(TerminalMouseEvent event) {
    for (final handler in _handlers) {
      final result = handler(event);
      if (result != null) {
        return result;
      }
    }
    return null;
  }
}

/// Reports presses of the left, middle and right buttons while the program
/// uses [MouseMode.clickOnly] (X10, DEC mode 9).
class ClickMouseHandler implements TerminalMouseHandler {
  /// Creates the handler.
  const ClickMouseHandler();

  @override
  String? call(TerminalMouseEvent event) {
    switch (event.state.mouseMode) {
      case MouseMode.clickOnly:
        // Only clicks and only the first 3 buttons are reported.
        if (event.buttonState == TerminalMouseButtonState.down &&
            (event.button.id < 3)) {
          return MouseReporter.report(
            event.button,
            event.buttonState,
            event.position,
            event.state.mouseReportMode,
          );
        }
        return null;
      case MouseMode.none:
      case MouseMode.upDownScroll:
      case MouseMode.upDownScrollDrag:
      case MouseMode.upDownScrollMove:
        return null;
    }
  }
}

/// Reports presses, releases and wheel steps (never a wheel "release")
/// while the program uses [MouseMode.upDownScroll] or one of the modes
/// that extend it.
class UpDownMouseHandler implements TerminalMouseHandler {
  /// Creates the handler.
  const UpDownMouseHandler();

  @override
  String? call(TerminalMouseEvent event) {
    switch (event.state.mouseMode) {
      case MouseMode.none:
      case MouseMode.clickOnly:
        return null;
      case MouseMode.upDownScroll:
      case MouseMode.upDownScrollDrag:
      case MouseMode.upDownScrollMove:
        // Up events are never reported for mouse wheel buttons.
        if (event.button.isWheel &&
            event.buttonState == TerminalMouseButtonState.up) {
          return null;
        }
        return MouseReporter.report(
          event.button,
          event.buttonState,
          event.position,
          event.state.mouseReportMode,
        );
    }
  }
}
