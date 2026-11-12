/// A Flutter terminal widget on top of `ghostty_dart`, the Dart bindings
/// for libghostty-vt (Ghostty's terminal emulation engine).
///
/// - [VtTerminalController] owns the terminal: feed it the program's
///   output and forward [VtTerminalController.onOutput] to the program's
///   input (it is pty-agnostic).
/// - [VtTerminalView] draws it and takes keyboard, IME, mouse and touch
///   input.
/// - [VtTerminalTheme] sets its colours; [VtCellMetrics] is the measured,
///   device-pixel-aligned cell size; [VtTextRendering] picks how grid text
///   is drawn (a glyph atlas by default).
///
/// ```dart
/// final controller = VtTerminalController(onOutput: pty.write);
/// pty.output.listen(controller.writeBytes);
///
/// Widget build(BuildContext context) =>
///     VtTerminalView(controller: controller, autofocus: true);
/// ```
///
/// Types such as `VtKeyEvent`, `PasteResult` or `ViewportScroll` come from
/// `package:ghostty_dart/ghostty_dart.dart`.
library;

export 'src/controller/terminal_controller.dart'
    show
        VtTerminalController,
        VtTerminalHighlight,
        VtTerminalOutputCallback,
        VtTerminalResizeCallback;
export 'src/input/input_hooks.dart'
    show
        VtTerminalKeyHook,
        VtTerminalMouseFilter,
        VtTerminalMouseHook,
        VtTerminalTextHook;
export 'src/input/keyboard/key_toolbar.dart' show VtTerminalKeyToolbar;
export 'src/metrics/cell_metrics.dart' show VtCellMetrics;
export 'src/render/text_rendering.dart' show VtTextRendering;
export 'src/theme/terminal_theme.dart' show VtTerminalTheme;
export 'src/view/flood_pacing.dart' show VtFloodPacing;
export 'src/view/terminal_view.dart' show VtTerminalView, VtTerminalViewState;
