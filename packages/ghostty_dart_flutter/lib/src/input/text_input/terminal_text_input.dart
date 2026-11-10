import 'package:flutter/services.dart';

import 'sentinel_editor.dart';

/// The text input configuration of a terminal (ADR 0011, Input). Never
/// exported.
///
/// Autocorrect, suggestions, personalised learning, smart dashes and
/// quotes and capitalisation are off: a shell command is not prose. The
/// delta model is on. [keyboardType] defaults to
/// [TextInputType.visiblePassword] on Android (the closest Flutter has to
/// Termux's `TYPE_NULL`: no suggestion strip; research
/// `docs/internal/research/2026-11-09-flutter-input.md` §3) and [TextInputType.text]
/// elsewhere. [obscureText] is set while the program reads a password, so
/// the IME neither shows nor learns it.
TextInputConfiguration terminalTextInputConfiguration({
  required int? viewId,
  required TargetPlatform platform,
  TextInputType? keyboardType,
  Brightness keyboardAppearance = Brightness.light,
  bool obscureText = false,
}) => TextInputConfiguration(
  viewId: viewId,
  inputType:
      keyboardType ??
      (platform == TargetPlatform.android
          ? TextInputType.visiblePassword
          : TextInputType.text),
  obscureText: obscureText,
  autocorrect: false,
  enableSuggestions: false,
  enableIMEPersonalizedLearning: false,
  enableInlinePrediction: false,
  smartDashesType: SmartDashesType.disabled,
  smartQuotesType: SmartQuotesType.disabled,
  textCapitalization: TextCapitalization.none,
  inputAction: TextInputAction.newline,
  keyboardAppearance: keyboardAppearance,
  enableInteractiveSelection: false,
  enableDeltaModel: true,
);

/// The terminal's connection to the platform text input: soft keyboards,
/// IMEs, dead keys and the emoji picker (ADR 0011, Input). Never exported.
///
/// A [DeltaTextInputClient] over a [SentinelEditor]: committed text and
/// deletions are reported through [onEdit], the preedit through
/// [onComposing], action keys (Enter on a soft keyboard) through
/// [onAction], and the end of every platform update through [onUpdate].
/// Never exported.
final class TerminalTextInput with TextInputClient, DeltaTextInputClient {
  /// A client reporting to the given callbacks; [sentinel] is the idle
  /// text (see [SentinelEditor]).
  TerminalTextInput({
    required this.onEdit,
    required this.onComposing,
    required this.onAction,
    this.onUpdate,
    String sentinel = deleteDetectionSentinel,
  }) : editor = SentinelEditor(sentinel: sentinel);

  /// Called with what to send after each editing update.
  final ValueChanged<SentinelEdit> onEdit;

  /// Called with the preedit text whenever it changes (`''` when the IME
  /// stops composing).
  final ValueChanged<String> onComposing;

  /// Called for an IME action (Enter on a soft keyboard), and for the
  /// macOS `insertNewline:` selector.
  final ValueChanged<TextInputAction> onAction;

  /// Called after each editing update from the platform, once its edits
  /// and preedit change were reported (also when it changed nothing).
  final VoidCallback? onUpdate;

  /// The hidden editing state.
  final SentinelEditor editor;

  TextInputConnection? _connection;
  String _composing = '';

  /// Whether a connection is open.
  bool get isAttached => _connection?.attached ?? false;

  /// The connection, while [isAttached].
  TextInputConnection? get connection => isAttached ? _connection : null;

  /// The current preedit text, or `''`.
  String get composingText => _composing;

  /// Opens a connection with [configuration] (if none is open), resets the
  /// editing state to the sentinel and shows the keyboard.
  void attach(TextInputConfiguration configuration) {
    if (!isAttached) {
      _connection = TextInput.attach(this, configuration);
      editor.reset();
      _connection!.setEditingState(editor.value);
    }
    _connection!.show();
  }

  /// Shows the soft keyboard again (after the user dismissed it).
  void show() => connection?.show();

  /// Closes the connection, dropping any preedit. With [notify] `false`
  /// (while the owner is being disposed) the preedit is dropped silently.
  void detach({bool notify = true}) {
    if (isAttached) _connection!.close();
    _connection = null;
    if (notify) {
      _setComposing('');
    } else {
      _composing = '';
    }
  }

  @override
  TextEditingValue? get currentTextEditingValue => editor.value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) =>
      _settle(editor.applyDeltas(textEditingDeltas));

  @override
  void updateEditingValue(TextEditingValue value) =>
      _settle([editor.update(value)]);

  void _settle(List<SentinelEdit> edits) {
    if (editor.needsReset) {
      editor.reset();
      connection?.setEditingState(editor.value);
    }
    for (final edit in edits) {
      if (!edit.isEmpty) onEdit(edit);
    }
    _setComposing(editor.composingText);
    onUpdate?.call();
  }

  void _setComposing(String text) {
    if (text == _composing) return;
    _composing = text;
    onComposing(text);
  }

  @override
  void performAction(TextInputAction action) => onAction(action);

  /// macOS sends editing selectors for keys the framework left to the
  /// platform. As Ghostty does (`doCommand(by:)` in
  /// `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`, read
  /// 2026-11-10, sends the event back to be encoded), they become key
  /// events through the encoder, never text: Backspace and Enter.
  @override
  void performSelector(String selectorName) {
    switch (selectorName) {
      case 'deleteBackward:':
        onEdit(const SentinelEdit(backspaces: 1));
      case 'insertNewline:':
        onAction(TextInputAction.newline);
    }
  }

  // A terminal has no private IME commands, no caret to drag and no
  // autocorrection, so these three are no-ops.

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    // The platform closed it (the keyboard was dismissed for good, or
    // another client took over).
    _connection = null;
    editor.reset();
    _setComposing('');
  }
}
