// Ported from package:xterm 4.0.0 (lib/src/ui/controller.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.
// Changed: while a TerminalView shows it, the controller mirrors the
// view's terminal: setSelection, setSelectionMode and clearSelection
// change libghostty-vt's selection, `selection` reads it (so selections
// made with the mouse show here), and highlights are painted by
// ghostty_dart_flutter over the text and the selection (ADR 0013).

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:ghostty_dart/ghostty_dart.dart'
    show GridPoint, PointSpace, VtTerminalSelection;
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart'
    show VtTerminalController, VtTerminalHighlight;

import '../base/disposable.dart';
import '../core/buffer/cell_offset.dart';
import '../core/buffer/line.dart';
import '../core/buffer/range.dart';
import '../core/buffer/range_block.dart';
import '../core/buffer/range_line.dart';
import 'controller_binding.dart';
import 'pointer_input.dart';
import 'selection_mode.dart';

/// The selection, highlights and pointer settings of a `TerminalView`.
///
/// Create one and pass it to `TerminalView.controller` to read or change
/// the selection, highlight ranges, or choose which pointer events reach
/// the program; listen to it to learn when the selection changes. Dispose
/// it when done (a view disposes only the controller it created itself).
///
/// ```dart
/// final controller = TerminalController();
/// // TerminalView(terminal, controller: controller)
/// final range = controller.selection;
/// if (range != null) print(terminal.buffer.getText(range));
/// ```
///
/// While a `TerminalView` shows it, [selection] is the selection on the
/// screen, including the one the user makes with the mouse, and
/// [setSelection], [setSelectionMode] and [clearSelection] change it.
/// Use one controller per view.
class TerminalController with ChangeNotifier {
  /// A controller with the given selection mode and pointer settings.
  TerminalController({
    SelectionMode selectionMode = SelectionMode.line,
    PointerInputs pointerInputs = const PointerInputs({PointerInput.tap}),
    bool suspendPointerInput = false,
  }) : _selectionMode = selectionMode,
       _pointerInputs = pointerInputs,
       _suspendPointerInputs = suspendPointerInput {
    bindTerminalController(this, _Binding(this));
  }

  CellAnchor? _selectionBase;
  CellAnchor? _selectionExtent;

  /// How selections cover cells: running text ([SelectionMode.line], the
  /// default) or a rectangle ([SelectionMode.block]). A view also makes a
  /// plain mouse drag select a rectangle in [SelectionMode.block].
  SelectionMode get selectionMode => _selectionMode;
  SelectionMode _selectionMode;

  /// The set of pointer events which will be used as mouse input for the terminal.
  PointerInputs get pointerInput => _pointerInputs;
  PointerInputs _pointerInputs;

  /// True if sending pointer events to the terminal is suspended.
  bool get suspendedPointerInputs => _suspendPointerInputs;
  bool _suspendPointerInputs;

  /// The live highlights, in creation order (see [highlight]).
  List<TerminalHighlight> get highlights => _highlights;
  final _highlights = <TerminalHighlight>[];

  // The engine of the terminal of the view that shows this controller.
  VtTerminalController? _vt;

  // Whether the selection on the screen is the one [setSelection] made
  // from [_selectionBase] and [_selectionExtent]; false once the user (or
  // anything else) changed it.
  bool _anchorSelection = false;

  // The screen selection last seen, to notice changes made elsewhere.
  _ScreenSelection? _lastSeen;

  // Set while this controller changes the engine's selection.
  bool _changingEngine = false;

  final _nativeHighlights = <TerminalHighlight, VtTerminalHighlight>{};

  /// The selected range, or `null` when nothing is selected (or the
  /// anchors of the selection left the buffer). Its end is exclusive, as
  /// in xterm: a selection of one cell at (x, y) ends at (x + 1, y).
  BufferRange? get selection {
    final vt = _liveEngine;
    if (vt != null && !_anchorSelection) {
      final current = _readScreenSelection(vt);
      if (current == null) return null;
      final begin = CellOffset(current.start.x, current.start.y);
      final end = CellOffset(current.end.x + 1, current.end.y);
      return current.rectangle
          ? BufferRangeBlock(begin, end)
          : BufferRangeLine(begin, end);
    }

    final base = _selectionBase;
    final extent = _selectionExtent;

    if (base == null || extent == null) {
      return null;
    }

    if (!base.attached || !extent.attached) {
      return null;
    }

    return _createRange(base.offset, extent.offset);
  }

  /// Set selection on the terminal from [base] to [extent]. This method takes
  /// the ownership of [base] and [extent] and will dispose them when the
  /// selection is cleared or changed.
  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    _selectionBase?.dispose();
    _selectionBase = base;

    _selectionExtent?.dispose();
    _selectionExtent = extent;

    if (mode != null) {
      _selectionMode = mode;
    }

