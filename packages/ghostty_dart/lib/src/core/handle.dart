/// Ownership of native libghostty-vt objects: the [NativeHandle] base used by
/// every public wrapper, and the internal registry that lets sibling modules
/// reach a wrapper's handle without exposing `dart:ffi` publicly.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'library_info.dart';
import 'result.dart';

/// An owned native object: its pointer, its `_free` function and the
/// [NativeFinalizer] that frees it if the owner is garbage collected.
///
/// Every public wrapper of an owned libghostty-vt object keeps one of these
/// in a private field, implements [Finalizable] itself, and forwards
/// `dispose()` / `isDisposed` to it. The handle guarantees:
///
/// - [dispose] is idempotent. It detaches the finalizer, disposes the
///   [addDependent] objects, frees the object and then runs the [addCleanup]
///   callbacks (last added first).
/// - [pointer] throws [StateError] once disposed.
/// - A [dispose] that happens inside [use] (for example from a Dart callback
///   that runs during `ghostty_terminal_vt_write`) marks the handle disposed
///   at once but defers the native free until the outermost [use] returns,
///   so the library never runs on freed memory.
/// - The same holds for a dependent (see [addDependent]) while its owner is
///   inside [use]: its free waits until the owner's outermost [use] returns
///   (and runs before the owner's own deferred free). Some frees write to
///   their owner (`ghostty_search_free` and `ghostty_tracked_grid_ref_free`
///   unregister from the terminal), which must not happen while the owner's
///   native call is still on the stack.
/// - Conversely, an owner disposed while one of its dependents is inside
///   the dependent's own [use] keeps its memory until that dependent has
///   been freed: a dependent is never freed after its owner.
final class NativeHandle<T extends NativeType> implements Finalizable {
  /// Takes ownership of [pointer].
  ///
  /// [free] is called once by [dispose]. [finalizer] must call the same
  /// native `_free` function; pass `null` only for objects whose `_free`
  /// takes more than the handle (they are then freed by [dispose] only, and
  /// leak if never disposed). [typeName] is the public type name used in
  /// error messages. [externalSize] is a hint for the garbage collector.
  NativeHandle(
    Pointer<T> pointer, {
    required this.typeName,
    required void Function(Pointer<T> pointer) free,
    required NativeFinalizer? finalizer,
    int externalSize = 0,
  }) : _pointer = pointer,
       _free = free,
       _finalizer = finalizer {
    if (pointer == nullptr) {
      throw ArgumentError.value(pointer, 'pointer', 'must not be NULL');
    }
    finalizer?.attach(
      this,
      pointer.cast(),
      detach: this,
      externalSize: externalSize,
    );
  }

  /// The public type that owns this handle, e.g. `VtTerminal`.
  final String typeName;

  final void Function(Pointer<T> pointer) _free;
  final NativeFinalizer? _finalizer;
  Pointer<T> _pointer;
  bool _disposed = false;
  int _activeUses = 0;
  int _epoch = 0;
  List<void Function()>? _cleanups;
  List<WeakReference<NativeHandle>>? _dependents;
  Map<Object, Object>? _attachments;

  /// The handle this one was registered with by [addDependent], if any.
  NativeHandle? _owner;

  /// Disposed dependents whose free waits for this handle's outermost [use].
  List<NativeHandle>? _deferredDependents;

  /// Disposed dependents still inside their own [use] when this handle was
  /// disposed; this handle's free waits until they are freed.
  List<NativeHandle>? _busyDependents;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// The native pointer.
  ///
  /// Throws [StateError] if the handle is disposed. Read it right before the
  /// native call and never store it beyond the current synchronous call.
  /// For calls that can run Dart callbacks, use [use] instead.
  Pointer<T> get pointer {
    if (_disposed) throw StateError('$typeName has been disposed');
    return _pointer;
  }

  /// Throws [StateError] if the handle is disposed.
  void checkNotDisposed() {
    if (_disposed) throw StateError('$typeName has been disposed');
  }

  /// Runs [action] with the native pointer, deferring any [dispose] that
  /// happens during it until it returns.
  ///
  /// Use this for every native call that can call back into Dart
  /// (`vt_write`, `resize`, `reset`, ...). [action] must be synchronous.
  R use<R>(R Function(Pointer<T> pointer) action) {
    final p = pointer;
    _activeUses++;
    try {
      return action(p);
    } finally {
      _activeUses--;
      if (_activeUses == 0 && (_deferredDependents != null || _awaitsFree)) {
        _releaseDeferred();
      }
    }
  }

