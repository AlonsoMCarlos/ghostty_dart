// Ported from package:xterm 4.0.0 (lib/src/base/event.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'disposable.dart';

/// A listener of an [Event].
typedef EventListener<T> = void Function(T event);

/// The listening side of an [EventEmitter]: call it with a listener to
/// subscribe.
class Event<T> {
  /// The emitter this event listens to.
  final EventEmitter<T> emitter;

  /// Creates the listening side of [emitter].
  Event(this.emitter);

  /// Subscribes [listener].
  void call(EventListener<T> listener) {
    emitter(listener);
  }
}

/// A list of listeners that [emit] calls in order.
class EventEmitter<T> {
  final _listeners = <EventListener<T>>[];

  /// Subscribes [listener]; dispose the result to unsubscribe.
  EventSubscription<T> call(EventListener<T> listener) {
    _listeners.add(listener);
    return EventSubscription(this, listener);
  }

  /// Calls every listener with [event].
  void emit(T event) {
    for (final listener in _listeners) {
      listener(event);
    }
  }

  /// The listening side of this emitter.
  Event<T> get event => Event(this);
}

/// A subscription to an [EventEmitter]; [dispose] unsubscribes.
class EventSubscription<T> with Disposable {
  /// The emitter subscribed to.
  final EventEmitter<T> emitter;

  /// The subscribed listener.
  final EventListener<T> listener;

  /// A subscription of [listener] to [emitter].
  EventSubscription(this.emitter, this.listener);

  @override
  void dispose() {
    emitter._listeners.remove(listener);
  }
}
