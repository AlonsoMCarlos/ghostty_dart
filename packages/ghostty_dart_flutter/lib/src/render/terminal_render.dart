import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../seams/terminal_geometry.dart';
import '../seams/terminal_seams.dart';

/// The terminal grid renderer (ADR 0011): one repaint-isolated render box
/// that draws the rows of [source] with a cached picture per row, the
/// cursor and the selection, inside [geometry]. Never exported.
///
/// Not implemented yet: it sizes itself and paints nothing.
class TerminalRenderWidget extends LeafRenderObjectWidget {
  /// A renderer for [source] laid out by [geometry], drawing with
  /// [textStyle]'s font. [focused] selects the focused cursor style.
  const TerminalRenderWidget({
    super.key,
    required this.source,
    required this.geometry,
    required this.textStyle,
    required this.focused,
    this.hideCursor = false,
  });

  /// Where the frames come from.
  final TerminalFrameSource source;

  /// Where the grid is and how big its cells are.
  final TerminalGeometry geometry;

  /// The font of the grid; [geometry]'s metrics were measured with it.
  final TextStyle textStyle;

  /// Whether the view has keyboard focus.
  final bool focused;

  /// Whether to hide the cursor, e.g. while the input layer shows IME
  /// composing text at the cursor.
  final bool hideCursor;

  @override
  RenderTerminal createRenderObject(BuildContext context) => RenderTerminal(
    source: source,
    geometry: geometry,
    textStyle: textStyle,
    focused: focused,
    hideCursor: hideCursor,
  );

  @override
  void updateRenderObject(BuildContext context, RenderTerminal renderObject) {
    renderObject
      ..source = source
      ..geometry = geometry
      ..textStyle = textStyle
      ..focused = focused
      ..hideCursor = hideCursor;
  }
}

/// The render box behind [TerminalRenderWidget].
class RenderTerminal extends RenderBox {
  /// Creates the render box; see [TerminalRenderWidget].
  RenderTerminal({
    required TerminalFrameSource source,
    required TerminalGeometry geometry,
    required TextStyle textStyle,
    required bool focused,
    bool hideCursor = false,
  }) : _source = source,
       _geometry = geometry,
       _textStyle = textStyle,
       _focused = focused,
       _hideCursor = hideCursor;

  TerminalFrameSource _source;
  TerminalGeometry _geometry;
  TextStyle _textStyle;
  bool _focused;
  bool _hideCursor;

  /// See [TerminalRenderWidget.source].
  TerminalFrameSource get source => _source;
  set source(TerminalFrameSource value) {
    if (identical(value, _source)) return;
    if (attached) _source.removeListener(markNeedsPaint);
    _source = value;
    if (attached) _source.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.geometry].
  TerminalGeometry get geometry => _geometry;
  set geometry(TerminalGeometry value) {
    if (value == _geometry) return;
    _geometry = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.textStyle].
  TextStyle get textStyle => _textStyle;
  set textStyle(TextStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.focused].
  bool get focused => _focused;
  set focused(bool value) {
    if (value == _focused) return;
    _focused = value;
    markNeedsPaint();
  }

  /// See [TerminalRenderWidget.hideCursor].
  bool get hideCursor => _hideCursor;
  set hideCursor(bool value) {
    if (value == _hideCursor) return;
    _hideCursor = value;
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _source.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _source.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {}
}
