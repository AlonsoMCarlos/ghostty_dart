/// Tracked grid references (`grid_ref_tracked.h`).
library;

import 'dart:ffi';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../terminal/terminal.dart' show VtTerminal;
import 'grid_ref.dart';

/// An **owned** reference to one cell that follows the cell as the terminal
/// changes (`GhosttyTrackedGridRef`).
///
/// Create one with [VtTerminalGrid.trackGridRef]. Scrolling, scrollback
/// pruning, resize/reflow and other changes move it with its cell, so it
/// suits long-lived anchors such as the ends of a selection:
///
/// ```dart
/// final anchor = terminal.trackGridRef(const GridPoint.active(0, 0))!;
/// terminal.write(utf8.encode('\n' * 100));        // the cell scrolls up
/// print(anchor.pointIn(PointSpace.screen));        // still the same cell
/// anchor.dispose();
/// ```
///
/// When its cell is discarded (e.g. pruned from the scrollback) the
/// reference stays alive but has no value: [hasValue] is `false` and the
/// readers return `null`. [moveTo] points it at a cell again.
///
/// A tracked reference belongs to the screen (primary or alternate) that
/// was active when it was created or last moved, which may differ from the
/// terminal's active screen.
///
/// **Ownership:** call [dispose] when done; a forgotten reference is freed
/// some time after it is garbage collected (between event-loop turns).
/// Disposing its terminal disposes it first. It keeps its terminal object
/// reachable. Members throw [StateError] after
/// [dispose] and when called from inside a callback of the terminal.
final class TrackedGridRef implements Finalizable {
  TrackedGridRef._(this._terminal, Pointer<GhosttyTrackedGridRefImpl> pointer)
    : _handle = NativeHandle(
        pointer,
        typeName: 'TrackedGridRef',
        free: (p) => ghostty_tracked_grid_ref_free(p),
        finalizer: null,
      ) {
    bindHandle(this, _handle);
    final terminalHandle = _terminalHandle;
    terminalHandle.addDependent(_handle);
    // Like a NativeFinalizer, the Dart one watches the handle; dispose()
    // detaches it through a cleanup. The locals keep `this` out of the
    // closure. The token holds the terminal handle, so the terminal's
    // NativeFinalizer (which may run on another thread and writes to every
    // registered ref) cannot run before or during this ref's free.
    final handle = _handle;
    _finalizer.attach(handle, (
      ref: pointer.address,
      terminal: terminalHandle,
    ), detach: handle);
    handle.addCleanup(() => _finalizer.detach(handle));
  }

  /// Frees a forgotten reference on this isolate's event loop.
  ///
  /// Not a `NativeFinalizer`: unlike most frees,
  /// `ghostty_tracked_grid_ref_free` writes to its (still live) terminal,
  /// removing the pin from the page list. A native finalizer may run on any
  /// thread at any moment, e.g. during a garbage collection started by
  /// another isolate of the group while this one is inside `vt_write`; that
  /// would race the library's page list. A Dart [Finalizer] runs as an
  /// event on this isolate, so never while a terminal call is on the stack.
  /// The cost is that a reference still alive when the isolate exits is not
  /// freed (a few bytes; the terminal's own free detaches it).
  static final _finalizer =
      Finalizer<({int ref, NativeHandle<GhosttyTerminalImpl> terminal})>(
        (token) =>
            ghostty_tracked_grid_ref_free(Pointer.fromAddress(token.ref)),
      );

  /// Strong reference: [moveTo] needs the terminal, and snapshots are
  /// guarded by its handle.
  final VtTerminal _terminal;
  final NativeHandle<GhosttyTrackedGridRefImpl> _handle;

  NativeHandle<GhosttyTerminalImpl> get _terminalHandle =>
      handleOf<GhosttyTerminalImpl>(_terminal);

  /// Whether [dispose] has been called (directly or by disposing the
  /// terminal).
  bool get isDisposed => _handle.isDisposed;