    _pushAnchorSelection();
    notifyListeners();
  }

  BufferRange _createRange(CellOffset begin, CellOffset end) {
    switch (selectionMode) {
      case SelectionMode.line:
        return BufferRangeLine(begin, end);
      case SelectionMode.block:
        return BufferRangeBlock(begin, end);
    }
  }

  /// Controls how the terminal behaves when the user selects a range of text.
  /// The default is [SelectionMode.line]. Setting this to [SelectionMode.block]
  /// enables block selection mode.
  void setSelectionMode(SelectionMode newSelectionMode) {
    // If the new mode is the same as the old mode,
    // nothing has to be changed.
    if (_selectionMode == newSelectionMode) {
      return;
    }
    // Set the new mode.
    _selectionMode = newSelectionMode;
    if (_anchorSelection) {
      _pushAnchorSelection();
    } else {
      _reshapeScreenSelection();
    }
    notifyListeners();
  }

  /// Clears the current selection.
  void clearSelection() {
    _selectionBase?.dispose();
    _selectionBase = null;
    _selectionExtent?.dispose();
    _selectionExtent = null;
    _anchorSelection = false;
    final vt = _liveEngine;
    if (vt != null) _changeEngine(vt, vt.clearSelection);
    notifyListeners();
  }

  /// Selects which pointer events are reported to the program while it
  /// tracks the mouse.
  void setPointerInputs(PointerInputs pointerInput) {
    _pointerInputs = pointerInput;
    notifyListeners();
  }

  /// Turns reporting pointer events to the program off (`true`) or back on.
  void setSuspendPointerInput(bool suspend) {
    _suspendPointerInputs = suspend;
    notifyListeners();
  }

  /// Whether [pointerInput] events are reported to the program: they are
  /// in the controller's [PointerInputs] and reporting is not suspended.
  @internal
  bool shouldSendPointerInput(PointerInput pointerInput) {
    // Always return false if pointer input is suspended.
    return _suspendPointerInputs
        ? false
        : _pointerInputs.inputs.contains(pointerInput);
  }

  /// Creates a new highlight on the terminal from [p1] to [p2] with the given
  /// [color]. The highlight will be removed when the returned object is
  /// disposed.
  ///
  /// [p2] is exclusive, as a selection's end. A view paints highlights
  /// over the text and over the selection (xterm paints the selection
  /// last).
  TerminalHighlight highlight({
    required CellAnchor p1,
    required CellAnchor p2,
    required Color color,
  }) {
    final highlight = TerminalHighlight(this, p1: p1, p2: p2, color: color);

    _highlights.add(highlight);
    _addNativeHighlight(highlight);
    notifyListeners();

    highlight.registerCallback(() {
      _highlights.remove(highlight);
      _nativeHighlights.remove(highlight)?.dispose();
      notifyListeners();
    });

    return highlight;
  }

  @override
  void dispose() {
    final vt = _vt;
    if (vt != null) _detach(vt);
    super.dispose();
  }

  /* Engine binding (TerminalView) */

  VtTerminalController? get _liveEngine {
    final vt = _vt;
    return vt == null || vt.isDisposed ? null : vt;
  }

  void _attach(VtTerminalController vt) {
    if (identical(_vt, vt)) return;
    final old = _vt;
    if (old != null) _detach(old);
    _vt = vt;
    if (vt.isDisposed) return;
    vt.addListener(_onEngineChanged);
    if (_selectionBase != null && _selectionExtent != null) {
      _pushAnchorSelection();
    } else {
      _anchorSelection = false;
      _lastSeen = _readScreenSelection(vt);
    }
    for (final highlight in _highlights) {
      _addNativeHighlight(highlight);
    }
  }

  void _detach(VtTerminalController vt) {
    if (!identical(_vt, vt)) return;
    vt.removeListener(_onEngineChanged);
    for (final native in _nativeHighlights.values) {
      native.dispose();
    }
    _nativeHighlights.clear();
    _vt = null;
    _anchorSelection = false;
    _lastSeen = null;
  }

  void _onEngineChanged() {
    if (_changingEngine) return;
    final vt = _liveEngine;
    if (vt == null) return;
    final current = _readScreenSelection(vt);
    if (current == _lastSeen) return;
    _lastSeen = current;
    if (_anchorSelection) {
      // Someone else replaced the selection (the user, select all): it
      // is no longer the one the anchors describe.
      _anchorSelection = false;
      _selectionBase?.dispose();
      _selectionBase = null;
      _selectionExtent?.dispose();
      _selectionExtent = null;
    }
    notifyListeners();
  }

  /// Runs [change] on [vt] without treating its notification as an
  /// outside change, then records the resulting selection.
  void _changeEngine(VtTerminalController vt, void Function() change) {
    _changingEngine = true;
    try {
      change();
    } finally {
      _changingEngine = false;
    }
    _lastSeen = _readScreenSelection(vt);
  }

  /// Shows the anchors' selection on the bound terminal.
  void _pushAnchorSelection() {
    final vt = _liveEngine;
    if (vt == null) return;
    _anchorSelection = true;
    final base = _selectionBase;
    final extent = _selectionExtent;
    final cells = base != null && extent != null && base.attached
        ? extent.attached
              ? _inclusiveCells(
                  _createRange(base.offset, extent.offset),
                  vt.cols,
                )
              : null
        : null;
    _changeEngine(vt, () {
      vt.selection = cells == null
          ? null
          : vt.terminal.selectRange(
              GridPoint.screen(cells.$1.x, cells.$1.y),
              GridPoint.screen(cells.$2.x, cells.$2.y),
              rectangle: selectionMode == SelectionMode.block,
            );
    });
  }

  /// Re-selects the screen selection in the current [selectionMode].
  void _reshapeScreenSelection() {
    final vt = _liveEngine;
    if (vt == null) return;
    final current = _readScreenSelection(vt);
    final rectangle = selectionMode == SelectionMode.block;
    if (current == null || current.rectangle == rectangle) return;
    _changeEngine(vt, () {
      vt.selection = vt.terminal.selectRange(
        current.start,
        current.end,
        rectangle: rectangle,
      );
    });
  }

  void _addNativeHighlight(TerminalHighlight highlight) {
    final vt = _liveEngine;
    if (vt == null || _nativeHighlights.containsKey(highlight)) return;
    if (!highlight.p1.attached || !highlight.p2.attached) return;
    final cells = _inclusiveCells(
      BufferRangeLine(highlight.p1.offset, highlight.p2.offset),
      vt.cols,
    );
    // An empty range paints nothing, as in xterm.
    if (cells == null) return;
    try {
      _changeEngine(vt, () {
        _nativeHighlights[highlight] = vt.addHighlight(
          GridPoint.screen(cells.$1.x, cells.$1.y),
          GridPoint.screen(cells.$2.x, cells.$2.y),
          color: highlight.color,
        );
      });
    } on RangeError {
      // The range is outside the terminal's screen (for example anchors of
      // another terminal); there is nothing to paint.
    }
  }
}

