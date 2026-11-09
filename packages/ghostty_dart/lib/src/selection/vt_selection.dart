/// Selections (`selection.h`): the [VtSelection] value and the
/// [VtTerminalSelection] extension that makes and installs them.
library;

import 'dart:ffi';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../grid/grid_ref.dart' show GridRef, gridRefFromNative;
import '../grid/tracked_grid_ref.dart' show TrackedGridRef;
import '../terminal/terminal.dart' show VtTerminal;
import '../terminal/terminal_native.dart'
    show checkNotInCallback, setOption, tryReadData;
import 'selection_enums.dart';
import 'selection_native.dart';

/// Makes selections of a [VtTerminal] and reads or sets its active
/// selection, the one the terminal highlights.
///
/// ```dart
/// final word = terminal.selectWord(const GridPoint.viewport(4, 0));
/// if (word != null) terminal.selection = word;   // highlight it
/// ```
///
/// The `select…` members only compute a [VtSelection]; nothing is
/// highlighted until it is assigned to [selection]. Copy the selected text
/// with `TerminalFormatter.formatText(selection: ...)`.
///
/// These members are only visible when this extension is imported; the
/// package barrel exports it.
extension VtTerminalSelection on VtTerminal {
  /// The active screen's selection, as drawn by renderers (see
  /// `RenderRow.selectionStart`), or `null` when nothing is selected.
  ///
  /// Reading returns a new borrowed [VtSelection] snapshot. Assigning
  /// installs a copy of the value: the terminal then keeps its selection
  /// up to date as content scrolls, and the value assigned becomes stale
  /// (assigning changes the terminal). Assign `null` to clear it.
  ///
  /// Throws [ArgumentError] when assigning a selection of another terminal,
  /// and [StateError] for a stale selection, after [VtTerminal.dispose] or
  /// from inside a callback of this terminal.
  VtSelection? get selection {
    final handle = _checkedHandle('selection');
    return tryReadData(
      handle.pointer,
      GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SELECTION,
      sizeOf<GhosttySelection>(),
      (out) => selectionFromNative(handle, out.cast<GhosttySelection>().ref),
    );
  }

  set selection(VtSelection? value) {
    final handle = _checkedHandle('selection');
    const option = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SELECTION;
    if (value == null) return setOption(handle, option, nullptr);
    withScratch(sizeOf<GhosttySelection>(), (out) {
      final native = out.cast<GhosttySelection>();
      selectionToNative(value, handle, native, 'selection');
      setOption(handle, option, native.cast());
    });
  }

  /// A selection from the cell at [start] to the cell at [end], both
  /// included, or `null` when either point is outside its coordinate space.
  ///
  /// The points may be in any [PointSpace], also different ones. A linear
  /// selection runs from [start] to [end] the way text flows, wrapping
  /// across rows; with [rectangle] it is the block of cells with [start]
  /// and [end] at opposite corners. [start] may come after [end]: the
  /// selection keeps the direction (see [VtSelection.order]).
  ///
  /// Throws [ArgumentError] for [PointSpace.unknown], and [StateError]
  /// after [VtTerminal.dispose] or from inside a callback of this terminal.
  VtSelection? selectRange(
    GridPoint start,
    GridPoint end, {
    bool rectangle = false,
  }) {
    final handle = _checkedHandle('selectRange');
    return withScratch(sizeOf<GhosttySelection>(), (out) {
      final native = out.cast<GhosttySelection>();
      final resolved =
          resolveGridRef(handle, start, native.ref.start) &&
          resolveGridRef(handle, end, native.ref.end);
      if (!resolved) return null;
      native.ref.rectangle = rectangle;
      return selectionFromNative(handle, native.ref);
    });
  }

  /// A selection between the cells that [start] and [end] track now, or
  /// `null` when either has no value or belongs to the screen (primary or
  /// alternate) that is not active.
  ///
  /// This is how a selection survives terminal changes: keep its ends as
  /// [TrackedGridRef]s and rebuild the selection from them when needed.
  /// See [selectRange] for [rectangle].
  ///
  /// Throws [StateError] if either reference is disposed, after
  /// [VtTerminal.dispose] or from inside a callback of this terminal.
  VtSelection? selectTrackedRange(
    TrackedGridRef start,
    TrackedGridRef end, {
    bool rectangle = false,
  }) {
    final handle = _checkedHandle('selectTrackedRange');
    final startHandle = handleOf<GhosttyTrackedGridRefImpl>(start);
    final endHandle = handleOf<GhosttyTrackedGridRefImpl>(end);
    return withScratch(sizeOf<GhosttySelection>(), (out) {
      final native = out.cast<GhosttySelection>();
      final resolved =
          _snapshotOnActiveScreen(handle, startHandle, native.ref.start) &&
          _snapshotOnActiveScreen(handle, endHandle, native.ref.end);
      if (!resolved) return null;
      native.ref.rectangle = rectangle;
      return selectionFromNative(handle, native.ref);
    });
  }

