/// Grid references: random access to any cell or row of a terminal,
/// anywhere in the scrollback, and tracked references that follow a cell
/// as the terminal changes.
///
/// Start with [VtTerminalGrid.gridRef] for a borrowed [GridRef] (read its
/// [GridRef.cell], [GridRef.row], [GridRef.style], [GridRef.text] or
/// [GridRef.hyperlinkUri]) or [VtTerminalGrid.trackGridRef] for an owned
/// [TrackedGridRef].
library;

import 'grid_ref.dart';
import 'tracked_grid_ref.dart';

export 'grid_enums.dart' show RowSemanticPrompt;
export 'grid_ref.dart' show GridRef, VtTerminalGrid;
export 'grid_values.dart' show GridCell, GridRow;
export 'tracked_grid_ref.dart' show TrackedGridRef;