/// The first and last cell (both inclusive) of xterm's [range], whose end
/// is exclusive, on a screen [cols] wide; `null` for an empty range.
(CellOffset, CellOffset)? _inclusiveCells(BufferRange range, int cols) {
  final normalized = range.normalized;
  final begin = normalized.begin;
  final end = normalized.end;
  if (cols <= 0) return null;
  if (normalized is BufferRangeBlock) {
    final left = begin.x < end.x ? begin.x : end.x;
    final right = (begin.x < end.x ? end.x : begin.x).clamp(0, cols);
    if (right <= left) return null;
    final top = begin.y < end.y ? begin.y : end.y;
    final bottom = begin.y < end.y ? end.y : begin.y;
    return (CellOffset(left, top), CellOffset(right - 1, bottom));
  }
  if (!begin.isBefore(end)) return null;
  final last = end.x > 0
      ? CellOffset(end.x.clamp(1, cols) - 1, end.y)
      : CellOffset(cols - 1, end.y - 1);
  final first = CellOffset(begin.x.clamp(0, cols - 1), begin.y);
  if (last.isBefore(first)) return null;
  return (first, last);
}

/// A selection on the screen: its first and last cell (screen space,
/// in line order) and whether it is a rectangle.
@immutable
final class _ScreenSelection {
  const _ScreenSelection(this.start, this.end, this.rectangle);

  final GridPoint start;
  final GridPoint end;
  final bool rectangle;

  @override
  bool operator ==(Object other) =>
      other is _ScreenSelection &&
      other.start == start &&
      other.end == end &&
      other.rectangle == rectangle;

  @override
  int get hashCode => Object.hash(start, end, rectangle);
}

_ScreenSelection? _readScreenSelection(VtTerminalController vt) {
  try {
    final current = vt.selection?.ordered();
    if (current == null) return null;
    final start = current.start.pointIn(PointSpace.screen);
    final end = current.end.pointIn(PointSpace.screen);
    if (start == null || end == null) return null;
    return _ScreenSelection(start, end, current.isRectangle);
  } on StateError {
    // Read from inside a terminal callback: nothing reliable to report.
    return null;
  }
}

final class _Binding implements TerminalControllerBinding {
  _Binding(this._controller);

  final TerminalController _controller;

  @override
  void attach(VtTerminalController vt) => _controller._attach(vt);

  @override
  void detach(VtTerminalController vt) => _controller._detach(vt);
}

/// A coloured range of a terminal, made by [TerminalController.highlight];
/// [dispose] removes it.
class TerminalHighlight with Disposable {
  /// The controller that made this highlight.
  final TerminalController owner;

  /// The first cell.
  final CellAnchor p1;

  /// The end, exclusive.
  final CellAnchor p2;

  /// The colour painted over the range (its alpha is kept).
  final Color color;

  /// A highlight of [owner] from [p1] to [p2]; use
  /// [TerminalController.highlight], which also shows it.
  TerminalHighlight(
    this.owner, {
    required this.p1,
    required this.p2,
    required this.color,
  });

  /// Returns the range of the highlight. May be null if the anchors that
  /// define the highlight are not attached to the terminal.
  BufferRange? get range {
    if (!p1.attached || !p2.attached) {
      return null;
    }
    return BufferRangeLine(p1.offset, p2.offset);
  }
}