  /// The word under the cell at [at], or `null` when [at] is outside its
  /// coordinate space or the cell was never written (such as the blank
  /// cells after the end of a line).
  ///
  /// Words end at empty cells, at row ends that are not soft wraps, and
  /// at [boundaryCodepoints]. `null` uses Ghostty's default boundaries
  /// (space, tab, quotes, brackets, `,`, `:` and other punctuation); a
  /// custom list replaces them, so an empty list makes only empty cells
  /// end words. On a boundary character (such as a space between two
  /// words) the result is the run of boundary characters around it. Wide
  /// characters, combining marks and other non-ASCII text are part of
  /// words.
  ///
  /// Throws [RangeError] for a boundary value that is not a Unicode scalar
  /// value, [ArgumentError] for [PointSpace.unknown], and [StateError]
  /// after [VtTerminal.dispose] or from inside a callback of this terminal.
  VtSelection? selectWord(GridPoint at, {List<int>? boundaryCodepoints}) {
    final handle = _checkedHandle('selectWord');
    return withCodepoints(boundaryCodepoints, 'boundaryCodepoints', (
      codepoints,
      length,
    ) {
      final optionsBytes = align8(sizeOf<GhosttyTerminalSelectWordOptions>());
      return withScratch(optionsBytes + sizeOf<GhosttySelection>(), (block) {
        final options = block.cast<GhosttyTerminalSelectWordOptions>()
          ..initSized(sizeOf<GhosttyTerminalSelectWordOptions>());
        final out = (block + optionsBytes).cast<GhosttySelection>();
        if (!resolveGridRef(handle, at, options.ref.ref)) return null;
        options.ref
          ..boundary_codepoints = codepoints
          ..boundary_codepoints_len = length;
        return _derive(
          handle,
          out,
          ghostty_terminal_select_word(handle.pointer, options, out),
          'ghostty_terminal_select_word',
        );
      });
    });
  }

  /// The first word found going from [start] toward [end] (both included),
  /// or `null` when either point is outside its coordinate space or there
  /// is no word in between.
  ///
  /// For double-click-and-drag: ask for the nearest word from the click
  /// toward the pointer and from the pointer toward the click, and select
  /// from one to the other, so the selection does not collapse while the
  /// pointer is between words. `SelectionGesture` does this for you.
  /// [boundaryCodepoints] works as in [selectWord].
  ///
  /// Throws like [selectWord].
  VtSelection? selectWordBetween(
    GridPoint start,
    GridPoint end, {
    List<int>? boundaryCodepoints,
  }) {
    final handle = _checkedHandle('selectWordBetween');
    return withCodepoints(boundaryCodepoints, 'boundaryCodepoints', (
      codepoints,
      length,
    ) {
      final optionsBytes = align8(
        sizeOf<GhosttyTerminalSelectWordBetweenOptions>(),
      );
      return withScratch(optionsBytes + sizeOf<GhosttySelection>(), (block) {
        final options = block.cast<GhosttyTerminalSelectWordBetweenOptions>()
          ..initSized(sizeOf<GhosttyTerminalSelectWordBetweenOptions>());
        final out = (block + optionsBytes).cast<GhosttySelection>();
        final resolved =
            resolveGridRef(handle, start, options.ref.start) &&
            resolveGridRef(handle, end, options.ref.end);
        if (!resolved) return null;
        options.ref
          ..boundary_codepoints = codepoints
          ..boundary_codepoints_len = length;
        return _derive(
          handle,
          out,
          ghostty_terminal_select_word_between(handle.pointer, options, out),
          'ghostty_terminal_select_word_between',
        );
      });
    });
  }

