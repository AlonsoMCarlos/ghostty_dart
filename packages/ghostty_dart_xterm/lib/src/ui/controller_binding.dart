import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart'
    show VtTerminalController;

/// How a `TerminalView` connects a `TerminalController` to the terminal it
/// shows, without public members on the controller (xterm has none).
/// Never exported.
abstract interface class TerminalControllerBinding {
  /// Connects the controller to [vt], the engine of the view's terminal;
  /// replaces an earlier connection.
  void attach(VtTerminalController vt);

  /// Disconnects the controller from [vt] if it is connected to it.
  void detach(VtTerminalController vt);
}

final _bindings = Expando<TerminalControllerBinding>(
  'TerminalControllerBinding',
);

/// Registers [binding] for [controller]; once, in its constructor.
void bindTerminalController(
  Object controller,
  TerminalControllerBinding binding,
) {
  assert(_bindings[controller] == null, 'controller bound twice');
  _bindings[controller] = binding;
}

/// The binding of [controller]; [StateError] if it has none.
TerminalControllerBinding terminalControllerBinding(Object controller) =>
    _bindings[controller] ??
    (throw StateError('$controller has no ghostty_dart_xterm binding'));
