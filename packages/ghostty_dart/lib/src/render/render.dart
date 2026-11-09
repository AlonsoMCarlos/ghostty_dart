/// Render state: dirty rows, cells, styles, cursor, colours and image
/// placements, for renderers that draw the terminal themselves.
///
/// Start with [RenderState]: update it from a `VtTerminal` once per frame,
/// iterate its [RenderState.dirtyRows], draw, then [RenderState.markClean].
library;

import 'render_state.dart';

export 'render_enums.dart'
    show
        CellSemanticContent,
        CellWidth,
        ImageLayer,
        ImageProtocol,
        KittyPlacementKind,
        RenderDirtyState;
export 'render_state.dart' show RenderRow, RenderState;
export 'render_values.dart'
    show
        RenderCell,
        RenderColors,
        RenderCursor,
        RenderImagePlacement,
        RenderOverscan,
        RenderRowId;
