/// Internal native plumbing shared by the selection, search and text
/// modules: resolving points to native grid references and passing
/// codepoint lists. Not exported.
library;

import 'dart:ffi';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';

/// Throws [StateError] when [member] (e.g. `'TerminalSearch.feed'`), a
/// member of an object bound to the terminal behind [terminal], is called
/// from inside a callback of that terminal: the library is not reentrant.
void checkNotInTerminalCallback(
  NativeHandle<GhosttyTerminalImpl> terminal,
  String member,
) {
  if (terminal.isInUse) {
    throw StateError(
      '$member must not be called from inside a callback of its terminal',
    );
  }
}

/// The largest Unicode scalar value.
const _maxCodepoint = 0x10FFFF;

/// Resolves [point] against the active screen of the terminal behind
/// [terminal] and stores the grid reference in [out] (a struct view, such
/// as a field of a native options struct). Returns `false`, leaving [out]
/// unchanged, when [point] is outside its coordinate space.
///
/// Throws [ArgumentError] for [PointSpace.unknown] and [RangeError] for a
/// coordinate that does not fit the native point.
bool resolveGridRef(
  NativeHandle<GhosttyTerminalImpl> terminal,
  GridPoint point,
  GhosttyGridRef out,
) {
  final pointBytes = align8(sizeOf<GhosttyPoint>());
  return withScratch(pointBytes + sizeOf<GhosttyGridRef>(), (block) {
    final nativePoint = block.cast<GhosttyPoint>();
    final ref = (block + pointBytes).cast<GhosttyGridRef>();
    gridPointToNative(point, nativePoint.ref);
    final code = checkResultAllowing(
      ghostty_terminal_grid_ref(terminal.pointer, nativePoint.ref, ref),
      'ghostty_terminal_grid_ref',
      const {GhosttyResultCode.invalidValue},
    );
    if (code != GhosttyResultCode.success) return false;
    copyGridRef(ref.ref, out);
    return true;
  });
}

/// The [PointSpace.screen] point of [ref] on the active screen of the
/// terminal behind [terminal], or `null` when [ref] is not a cell of that
/// screen.
///
/// `ghostty_terminal_point_from_grid_ref` looks the page of [ref] up in
/// the active screen's page list and never dereferences it, so this is
/// safe for a reference whose page may have been freed (the other screen,
/// another terminal, or evicted scrollback). It does not check that the
/// in-page position is inside the page; see [isLiveGridRef] for that.
GridPoint? screenPointOfRef(
  NativeHandle<GhosttyTerminalImpl> terminal,
  GhosttyGridRef ref,
) {
  final refBytes = align8(sizeOf<GhosttyGridRef>());
  return withScratch(refBytes + sizeOf<GhosttyPointCoordinate>(), (block) {
    final copy = block.cast<GhosttyGridRef>();
    final coordinate = (block + refBytes).cast<GhosttyPointCoordinate>();
    copyGridRef(ref, copy.ref);
    final code = checkResultAllowing(
      ghostty_terminal_point_from_grid_ref(
        terminal.pointer,
        copy,
        GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN,
        coordinate,
      ),
      'ghostty_terminal_point_from_grid_ref',
      const {GhosttyResultCode.noValue, GhosttyResultCode.invalidValue},
    );
    if (code != GhosttyResultCode.success) return null;
    return GridPoint.screen(coordinate.ref.x, coordinate.ref.y);
  });
}

/// Whether [ref] is a cell of the active screen of the terminal behind
/// [terminal] right now: its page is in the screen's page list
/// ([screenPointOfRef]) and resolving that screen point gives [ref] back,
/// which also rules out an in-page row past the end of a reused page.
///
/// Never dereferences the page of [ref]. Costs two library calls, each
/// a walk of the page list.
bool isLiveGridRef(
  NativeHandle<GhosttyTerminalImpl> terminal,
  GhosttyGridRef ref,
) {
  final point = screenPointOfRef(terminal, ref);
  if (point == null) return false;
  return withScratch(sizeOf<GhosttyGridRef>(), (block) {
    final resolved = block.cast<GhosttyGridRef>().ref;
    return resolveGridRef(terminal, point, resolved) &&
        isSameGridRef(resolved, ref);
  });
}

/// Whether [a] and [b] (struct views) name the same page and position.
bool isSameGridRef(GhosttyGridRef a, GhosttyGridRef b) =>
    a.node == b.node && a.x == b.x && a.y == b.y;

/// Copies the fields of [from] into [to] (struct views).
void copyGridRef(GhosttyGridRef from, GhosttyGridRef to) => to
  ..node = from.node
  ..x = from.x
  ..y = from.y;

/// Runs [action] with [codepoints] as a native `uint32_t` array.
///
/// `null` passes NULL and 0, which the library reads as "use the default
/// set". An empty list passes a valid pointer and 0: an explicitly empty
/// set. Throws [RangeError] (naming [name]) for a value that is not a
/// Unicode scalar value (0–0x10FFFF): the library reinterprets the array as
/// 21-bit values without checking them.
R withCodepoints<R>(
  List<int>? codepoints,
  String name,
  R Function(Pointer<Uint32> data, int length) action,
) {
  if (codepoints == null) return action(nullptr, 0);
  for (final codepoint in codepoints) {
    RangeError.checkValueInInterval(codepoint, 0, _maxCodepoint, name);
  }
  return withScratch(codepoints.length * sizeOf<Uint32>(), (block) {
    final data = block.cast<Uint32>();
    data.asTypedList(codepoints.length).setAll(0, codepoints);
    return action(data, codepoints.length);
  });
}

/// Rounds [bytes] up to a multiple of 8, to lay several values out in one
/// scratch block.
int align8(int bytes) => (bytes + 7) & ~7;
