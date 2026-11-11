/// Package-internal access to the parts of a [VtTerminalController] that
/// are not public API: the render state the painter reads and the mouse
/// encoder the pointer layer configures. Never exported.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import 'terminal_controller.dart';

/// The non-public state of one [VtTerminalController].
///
/// Only `lib/src/seams/controller_seams.dart` reads it; the view's parts
/// work against the seam interfaces instead.
abstract interface class ControllerInternals {
  /// The controller's render state: one per controller, updated by the
  /// view's painter once per frame.
  RenderState get renderState;

  /// The controller's mouse encoder; [VtTerminalController.sendMouse]
  /// syncs its modes from the terminal before every event.
  MouseEncoder get mouseEncoder;

  /// Whether the program holds rendering (synchronized output, DEC mode
  /// 2026, reported by `onRenderHold`).
  bool get isRenderHeld;

  /// Modifiers latched by the on-screen key toolbar, applied to the next
  /// key or text input and then cleared by whoever consumed them.
  ValueNotifier<KeyModifiers> get latchedModifiers;

  /// The seams object that reads frames from [renderState]; debug builds
  /// use it to catch two views sharing one controller.
  Object? frameOwner;

  /// Whether a widget (a view or the key toolbar) built seams over this
  /// controller, so the Flutter scheduler binding exists and setters may
  /// ask it which phase the frame is in.
  bool usedByWidgets = false;

  /// Resizes the terminal at once and delivers `onResize` and the
  /// listener notification after the current frame (see
  /// [VtTerminalController.resize]).
  void resizeDuringLayout(
    int cols,
    int rows, {
    required int cellWidthPx,
    required int cellHeightPx,
  });

  /// The live highlights on the active screen whose ends are both known,
  /// as screen points with `start` before `end`, in creation order. Empty
  /// (and cheap) when there are none.
  List<({Color color, GridPoint start, GridPoint end})> screenHighlights();
}

final _internals = Expando<ControllerInternals>('VtTerminalController');

/// Registers [internals] for [controller]; called once by its constructor.
void bindControllerInternals(
  VtTerminalController controller,
  ControllerInternals internals,
) {
  assert(_internals[controller] == null, 'internals bound twice');
  _internals[controller] = internals;
}

/// The internals of [controller]. Throws [StateError] after
/// [VtTerminalController.dispose].
ControllerInternals internalsOf(VtTerminalController controller) {
  if (controller.isDisposed) {
    throw StateError('VtTerminalController has been disposed');
  }
  return _internals[controller]!;
}