  /// The line under the cell at [at], following soft wraps, without the
  /// leading and trailing [whitespace]; or `null` when [at] is outside its
  /// coordinate space or the line is blank.
  ///
  /// `null` [whitespace] uses Ghostty's default (spaces and tabs). With
  /// [semanticPromptBoundary], the line also stops where shell integration
  /// (OSC 133) marks a change between prompt, input and output.
  ///
  /// Throws like [selectWord].
  VtSelection? selectLine(
    GridPoint at, {
    List<int>? whitespace,
    bool semanticPromptBoundary = false,
  }) {
    final handle = _checkedHandle('selectLine');
    return withCodepoints(whitespace, 'whitespace', (codepoints, length) {
      final optionsBytes = align8(sizeOf<GhosttyTerminalSelectLineOptions>());
      return withScratch(optionsBytes + sizeOf<GhosttySelection>(), (block) {
        final options = block.cast<GhosttyTerminalSelectLineOptions>()
          ..initSized(sizeOf<GhosttyTerminalSelectLineOptions>());
        final out = (block + optionsBytes).cast<GhosttySelection>();
        if (!resolveGridRef(handle, at, options.ref.ref)) return null;
        options.ref
          ..whitespace = codepoints
          ..whitespace_len = length
          ..semantic_prompt_boundary = semanticPromptBoundary;
        return _derive(
          handle,
          out,
          ghostty_terminal_select_line(handle.pointer, options, out),
          'ghostty_terminal_select_line',
        );
      });
    });
  }

  /// All content of the active screen, scrollback included, from its first
  /// to its last non-blank cell; or `null` when the screen is blank.
  ///
  /// Throws [StateError] after [VtTerminal.dispose] or from inside a
  /// callback of this terminal.
  VtSelection? selectAll() {
    final handle = _checkedHandle('selectAll');
    return withScratch(sizeOf<GhosttySelection>(), (block) {
      final out = block.cast<GhosttySelection>();
      return _derive(
        handle,
        out,
        ghostty_terminal_select_all(handle.pointer, out),
        'ghostty_terminal_select_all',
      );
    });
  }

  /// The output of the command under the cell at [at], as marked by shell
  /// integration (OSC 133); or `null` when [at] is outside its coordinate
  /// space or the cell is not command output.
  ///
  /// Throws [ArgumentError] for [PointSpace.unknown], and [StateError]
  /// after [VtTerminal.dispose] or from inside a callback of this terminal.
  VtSelection? selectOutput(GridPoint at) {
    final handle = _checkedHandle('selectOutput');
    final refBytes = align8(sizeOf<GhosttyGridRef>());
    return withScratch(refBytes + sizeOf<GhosttySelection>(), (block) {
      final ref = block.cast<GhosttyGridRef>();
      final out = (block + refBytes).cast<GhosttySelection>();
      if (!resolveGridRef(handle, at, ref.ref)) return null;
      return _derive(
        handle,
        out,
        ghostty_terminal_select_output(handle.pointer, ref, out),
        'ghostty_terminal_select_output',
      );
    });
  }

  NativeHandle<GhosttyTerminalImpl> _checkedHandle(String member) {
    final handle = handleOf<GhosttyTerminalImpl>(this);
    handle.checkNotDisposed();
    checkNotInCallback(handle, member);
    return handle;
  }
}

/// Maps the result of a `ghostty_terminal_select_*` call that wrote [out]:
/// a selection, or `null` for `GHOSTTY_NO_VALUE`. Other errors throw.
VtSelection? _derive(
  NativeHandle<GhosttyTerminalImpl> terminal,
  Pointer<GhosttySelection> out,
  int raw,
  String operation,
) => checkResultHasValue(raw, operation)
    ? selectionFromNative(terminal, out.ref)
    : null;

/// Stores a snapshot of [tracked] in [out] (a struct view) and checks
/// that it lies on the active screen of [terminal]. `false` when it has no
/// value or lies elsewhere (the other screen, or another terminal).
bool _snapshotOnActiveScreen(
  NativeHandle<GhosttyTerminalImpl> terminal,
  NativeHandle<GhosttyTrackedGridRefImpl> tracked,
  GhosttyGridRef out,
) => withScratch(sizeOf<GhosttyGridRef>(), (block) {
  final ref = block.cast<GhosttyGridRef>();
  final hasValue = checkResultHasValue(
    ghostty_tracked_grid_ref_snapshot(tracked.pointer, ref),
    'ghostty_tracked_grid_ref_snapshot',
  );
  if (!hasValue || screenPointOfRef(terminal, ref.ref) == null) return false;
  copyGridRef(ref.ref, out);
  return true;
});

/// A raw `GhosttyGridRef`: a page address and an in-page position. Never
/// dereferenced in Dart; only passed back to the library while current.
typedef _RawRef = ({int node, int x, int y});

