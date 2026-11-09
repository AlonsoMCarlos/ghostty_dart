/// Standalone OSC and SGR parsers, for escape sequences handled outside a
/// terminal (`osc.h`, `sgr.h`). A `VtTerminal` parses both by itself.
library;

export 'osc_command.dart'
    show
        OscCommand,
        OscCommandType,
        OscOtherCommand,
        OscTerminator,
        OscUnimplementedCommand,
        OscWindowTitleCommand;
export 'osc_parser.dart' show OscParser;
export 'sgr_attribute.dart'
    show
        SgrAttribute,
        SgrBackground,
        SgrColorAttribute,
        SgrColorForm,
        SgrFlag,
        SgrFlagKind,
        SgrForeground,
        SgrReset,
        SgrUnderline,
        SgrUnderlineColor,
        SgrUnrecognized;
export 'sgr_parser.dart' show SgrParser, SgrSeparator;
