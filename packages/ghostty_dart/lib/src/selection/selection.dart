/// Selections and selection gestures.
///
/// A [VtSelection] is a borrowed range of cells. Make one with the
/// [VtTerminalSelection] extension (`selectRange`, `selectWord`,
/// `selectLine`, `selectAll`, `selectOutput`), turn pointer events into
/// selections with a [SelectionGesture], and highlight one by assigning it
/// to [VtTerminalSelection.selection].
library;

import 'selection_gesture.dart';
import 'vt_selection.dart';

export 'selection_enums.dart'
    show
        SelectionAdjustment,
        SelectionAutoscroll,
        SelectionGestureBehavior,
        SelectionOrder;
export 'selection_gesture.dart' show SelectionGesture;
export 'selection_values.dart'
    show SelectionGestureBehaviors, SelectionGestureGeometry;
export 'vt_selection.dart' show VtSelection, VtTerminalSelection;