  /// Whether the reference currently points at a cell. `false` once its
  /// cell has been discarded, until [moveTo] succeeds.
  bool get hasValue => ghostty_tracked_grid_ref_has_value(_pointer('hasValue'));

  /// The tracked cell's position in [space], or `null` when the reference
  /// has no value or the cell cannot be expressed in [space] (e.g. a cell
  /// that scrolled into the history has no [PointSpace.active] position).
  ///
  /// Throws [ArgumentError] for [PointSpace.unknown].
  GridPoint? pointIn(PointSpace space) {
    final tag = pointSpaceCodec.encode(space);
    final pointer = _pointer('pointIn');
    return withScratch(
      sizeOf<GhosttyPointCoordinate>(),
      (out) => readPointCoordinate(
        _terminalHandle,
        space,
        out,
        (coordinate) =>
            ghostty_tracked_grid_ref_point(pointer, tag, coordinate),
        'ghostty_tracked_grid_ref_point',
      ),
    );
  }

  /// A borrowed [GridRef] to the tracked cell, for reading its contents, or
  /// `null` when the reference has no value.
  ///
  /// The snapshot has the usual [GridRef] lifetime: take it right before
  /// reading and do not keep it across terminal changes.
  ///
  /// [GridRef.pointIn] resolves against the terminal's *active* screen, so
  /// for a reference that belongs to the other screen it returns `null`;
  /// use [pointIn] on the tracked reference instead.
  GridRef? snapshot() {
    final pointer = _pointer('snapshot');
    return withScratch(sizeOf<GhosttyGridRef>(), (out) {
      final ref = out.cast<GhosttyGridRef>();
      final hasValue = checkResultHasValue(
        ghostty_tracked_grid_ref_snapshot(pointer, ref),
        'ghostty_tracked_grid_ref_snapshot',
      );
      return hasValue ? gridRefFromNative(_terminalHandle, ref.ref) : null;
    });
  }

  /// Makes the reference track the cell at [point] instead, resolved
  /// against the terminal's currently active screen, and clears a
  /// "no value" state.
  ///
  /// Returns `false`, leaving the reference unchanged, when [point] is
  /// outside its coordinate space. Throws [ArgumentError] for
  /// [PointSpace.unknown] and [GhosttyException] if the library runs out of
  /// memory (the reference is then unchanged too).
  bool moveTo(GridPoint point) {
    final pointer = _pointer('moveTo');
    return withScratch(sizeOf<GhosttyPoint>(), (block) {
      final nativePoint = block.cast<GhosttyPoint>();
      gridPointToNative(point, nativePoint.ref);
      final code = checkResultAllowing(
        ghostty_tracked_grid_ref_set(
          pointer,
          _terminalHandle.pointer,
          nativePoint.ref,
        ),
        'ghostty_tracked_grid_ref_set',
        const {GhosttyResultCode.invalidValue},
      );
      return code == GhosttyResultCode.success;
    });
  }

  /// Frees the native reference. Safe to call more than once.
  void dispose() => _handle.dispose();

  /// The native pointer, after checking that this reference is not
  /// disposed and the terminal is not running a callback ([member] names
  /// the caller in the error).
  Pointer<GhosttyTrackedGridRefImpl> _pointer(String member) {
    final pointer = _handle.pointer;
    if (_terminalHandle.isInUse) {
      throw StateError(
        'TrackedGridRef.$member must not be called from inside a callback '
        'of its terminal',
      );
    }
    return pointer;
  }
}

/// Wraps a tracked reference that `ghostty_terminal_grid_ref_track` made
/// for [terminal], taking ownership of [pointer].
TrackedGridRef newTrackedGridRef(
  VtTerminal terminal,
  Pointer<GhosttyTrackedGridRefImpl> pointer,
) => TrackedGridRef._(terminal, pointer);
