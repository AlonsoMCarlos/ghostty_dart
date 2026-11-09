/// Key, mouse, focus and paste encoders, and size/mode/colour-scheme reports.
///
/// Stateful encoders ([KeyEncoder], [MouseEncoder]) follow a terminal's
/// modes through `setFromTerminal`; the report and paste functions are
/// stateless.
library;

import 'key_encoder.dart';
import 'mouse_encoder.dart';

export 'encoders.dart'
    show
        encodeColorSchemeReport,
        encodeFocusEvent,
        encodeModeReport,
        encodePaste,
        encodeSizeReport,
        isPasteSafe;
export 'key.dart' show KeyAction, OptionAsAlt, VtKey, VtKeyEvent;
export 'key_encoder.dart' show KeyEncoder;
export 'mouse.dart'
    show
        MouseAction,
        MouseButton,
        MouseEncoderSize,
        MouseFormat,
        MouseTrackingMode,
        VtMouseEvent;
export 'mouse_encoder.dart' show MouseEncoder;
export 'reports.dart'
    show
        ModeReportState,
        SizeReportSize,
        SizeReportStyle,
        VtColorScheme,
        VtFocusEvent;