  /// Whether the native free may run now: neither this handle nor its owner
  /// is inside [use].
  bool get _canRelease => _activeUses == 0 && !(_owner?.isInUse ?? false);

  /// Whether this handle is disposed but its native free has not run yet.
  bool get _awaitsFree => _disposed && _pointer != nullptr;

  // The free path of a disposed handle, each step waiting for one thing:
  //   _releaseWhenIdle  waits for this handle's own use() and for busy
  //                     dependents (re-entered by _dependentFreed);
  //   _releaseOrDefer   waits for the owner's use() (queued on the owner,
  //                     drained by the owner's _releaseDeferred);
  //   _release          frees, runs the cleanups and tells the owner.

  /// Frees this disposed handle unless something it waits for is still
  /// running: its own [use], or a dependent's [use]. Checked when it runs,
  /// so a free triggered meanwhile (by the last busy dependent) is not
  /// repeated.
  void _releaseWhenIdle() {
    if (_awaitsFree && _activeUses == 0 && (_busyDependents?.isEmpty ?? true)) {
      _releaseOrDefer();
    }
  }

  /// Frees this handle, now or (when its owner is inside [use]) once the
  /// owner's outermost [use] returns. Called when disposed and not in use.
  void _releaseOrDefer() {
    final owner = _owner;
    if (owner != null && owner.isInUse) {
      (owner._deferredDependents ??= []).add(this);
    } else {
      _release();
    }
  }

  /// Runs the frees that waited for the outermost [use] to return: first
  /// the deferred dependents, then this handle if it was disposed meanwhile.
  /// Every free runs even if one throws; the first error is rethrown.
  void _releaseDeferred() {
    final dependents = _deferredDependents;
    _deferredDependents = null;
    _runAll([
      if (dependents != null)
        for (final dependent in dependents)
          if (dependent._pointer != nullptr && dependent._canRelease)
            dependent._release,
      _releaseWhenIdle,
    ]);
  }

  /// Whether a [use] call is running, i.e. we are inside a native call that
  /// may be calling back into Dart.
  bool get isInUse => _activeUses > 0;

  /// A counter bumped by [bumpEpoch] on every mutating call of the owner.
  ///
  /// Borrowed views (render rows, grid refs, kitty images) capture it when
  /// created and treat themselves as invalid once it changes.
  int get epoch => _epoch;

  /// Invalidates borrowed views; call after every mutating native call.
  void bumpEpoch() => _epoch++;

  /// Registers [cleanup] to run once, after the native object is freed by
  /// [dispose] (e.g. `NativeCallable.close`). Cleanups run last-added first.
  ///
  /// Cleanups do not run when the object is freed by the garbage collector.
  /// Throws [StateError] if the handle is disposed.
  void addCleanup(void Function() cleanup) {
    checkNotDisposed();
    (_cleanups ??= []).add(cleanup);
  }

  /// Registers [dependent], a native object that borrows this one and must
  /// be freed before it (e.g. a formatter, which needs its terminal to
  /// outlive it). [dispose] disposes every live dependent first.
  ///
  /// Held weakly: a dependent that is garbage collected is simply skipped.
  /// Throws [StateError] if this handle is disposed.
  ///
  /// While this handle is inside [use], disposing [dependent] (directly or
  /// through this handle's [dispose]) defers its native free until the
  /// outermost [use] returns. A handle can be the dependent of one owner
  /// only; throws [StateError] for a second, different owner.
  void addDependent(NativeHandle dependent) {
    checkNotDisposed();
    final owner = dependent._owner;
    if (owner != null && !identical(owner, this)) {
      throw StateError('${dependent.typeName} already has an owner');
    }
    dependent._owner = this;
    final dependents = _dependents ??= [];
    if (dependents.length >= _pruneDependentsAt) {
      // Keep disposed dependents whose free is still pending (they may be
      // inside their own use, which this handle's free must wait for).
      dependents.removeWhere((ref) => ref.target?._pointer == nullptr);
    }
    dependents.add(WeakReference(dependent));
  }

  /// Dead or disposed dependents are pruned once the list reaches this size,
  /// so a long-lived parent with many short-lived children stays small.
  static const _pruneDependentsAt = 16;