_RawRef _rawRef(GhosttyGridRef ref) =>
    (node: ref.node.address, x: ref.x, y: ref.y);

void _writeRawRef(_RawRef raw, GhosttyGridRef out) => out
  ..node = Pointer.fromAddress(raw.node)
  ..x = raw.x
  ..y = raw.y;

/// A **borrowed** range of terminal content between two cells, both
/// included (`GhosttySelection`).
///
/// Make one with [VtTerminalSelection] (`selectRange`, `selectWord`,
/// `selectLine`, `selectAll`, ...), read the terminal's active one with
/// [VtTerminalSelection.selection], or get search matches from
/// `TerminalSearch`.
///
/// ```dart
/// final line = terminal.selectLine(const GridPoint.active(0, 2));
/// if (line != null) {
///   print(formatter.formatText(selection: line));
///   terminal.selection = line;       // highlight it
/// }
/// ```
///
/// **Lifetime:** like a [GridRef], a selection is an untracked snapshot,
/// valid only until the next call that changes its terminal (`write`,
/// `resize`, scrolling, assigning [VtTerminalSelection.selection], ...),
/// and not usable from inside a callback of the terminal. After that its
/// members throw [StateError]; check [isValid] first if unsure. To keep a
/// range across changes, install it as the terminal's
/// [VtTerminalSelection.selection] (the terminal tracks it) or keep its
/// ends as `TrackedGridRef`s and use
/// [VtTerminalSelection.selectTrackedRange].
///
/// Immutable: [adjusted] and [ordered] return new selections. It holds no
/// native memory.
final class VtSelection implements Finalizable {
  VtSelection._(
    this._terminal,
    this._epoch,
    this._start,
    this._end,
    this.isRectangle,
  );

  /// The terminal's handle; also keeps the native terminal alive.
  final NativeHandle<GhosttyTerminalImpl> _terminal;
  final int _epoch;
  final _RawRef _start;
  final _RawRef _end;

  /// Whether this is a rectangular (block) selection: [start] and [end]
  /// are opposite corners of a block of cells. Otherwise the selection is
  /// linear and wraps from the end of one row to the start of the next.
  final bool isRectangle;

  /// Whether this selection can still be used: its terminal is not
  /// disposed, has not changed since the selection was made, and is not
  /// running a callback.
  bool get isValid =>
      !_terminal.isDisposed && _terminal.epoch == _epoch && !_terminal.isInUse;

  /// The cell where the selection starts: where the user pressed. It may
  /// come after [end] (see [order]). Borrowed, with the same lifetime as
  /// this selection.
  GridRef get start => _gridRef(_start);

  /// The cell where the selection ends: where the pointer is now. The end
  /// is what [adjusted] moves. Borrowed, with the same lifetime as this
  /// selection.
  GridRef get end => _gridRef(_end);

  /// The order of [start] and [end] in the terminal.
  SelectionOrder get order => _withNative(sizeOf<UnsignedInt>(), (sel, out) {
    final order = out.cast<UnsignedInt>();
    checkResult(
      ghostty_terminal_selection_order(_terminal.pointer, sel, order),
      'ghostty_terminal_selection_order',
    );
    return selectionOrderCodec.decode(order.value);
  });

  /// This selection with its ends swapped as needed so they run in the
  /// [desired] order: [SelectionOrder.forward] (the default) puts [start]
  /// at the top-left, [SelectionOrder.reverse] at the bottom-right.
  ///
  /// A mirrored [desired] order returns the selection unchanged when it
  /// already has that order, and otherwise acts like
  /// [SelectionOrder.forward] (libghostty-vt 1.0.0).
  ///
  /// Throws [ArgumentError] for [SelectionOrder.unknown].
  VtSelection ordered([SelectionOrder desired = SelectionOrder.forward]) {
    final raw = selectionOrderCodec.encode(desired);
    return _withNative(sizeOf<GhosttySelection>(), (sel, out) {
      final result = out.cast<GhosttySelection>();
      checkResult(
        ghostty_terminal_selection_ordered(_terminal.pointer, sel, raw, result),
        'ghostty_terminal_selection_ordered',
      );
      return selectionFromNative(_terminal, result.ref);
    });
  }

  /// This selection with its [end] moved by [adjustment], using the
  /// terminal's keyboard-selection rules.
  VtSelection adjusted(SelectionAdjustment adjustment) =>
      _withNative(0, (sel, _) {
        checkResult(
          ghostty_terminal_selection_adjust(
            _terminal.pointer,
            sel,
            selectionAdjustmentToRaw(adjustment),
          ),
          'ghostty_terminal_selection_adjust',
        );
        return selectionFromNative(_terminal, sel.ref);
      });

