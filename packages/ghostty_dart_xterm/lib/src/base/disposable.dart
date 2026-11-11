// Ported from package:xterm 4.0.0 (lib/src/base/disposable.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'event.dart';

/// Something that can be disposed once, disposing what it [register]ed
/// with it and then firing [onDisposed]. `TerminalHighlight` mixes it in.
mixin Disposable {
  final _disposables = <Disposable>[];

  /// Whether [dispose] was called.
  bool get disposed => _disposed;
  bool _disposed = false;

  /// Fires after [dispose] has disposed everything registered.
  Event<dynamic> get onDisposed => _onDisposed.event;
  final _onDisposed = EventEmitter<dynamic>();

  /// Disposes [disposable] together with this object.
  void register(Disposable disposable) {
    assert(!_disposed);
    _disposables.add(disposable);
  }

  /// Calls [callback] when this object is disposed.
  void registerCallback(void Function() callback) {
    assert(!_disposed);
    _disposables.add(_DisposeCallback(callback));
  }

  /// Disposes everything registered and fires [onDisposed].
  void dispose() {
    _disposed = true;
    for (final disposable in _disposables) {
      disposable.dispose();
    }
    _onDisposed.emit(null);
  }
}

class _DisposeCallback with Disposable {
  final void Function() callback;

  _DisposeCallback(this.callback);

  @override
  void dispose() {
    super.dispose();
    callback();
  }
}
