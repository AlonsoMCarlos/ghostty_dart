/// Searching terminal content.
///
/// Create a [TerminalSearch] for a terminal, set its
/// [TerminalSearch.needle], then [TerminalSearch.run] it (or drive it with
/// [TerminalSearch.step]) and read its matches.
library;

import 'terminal_search.dart';

export 'search_enums.dart' show SearchScroll, SearchStatus;
export 'terminal_search.dart' show TerminalSearch;