  /// Returns the value stored by [setAttachment] for [key], or `null`.
  ///
  /// Attachments let a sibling module keep per-object state (for example the
  /// `NativeCallable`s of terminal callbacks) without changing the owner's
  /// class. Use a private top-level `Object()` as the key.
  A? attachment<A extends Object>(Object key) => _attachments?[key] as A?;

  /// Stores [value] for [key], or removes it when [value] is `null`.
  void setAttachment(Object key, Object? value) {
    if (value == null) {
      _attachments?.remove(key);
    } else {
      (_attachments ??= {})[key] = value;
    }
  }

  /// Frees the native object. Safe to call more than once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer?.detach(this);
    final dependents = _dependents;
    _dependents = null;
    // A dependent whose cleanup throws must not stop this object (and the
    // other dependents) from being freed: the finalizer is already
    // detached, so skipping the free would leak it for good.
    _runAll([
      if (dependents != null)
        for (final ref in dependents)
          if (ref.target case final dependent?)
            () => _disposeDependent(dependent),
      _releaseWhenIdle,
    ]);
  }

  /// Disposes [dependent] for this handle's [dispose]. A dependent still
  /// inside its own [use] keeps its pointer until that returns, so this
  /// handle's free waits for it (the dependent may write to this object).
  void _disposeDependent(NativeHandle dependent) {
    try {
      dependent.dispose();
    } finally {
      if (dependent._awaitsFree && dependent._activeUses > 0) {
        (_busyDependents ??= []).add(dependent);
      }
    }
  }

  void _release() {
    final p = _pointer;
    _pointer = nullptr;
    try {
      _free(p);
      final cleanups = _cleanups;
      _cleanups = null;
      _attachments = null;
      if (cleanups != null) _runAll(cleanups.reversed);
    } finally {
      _owner?._dependentFreed(this);
    }
  }

  /// Frees this handle if it was only waiting for [dependent] to be freed.
  void _dependentFreed(NativeHandle dependent) {
    final busy = _busyDependents;
    if (busy != null && busy.remove(dependent) && busy.isEmpty) {
      _releaseWhenIdle();
    }
  }

  /// Runs every action even if some throw, then rethrows the first error.
  static void _runAll(Iterable<void Function()> actions) {
    Object? firstError;
    StackTrace? firstStack;
    for (final action in actions) {
      try {
        action();
      } catch (e, s) {
        firstError ??= e;
        firstStack ??= s;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}

/// Creates a native object with a `ghostty_*_new`-style function.
///
/// Checks that the loaded library is compatible (see
/// [ensureCompatibleLibrary]), allocates the out-parameter, calls [create]
/// with it and maps its result with [checkResult]. Returns the new pointer,
/// which the caller wraps in a [NativeHandle] right away.
///
/// ```dart
/// final pointer = createNative<GhosttyTerminalImpl>(
///   'ghostty_terminal_new',
///   (out) => ghostty_terminal_new(nullptr, out, cols, rows),
/// );
/// ```
Pointer<T> createNative<T extends NativeType>(
  String operation,
  int Function(Pointer<Pointer<T>> out) create,
) {
  ensureCompatibleLibrary();
  // Allocated as `void*` because allocators need a constant type argument.
  final slot = calloc<Pointer<Void>>();
  final out = slot.cast<Pointer<T>>();
  try {
    checkResult(create(out), operation);
    final pointer = out.value;
    if (pointer == nullptr) {
      throw GhosttyException(
        operation,
        resultCodec.encode(GhosttyResultCode.invalidValue),
      );
    }
    return pointer;
  } finally {
    calloc.free(slot);
  }
}

final Expando<NativeHandle> _handles = Expando('ghostty_dart native handles');

/// Associates [handle] with its public [owner] so sibling modules can reach
/// it with [handleOf]. Call once, in the owner's constructor.
void bindHandle(Object owner, NativeHandle handle) {
  if (_handles[owner] != null) {
    throw StateError('${handle.typeName} already has a native handle');
  }
  _handles[owner] = handle;
}

/// Returns the [NativeHandle] bound to [owner] by [bindHandle].
///
/// Throws [ArgumentError] if [owner] has no handle (it is not a native-backed
/// object of this package). The returned handle may be disposed; read
/// [NativeHandle.pointer] (which throws [StateError]) to use it.
NativeHandle<T> handleOf<T extends NativeType>(Object owner) {
  final handle = _handles[owner];
  if (handle == null) {
    throw ArgumentError.value(owner, 'owner', 'has no native handle');
  }
  return handle as NativeHandle<T>;
}
