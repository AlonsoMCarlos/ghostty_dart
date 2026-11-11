import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

/// What the adapter's UI (`TerminalView`, `TerminalController`) needs from
/// a `Terminal` beyond xterm's public API (ADR 0013). Never exported: the
/// engine stays out of xterm's API surface.
///
/// `Terminal` binds one in its constructor with [bindTerminalInternals];
/// the UI reads it with [terminalInternals]. Only members listed in the
/// plan's `contratos.md` belong here.
abstract interface class TerminalInternals {
  /// The controller the terminal wraps; it owns the libghostty-vt terminal.
  /// The view draws it with `VtTerminalView`. Disposed by the terminal's
  /// `dispose()`, never by the UI.
  VtTerminalController get vtController;

  /// The device pixel ratio of the view that shows the terminal, set by
  /// `TerminalView` whenever it changes (`null`: no view, headless). The
  /// terminal uses it to report xterm's `onResize` pixel values (the cell
  /// size in logical pixels) from the controller's device pixels.
  double? get viewDevicePixelRatio;
  set viewDevicePixelRatio(double? value);
}

final _internals = Expando<TerminalInternals>('TerminalInternals');

/// Binds [internals] to [terminal] (a `Terminal`); once per terminal.
void bindTerminalInternals(Object terminal, TerminalInternals internals) {
  assert(_internals[terminal] == null, 'internals bound twice');
  _internals[terminal] = internals;
}

/// The internals bound to [terminal] (a `Terminal`).
///
/// Throws [StateError] if none were bound (only a `Terminal` has them).
TerminalInternals terminalInternals(Object terminal) =>
    _internals[terminal] ??
    (throw StateError('$terminal has no ghostty_dart_xterm internals'));
