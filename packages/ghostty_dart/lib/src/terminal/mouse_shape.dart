/// The mouse pointer shape a program asks for (`GhosttyMouseShape`).
library;

import '../core/enum_codec.dart';

/// A mouse pointer shape requested by the running program with OSC 22
/// (`GhosttyMouseShape`), named after the W3C CSS cursor names.
///
/// Read it with `VtTerminal.mouseShape` and map it to your platform's
/// pointer; not every platform has every shape. These are pointer shapes,
/// not the terminal's text cursor (see `VtCursorStyle`).
enum MouseShape {
  /// The platform's default pointer (CSS `default`).
  defaultShape(0),

  /// A context menu is available (CSS `context-menu`).
  contextMenu(1),

  /// Help is available (CSS `help`).
  help(2),

  /// A link or clickable item (CSS `pointer`).
  pointer(3),

  /// Busy in the background, still interactive (CSS `progress`).
  progress(4),

  /// Busy, not interactive (CSS `wait`).
  wait(5),

  /// A cell or set of cells can be selected (CSS `cell`).
  cell(6),

  /// A crosshair (CSS `crosshair`).
  crosshair(7),

  /// Text can be selected (CSS `text`); the initial shape.
  text(8),

  /// Vertical text can be selected (CSS `vertical-text`).
  verticalText(9),

  /// An alias or shortcut will be created (CSS `alias`).
  alias(10),

  /// Something will be copied (CSS `copy`).
  copy(11),

  /// Something will be moved (CSS `move`).
  move(12),

  /// The dragged item cannot be dropped here (CSS `no-drop`).
  noDrop(13),

  /// The action is not allowed (CSS `not-allowed`).
  notAllowed(14),

  /// Something can be grabbed (CSS `grab`).
  grab(15),

  /// Something is being grabbed (CSS `grabbing`).
  grabbing(16),

  /// Scrolling in any direction (CSS `all-scroll`).
  allScroll(17),

  /// A column can be resized horizontally (CSS `col-resize`).
  colResize(18),

  /// A row can be resized vertically (CSS `row-resize`).
  rowResize(19),

  /// An edge can be moved north (CSS `n-resize`).
  nResize(20),

  /// An edge can be moved east (CSS `e-resize`).
  eResize(21),

  /// An edge can be moved south (CSS `s-resize`).
  sResize(22),

  /// An edge can be moved west (CSS `w-resize`).
  wResize(23),

  /// An edge can be moved north-east (CSS `ne-resize`).
  neResize(24),

  /// An edge can be moved north-west (CSS `nw-resize`).
  nwResize(25),

  /// An edge can be moved south-east (CSS `se-resize`).
  seResize(26),

  /// An edge can be moved south-west (CSS `sw-resize`).
  swResize(27),

  /// Bidirectional east-west resize (CSS `ew-resize`).
  ewResize(28),

  /// Bidirectional north-south resize (CSS `ns-resize`).
  nsResize(29),

  /// Bidirectional north-east/south-west resize (CSS `nesw-resize`).
  neswResize(30),

  /// Bidirectional north-west/south-east resize (CSS `nwse-resize`).
  nwseResize(31),

  /// Something can be zoomed in (CSS `zoom-in`).
  zoomIn(32),

  /// Something can be zoomed out (CSS `zoom-out`).
  zoomOut(33),

  /// A shape added by a later libghostty-vt release. Show [defaultShape].
  unknown(null);

  const MouseShape(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyMouseShape` values to [MouseShape] and back.
final mouseShapeCodec = RawEnumCodec<MouseShape>(
  MouseShape.values,
  raw: (shape) => shape._raw,
  unknown: MouseShape.unknown,
);
