/// Formatting terminal content as plain text, VT sequences or HTML.
///
/// Create a [TerminalFormatter] for a terminal and call
/// [TerminalFormatter.formatText] or [TerminalFormatter.formatBytes], for
/// the whole screen or for a selection.
library;

import 'terminal_formatter.dart';

export 'terminal_formatter.dart' show TerminalFormatter;
export 'text_format.dart' show FormatterExtras, TextFormat;