  /// Whether the cell at [point] is inside this selection, with the
  /// terminal's rules for linear and rectangular selections. `false` for a
  /// point outside its coordinate space.
  ///
  /// Throws [ArgumentError] for [PointSpace.unknown].
  bool contains(GridPoint point) {
    final pointBytes = align8(sizeOf<GhosttyPoint>());
    return _withNative(pointBytes + sizeOf<Bool>(), (sel, out) {
      final nativePoint = out.cast<GhosttyPoint>();
      final result = (out + pointBytes).cast<Bool>();
      gridPointToNative(point, nativePoint.ref);
      final code = checkResultAllowing(
        ghostty_terminal_selection_contains(
          _terminal.pointer,
          sel,
          nativePoint.ref,
          result,
        ),
        'ghostty_terminal_selection_contains',
        const {GhosttyResultCode.invalidValue},
      );
      return code == GhosttyResultCode.success && result.value;
    });
  }

  /// Whether [other] selects the same cells of the same terminal state in
  /// the same mode: both ends and [isRectangle] match. This is the
  /// library's selection equality (`ghostty_terminal_selection_equal`),
  /// computed in Dart so it never throws, even for stale selections
  /// (selections from different terminal states are never equal).
  @override
  bool operator ==(Object other) =>
      other is VtSelection &&
      identical(other._terminal, _terminal) &&
      other._epoch == _epoch &&
      other._start == _start &&
      other._end == _end &&
      other.isRectangle == isRectangle;

  @override
  int get hashCode => Object.hash(
    identityHashCode(_terminal),
    _epoch,
    _start,
    _end,
    isRectangle,
  );

  @override
  String toString() =>
      'VtSelection(${isRectangle ? 'rectangle' : 'linear'}, '
      '${isValid ? 'valid' : 'stale'})';

  void _checkValid() {
    if (_terminal.isDisposed) {
      throw StateError(
        'VtSelection is no longer valid: the terminal has been disposed',
      );
    }
    if (_terminal.epoch != _epoch || _terminal.isInUse) {
      throw StateError('VtSelection is no longer valid: the terminal changed');
    }
  }

  GridRef _gridRef(_RawRef raw) {
    _checkValid();
    return withScratch(sizeOf<GhosttyGridRef>(), (block) {
      final ref = block.cast<GhosttyGridRef>();
      _writeRawRef(raw, ref.ref);
      return gridRefFromNative(_terminal, ref.ref);
    });
  }

  /// Runs [action] with a native copy of this selection and [extra] bytes
  /// of zeroed, 8-byte aligned scratch memory after it.
  R _withNative<R>(
    int extra,
    R Function(Pointer<GhosttySelection> selection, Pointer<Uint8> out) action,
  ) {
    _checkValid();
    final selectionBytes = align8(sizeOf<GhosttySelection>());
    return withScratch(selectionBytes + extra, (block) {
      final selection = block.cast<GhosttySelection>();
      _write(selection);
      return action(selection, block + selectionBytes);
    });
  }

  void _write(Pointer<GhosttySelection> out) {
    _writeRawRef(_start, out.ref.start);
    _writeRawRef(_end, out.ref.end);
    out.ref.rectangle = isRectangle;
  }
}

/// Wraps a native `GhosttySelection` that the library made for the
/// terminal behind [terminal].
///
/// The selection is valid while the terminal's epoch is [epoch], by
/// default the current one. Search results pass the epoch of their last
/// feed, since they reflect the terminal as of that feed.
VtSelection selectionFromNative(
  NativeHandle<GhosttyTerminalImpl> terminal,
  GhosttySelection selection, {
  int? epoch,
}) => VtSelection._(
  terminal,
  epoch ?? terminal.epoch,
  _rawRef(selection.start),
  _rawRef(selection.end),
  selection.rectangle,
);

/// Writes [selection] into [out] for a call on the terminal behind
/// [terminal].
///
/// Throws [ArgumentError] (naming [name]) when [selection] belongs to
/// another terminal, and [StateError] when it is stale.
void selectionToNative(
  VtSelection selection,
  NativeHandle<GhosttyTerminalImpl> terminal,
  Pointer<GhosttySelection> out,
  String name,
) {
  if (!identical(selection._terminal, terminal)) {
    throw ArgumentError.value(selection, name, 'belongs to another terminal');
  }
  selection._checkValid();
  selection._write(out);
}
