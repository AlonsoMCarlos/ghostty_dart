/// The counterpart of `package:xterm/suggestion.dart`: an overlay placed
/// at the terminal's cursor, for command suggestions and completions
/// (`SuggestionPortal`, `SuggestionPortalController`).
///
/// Place the popup with the view's cursor rectangle:
///
/// ```dart
/// final viewKey = GlobalKey<TerminalViewState>();
/// // TerminalView(terminal, key: viewKey)
/// suggestionController.update(viewKey.currentState!.globalCursorRect);
/// ```
library;

export 'src/suggestion/suggestion.dart';
