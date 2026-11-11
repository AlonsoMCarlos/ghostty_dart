// Ported from package:xterm 4.0.0 (lib/src/base/observable.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// A minimal listener list, xterm's own (not a Flutter `Listenable`):
/// `Terminal` notifies its [listeners] after every `write`.
mixin Observable {
  /// The registered listeners, called in insertion order.
  final listeners = <void Function()>{};

  /// Registers [listener].
  void addListener(void Function() listener) {
    listeners.add(listener);
  }

  /// Unregisters [listener].
  void removeListener(void Function() listener) {
    listeners.remove(listener);
  }

  /// Calls every listener.
  void notifyListeners() {
    for (final listener in listeners) {
      listener();
    }
  }
}
