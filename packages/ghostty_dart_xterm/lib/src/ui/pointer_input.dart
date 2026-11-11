// Ported from package:xterm 4.0.0 (lib/src/ui/pointer_input.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// A kind of pointer event that `TerminalView` may report to the program
/// while it tracks the mouse (see `TerminalController.setPointerInputs`).
enum PointerInput {
  /// Taps / buttons presses & releases.
  tap,

  /// Scroll / mouse wheels events.
  scroll,

  /// Drag events, a pointer is in a down state and dragged across the terminal.
  drag,

  /// Move events, a pointer is in an up state and moved across the terminal.
  move,
}

/// A set of [PointerInput]s.
class PointerInputs {
  /// The kinds of pointer events in this set.
  final Set<PointerInput> inputs;

  /// A set of [inputs].
  const PointerInputs(this.inputs);

  /// No pointer events.
  const PointerInputs.none() : inputs = const <PointerInput>{};

  /// Every kind of pointer event.
  const PointerInputs.all()
    : inputs = const <PointerInput>{
        PointerInput.tap,
        PointerInput.scroll,
        PointerInput.drag,
        PointerInput.move,
      };
}
