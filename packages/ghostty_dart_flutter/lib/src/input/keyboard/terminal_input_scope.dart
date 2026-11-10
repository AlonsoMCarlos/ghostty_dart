import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../../seams/terminal_geometry.dart';
import '../../seams/terminal_seams.dart';
import '../text_input/composing_overlay.dart';
import '../text_input/sentinel_editor.dart';
import '../text_input/terminal_text_input.dart';
import 'key_event_mapper.dart';
import 'physical_key_map.dart';
import 'terminal_shortcuts.dart';

/// Keyboard and text input for the view (ADR 0011): hardware keys through
/// the key encoder, the IME and soft keyboards through a delta text input
/// client, shortcuts that never steal shell keys, and the IME composing
/// overlay. Never exported.
///
/// **Who handles a key.** For each key event, in order:
/// 1. [onKeyEvent]; anything but [KeyEventResult.ignored] is final.
/// 2. The shortcut map ([shortcuts], or [defaultTerminalShortcuts]): an
///    enabled action runs and the key is handled.
/// 3. The release of a key whose press was encoded, and every modifier
///    key, goes to the encoder (even while the IME composes).
/// 4. While the IME composes, every other key goes to the IME.
/// 5. With a text input connection open, and unless the program enabled
///    Kitty "report event types" (2) or "report all keys" (8), a
///    writing-system key or Space without Ctrl, Alt or Super (after the
///    AltGr and Option rules) is left to the platform text input, as
///    `EditableText` does, so IMEs, dead keys and compose sequences work.
///    Its text arrives as committed text (ADR 0011, 2026-11-10 amendment).
/// 6. Every other key goes to [keys] as a [VtKeyEvent]. The key is
///    [KeyEventResult.handled] when the encoder produced bytes, and always
///    for Tab, Esc, Enter, Space and the arrows (so Flutter's traversal and
///    activation shortcuts never see them); otherwise it is ignored, so Cmd
///    shortcuts, media and volume keys reach the platform.
///
/// **Order.** A key left to the platform answers asynchronously (the Linux
/// and Android embedders do not serialise key events). Until its text
/// arrives, encoded keys, committed text and pastes wait in a queue, so
/// `l`, `s`, Enter always reach the program in that order. If no text
/// arrives within [commitTimeout] (a dead key, an IME that swallowed the
/// key) or the IME starts composing, the queue moves on.
///
/// [readOnly] sends nothing (no keys, text, pastes or focus reports) but
/// still copies. [hardwareKeyboardOnly] opens no text input connection:
/// no soft keyboard and no IME, and printable keys are encoded with their
/// text directly.
class TerminalInputScope extends StatefulWidget {
  /// Input for [child], sending keys to [keys] and text to [text].
  const TerminalInputScope({
    super.key,
    required this.keys,
    required this.text,
    required this.geometry,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.shortcuts,
    this.onKeyEvent,
    this.textStyle,
    this.onComposingChanged,
    this.keyboardType,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = true,
    this.onUnsafePaste,
    this.composingBackgroundColor,
    this.composingBackground,
    this.kittyKeyboardFlags,
    this.macosOptionAsAlt,
    required this.child,
  });

  /// How long a key left to the platform text input may hold back the keys
  /// after it while its text has not arrived: 100 ms, several frames plus
  /// an IME round trip over D-Bus.
  static const commitTimeout = Duration(milliseconds: 100);

  /// Where encoded keys go.
  final TerminalKeySink keys;

  /// Where committed text, pastes and focus reports go.
  final TerminalTextSink text;

  /// Where the grid is, for the IME caret and composing rectangles.
  final TerminalGeometry geometry;

  /// The view's focus node.
  final FocusNode focusNode;

  /// Whether to request focus when first built.
  final bool autofocus;

  /// Whether to ignore input.
  final bool readOnly;

  /// Whether to use hardware keys only (no text input connection).
  final bool hardwareKeyboardOnly;

  /// The shortcut map, replacing the default policy (which never takes
  /// Ctrl+V or Ctrl+A from the shell). `null` uses the default. The xterm
  /// adapter passes xterm's map here.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Sees every key event before the terminal does; returning
  /// [KeyEventResult.handled] or [KeyEventResult.skipRemainingHandlers]
  /// stops the terminal from encoding it (xterm's `onKeyEvent`).
  final FocusOnKeyEventCallback? onKeyEvent;

  /// The grid font, for drawing IME composing text in place.
  final TextStyle? textStyle;

  /// Called with `true` when IME composing starts and `false` when it
  /// ends, so the view can hide the renderer's cursor meanwhile. Not called
  /// while the scope is disposed.
  final ValueChanged<bool>? onComposingChanged;

  /// The soft keyboard type; `null` picks [TextInputType.visiblePassword]
  /// on Android (no suggestion strip) and [TextInputType.text] elsewhere.
  /// xterm's `keyboardType`.
  final TextInputType? keyboardType;

  /// The soft keyboard's appearance on iOS (xterm's `keyboardAppearance`).
  final Brightness keyboardAppearance;

  /// Whether the hidden editing state holds a sentinel so Backspace is
  /// detected on soft keyboards that send no key event for it (xterm's
  /// `deleteDetection`, on by default here).
  final bool deleteDetection;

  /// Asked before pasting text the terminal considers unsafe; without it,
  /// such text is not pasted.
  final UnsafePasteCallback? onUnsafePaste;

  /// The fill behind the IME composing text; `null` draws none (the
  /// [textStyle]'s background colour still applies).
  final Color? composingBackgroundColor;

  /// Reads the fill behind the IME composing text when the preedit is
  /// drawn, and again on every [text] notification while composing, so a
  /// theme or OSC 11 change shows at once. Wins over
  /// [composingBackgroundColor] when it returns a colour.
  final ValueGetter<Color?>? composingBackground;

  /// The program's Kitty keyboard flags, read on every key. `null` reads
  /// them from [keys] when it is also a [TerminalPointerSink] (as the
  /// controller's seams are), else assumes none.
  final ValueGetter<KittyKeyboardFlags>? kittyKeyboardFlags;

  /// Which Option keys act as Alt on macOS and iOS
  /// (`VtTerminalController.macosOptionAsAlt`). `null` means
  /// [OptionAsAlt.none]: Option composes characters.
  final ValueGetter<OptionAsAlt>? macosOptionAsAlt;

  /// The rest of the view.
  final Widget child;

  @override
  State<TerminalInputScope> createState() => TerminalInputScopeState();
}

/// The state of a [TerminalInputScope]; the view uses [requestKeyboard]
/// and [closeKeyboard]. Never exported.
class TerminalInputScopeState extends State<TerminalInputScope>
    implements PasteSequencer {
  late TerminalTextInput _textInput = _createTextInput();
  late final TerminalCopyAction _copyAction = TerminalCopyAction(widget.text);
  late final TerminalCopyIfSelectedAction _copyIfSelectedAction =
      TerminalCopyIfSelectedAction(widget.text);
  late final TerminalPasteAction _pasteAction = TerminalPasteAction(
    widget.text,
    readOnly: widget.readOnly,
    onUnsafePaste: widget.onUnsafePaste,
    sequencer: this,
  );

  /// Physical keys whose press went to the encoder, so their repeats and
  /// release do too (the Kitty protocol pairs them) and no other release
  /// is sent.
  final _encodedPresses = <PhysicalKeyboardKey>{};

  /// Physical keys whose press was left to the platform text input, so
  /// their repeats are too.
  final _platformPresses = <PhysicalKeyboardKey>{};

  /// Input waiting for text the platform has not committed yet (see the
  /// class docs of [TerminalInputScope], "Order").
  final _queue = <_Pending>[];
  Timer? _commitTimer;

  bool _hadFocus = false;
  bool _disposing = false;

  /// Whether [closeKeyboard] closed the connection: a rebuild must not
  /// open it again; [requestKeyboard] or the next focus gain does.
  bool _keyboardClosed = false;
  bool _rectsScheduled = false;
  bool _passwordInput = false;
  bool _composingShown = false;
  GridPoint? _cursorCell;
  Size? _sentSize;
  Matrix4? _sentTransform;

  TerminalTextInput _createTextInput() => TerminalTextInput(
    onEdit: _onEdit,
    onComposing: _onComposing,
    onAction: _onAction,
    onUpdate: _onTextInputUpdate,
    sentinel: widget.deleteDetection ? deleteDetectionSentinel : '',
  );

  bool get _acceptsInput => !widget.readOnly && !widget.keys.isDisposed;

  bool get _wantsTextInput =>
      !widget.readOnly &&
      !widget.hardwareKeyboardOnly &&
      !widget.text.isDisposed;

  /// Whether a text input connection is open.
  @visibleForTesting
  bool get hasTextInputConnection => _textInput.isAttached;

  /// Shows the soft keyboard: focuses the view and opens (or re-shows) the
  /// text input connection. Does nothing for [TerminalInputScope.readOnly]
  /// or [TerminalInputScope.hardwareKeyboardOnly] views beyond focusing.
  void requestKeyboard() {
    _keyboardClosed = false;
    if (!widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
      return; // the focus listener opens the connection
    }
    if (_textInput.isAttached) {
      _textInput.show();
    } else {
      _openTextInput();
    }
  }

  /// Hides the soft keyboard by closing the text input connection; the
  /// view keeps the focus and hardware keys still work.
  void closeKeyboard() {
    _keyboardClosed = true;
    _closeTextInput();
  }

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
    widget.text.addListener(_onTextSinkChanged);
    _hadFocus = widget.focusNode.hasFocus;
    if (_hadFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.focusNode.hasFocus) _openTextInput();
      });
    }
  }

  @override
  void didUpdateWidget(TerminalInputScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      oldWidget.text.removeListener(_onTextSinkChanged);
      widget.text.addListener(_onTextSinkChanged);
    }
    _copyAction.text = widget.text;
    _copyIfSelectedAction.text = widget.text;
    _pasteAction
      ..text = widget.text
      ..readOnly = widget.readOnly
      ..onUnsafePaste = widget.onUnsafePaste;
    if (oldWidget.keys != widget.keys) {
      _encodedPresses.clear();
      _platformPresses.clear();
    }
    final configChanged =
        oldWidget.keyboardType != widget.keyboardType ||
        oldWidget.keyboardAppearance != widget.keyboardAppearance;
    if (oldWidget.deleteDetection != widget.deleteDetection) {
      _closeTextInput();
      _textInput = _createTextInput();
    } else if (configChanged && _textInput.isAttached) {
      _textInput.connection!.updateConfig(_configuration());
    }
    if (!_wantsTextInput) {
      _closeTextInput();
    } else if (widget.focusNode.hasFocus &&
        !_textInput.isAttached &&
        !_keyboardClosed) {
      _openTextInput();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
      // The new node may differ in focus: report it and open or close the
      // connection, as if it had changed. When the old node had the focus,
      // the owner may be moving it to the new node (the view does), which
      // applies after this frame: judge once the focus has settled, so the
      // program sees no focus-out/focus-in blip.
      if (oldWidget.focusNode.hasFocus) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          scheduleMicrotask(() {
            if (mounted && !_disposing) _onFocusChanged();
          });
        });
      } else {
        _onFocusChanged();
      }
    }
    if (oldWidget.geometry != widget.geometry ||
        oldWidget.textStyle != widget.textStyle) {
      _scheduleRects();
    }
  }

  @override
  void dispose() {
    _disposing = true;
    widget.focusNode.removeListener(_onFocusChanged);
    widget.text.removeListener(_onTextSinkChanged);
    _commitTimer?.cancel();
    _queue.clear();
    _textInput.detach(notify: false);
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Focus and the text input connection
  // ---------------------------------------------------------------------

  void _onFocusChanged() {
    final focused = widget.focusNode.hasFocus;
    if (focused == _hadFocus) return;
    _hadFocus = focused;
    if (!focused) {
      _encodedPresses.clear();
      _platformPresses.clear();
    }
    if (!widget.readOnly && !widget.text.isDisposed) {
      widget.text.sendFocus(focused: focused);
    }
    if (focused) {
      _keyboardClosed = false;
      _openTextInput();
    } else {
      _closeTextInput();
    }
  }

  TextInputConfiguration _configuration() => terminalTextInputConfiguration(
    viewId: View.maybeOf(context)?.viewId,
    platform: defaultTargetPlatform,
    keyboardType: widget.keyboardType,
    keyboardAppearance: widget.keyboardAppearance,
    obscureText: _passwordInput,
  );

  void _openTextInput() {
    if (!_wantsTextInput || !mounted) return;
    _passwordInput = widget.text.isPasswordInput;
    _textInput.attach(_configuration());
    final style = widget.textStyle;
    if (style != null) {
      _textInput.connection?.updateStyle(
        TextInputStyle(
          fontFamily: style.fontFamily,
          fontSize: style.fontSize,
          fontWeight: style.fontWeight,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
          letterSpacing: style.letterSpacing,
          lineHeight: widget.geometry.metrics.height,
        ),
      );
    }
    _sentSize = null;
    _sentTransform = null;
    _scheduleRects();
  }

  void _closeTextInput() {
    if (_textInput.isAttached || _textInput.composingText.isNotEmpty) {
      _textInput.detach();
    }
    // Nothing more will arrive from the platform.
    _dropTextPlaceholders();
  }

  // ---------------------------------------------------------------------
  // Order: input waiting behind text the platform has not committed
  // ---------------------------------------------------------------------

  /// Sends [send] now, or after what is already waiting.
  void _emit(VoidCallback send) {
    if (_queue.isEmpty) {
      send();
    } else {
      _queue.add(_Pending.ready(send));
    }
  }

  /// Reserves the place of the text a key left to the platform will
  /// produce.
  void _expectCommit() {
    _queue.add(_Pending(_PendingKind.text));
    _commitTimer?.cancel();
    _commitTimer = Timer(TerminalInputScope.commitTimeout, () {
      _commitTimer = null;
      _dropTextPlaceholders();
    });
  }

  /// Delivers committed text ([characters] grapheme clusters) in the place
  /// of the oldest keys waiting for it.
  void _commitText(VoidCallback send, int characters) {
    final first = _queue.indexWhere((p) => p.waitsForText);
    if (first < 0) {
      _emit(send);
      return;
    }
    _queue[first].fill(send);
    // Text that arrived in one update answers several keys.
    var extra = characters - 1;
    for (var i = first + 1; i < _queue.length && extra > 0;) {
      if (_queue[i].waitsForText) {
        _queue.removeAt(i);
        extra--;
      } else {
        i++;
      }
    }
    _flush();
  }

  void _dropTextPlaceholders() {
    _queue.removeWhere((p) => p.waitsForText);
    _flush();
  }

  void _flush() {
    while (_queue.isNotEmpty && _queue.first.isReady) {
      _queue.removeAt(0).send?.call();
    }
    if (!_queue.any((p) => p.waitsForText)) {
      _commitTimer?.cancel();
      _commitTimer = null;
    }
  }

  /// Holds a place for a paste: keys typed while the clipboard is read
  /// wait behind it.
  @override
  Object hold() {
    final pending = _Pending(_PendingKind.paste);
    _queue.add(pending);
    return pending;
  }

  /// Delivers the paste held by [token] in its place.
  @override
  void release(Object token, VoidCallback? send) {
    if (token is! _Pending || !_queue.contains(token)) {
      if (!_disposing) send?.call();
      return;
    }
    token.fill(send);
    _flush();
  }

  /// Sends [event] in order and returns whether it produced (or, when it
  /// had to wait, is expected to produce) bytes.
  bool _sendKey(VtKeyEvent event) {
    if (_queue.isEmpty || !_expectsBytes(event)) {
      // A key that likely encodes to nothing (Cmd shortcuts, media keys)
      // is not held back: its result decides whether Flutter gets it.
      return widget.keys.sendKey(event);
    }
    _queue.add(_Pending.ready(() => widget.keys.sendKey(event)));
    return true;
  }

  /// Whether [event] is expected to produce bytes in any mode: everything
  /// except Super shortcuts, lone modifiers, and media or system keys.
  static bool _expectsBytes(VtKeyEvent event) {
    final mods = event.modifiers;
    if (mods.hasSuper && !mods.hasCtrl && !mods.hasAlt) return false;
    final key = event.key;
    if (modifierVtKeys.contains(key)) return false;
    return reservedVtKeys.contains(key) ||
        event.text.isNotEmpty ||
        mods.hasCtrl ||
        mods.hasAlt ||
        key == VtKey.backspace ||
        isTextKey(key) ||
        (key.index >= VtKey.delete.index && key.index <= VtKey.f25.index);
  }

  // ---------------------------------------------------------------------
  // Text sink notifications: IME rectangles, password input
  // ---------------------------------------------------------------------

  void _onTextSinkChanged() {
    if (widget.text.isDisposed) {
      _closeTextInput();
      return;
    }
    _scheduleRects();
    if (_textInput.composingText.isNotEmpty &&
        widget.composingBackground != null &&
        _composingBackgroundOrNull() != _shownComposingBackground) {
      _scheduleRebuild();
    }
  }

  Color? _shownComposingBackground;
  bool _rebuildScheduled = false;

  Color? _composingBackgroundOrNull() =>
      widget.composingBackground?.call() ?? widget.composingBackgroundColor;

  /// Rebuilds now, or after the frame when notified during one (output
  /// written from a build method).
  void _scheduleRebuild() {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  /// Coalesces the platform calls the text sink's notifications cause to
  /// one per frame.
  void _scheduleRects() {
    if (_rectsScheduled || !_textInput.isAttached) return;
    _rectsScheduled = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _rectsScheduled = false;
        if (mounted) _updatePlatformState();
      }, debugLabel: 'TerminalInputScope.rects')
      ..ensureVisualUpdate();
  }

  void _updatePlatformState() {
    final connection = _textInput.connection;
    if (connection == null || widget.text.isDisposed) return;
    final password = widget.text.isPasswordInput;
    if (password != _passwordInput) {
      _passwordInput = password;
      connection.updateConfig(_configuration());
    }
    final cell = widget.text.cursorViewportCell;
    if (cell != _cursorCell) {
      // The preedit follows the cursor.
      if (_textInput.composingText.isNotEmpty) {
        setState(() => _cursorCell = cell);
      } else {
        _cursorCell = cell;
      }
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final transform = box.getTransformTo(null);
    if (box.size != _sentSize || transform != _sentTransform) {
      _sentSize = box.size;
      _sentTransform = transform;
      connection.setEditableSizeAndTransform(box.size, transform);
    }
    if (cell == null) return;
    // The connection drops rects equal to the last one sent.
    final caret = widget.geometry.cellRect(cell.x, cell.y);
    connection
      ..setComposingRect(caret)
      ..setCaretRect(caret);
  }

  // ---------------------------------------------------------------------
  // Text input callbacks
  // ---------------------------------------------------------------------

  void _onComposing(String text) {
    if (_disposing || !mounted) return;
    final wasComposing = _composingShown;
    _composingShown = text.isNotEmpty;
    setState(() {
      if (text.isNotEmpty) _cursorCell = widget.text.cursorViewportCell;
    });
    if (wasComposing != _composingShown) {
      widget.onComposingChanged?.call(_composingShown);
    }
  }

  void _onTextInputUpdate() {
    // Keys left to the platform went into the IME's preedit.
    if (_textInput.composingText.isNotEmpty) _dropTextPlaceholders();
  }

  void _onEdit(SentinelEdit edit) {
    if (!_acceptsInput || widget.text.isDisposed) return;
    for (var i = 0; i < edit.backspaces; i++) {
      _emit(() => _sendKeyWithLatch(const VtKeyEvent(key: VtKey.backspace)));
    }
    final text = edit.text;
    if (text.isEmpty) return;
    _commitText(() {
      final latched = widget.keys.latchedModifiers.value;
      if (!latched.isEmpty && text.characters.length == 1) {
        widget.keys.latchedModifiers.value = KeyModifiers.none;
        widget.keys.sendKey(keyEventForCharacter(text, latched));
      } else {
        widget.text.sendText(text);
      }
    }, text.characters.length);
  }

  void _onAction(TextInputAction action) {
    if (!_acceptsInput) return;
    switch (action) {
      case TextInputAction.newline ||
          TextInputAction.done ||
          TextInputAction.go ||
          TextInputAction.search ||
          TextInputAction.send:
        _emit(() => _sendKeyWithLatch(const VtKeyEvent(key: VtKey.enter)));
      default:
        break;
    }
  }

  void _sendKeyWithLatch(VtKeyEvent event) {
    final latched = widget.keys.latchedModifiers.value;
    if (!latched.isEmpty) {
      widget.keys.latchedModifiers.value = KeyModifiers.none;
      event = event.copyWith(modifiers: event.modifiers | latched);
    }
    widget.keys.sendKey(event);
  }

  // ---------------------------------------------------------------------
  // Hardware keys
  // ---------------------------------------------------------------------

  KittyKeyboardFlags get _kittyFlags {
    final read = widget.kittyKeyboardFlags;
    if (read != null) return read();
    if (widget.keys case final TerminalPointerSink pointer
        when !pointer.isDisposed) {
      return pointer.terminal.kittyKeyboardFlags;
    }
    return KittyKeyboardFlags.disabled;
  }

  /// Whether the program asked for key events the text input cannot give
  /// (releases, or escape codes for plain text keys).
  bool get _kittyWantsKeys {
    final flags = _kittyFlags;
    return flags.containsAll(KittyKeyboardFlags.reportEvents) ||
        flags.containsAll(KittyKeyboardFlags.reportAll);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final pre = widget.onKeyEvent?.call(node, event);
    if (pre != null && pre != KeyEventResult.ignored) return pre;

    final shortcut = _handleShortcut(node, event);
    if (shortcut != KeyEventResult.ignored) return shortcut;

    if (!_acceptsInput) return KeyEventResult.ignored;

    final physical = event.physicalKey;
    final key = vtKeyForPhysicalKey(physical);
    final isModifier = modifierVtKeys.contains(key);
    final mapper = KeyEventMapper(
      keyboard: HardwareKeyboard.instance,
      platform: defaultTargetPlatform,
      optionAsAlt: widget.macosOptionAsAlt?.call() ?? OptionAsAlt.none,
    );

    if (event is KeyUpEvent) {
      _platformPresses.remove(physical);
      final encoded = _encodedPresses.remove(physical);
      if (!encoded && !isModifier) return KeyEventResult.skipRemainingHandlers;
      _sendKey(mapper.map(event));
      // Modifiers still reach the platform (IMEs switch modes on them).
      return isModifier
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.handled;
    }

    if (isModifier) {
      _sendKey(mapper.map(event));
      return KeyEventResult.skipRemainingHandlers;
    }

    // A repeat follows its press: to the encoder or to the platform.
    if (event is KeyRepeatEvent) {
      if (_encodedPresses.contains(physical)) {
        return _encode(mapper.map(event), physical);
      }
      if (_platformPresses.contains(physical)) {
        if (_textInput.isAttached && _textInput.composingText.isEmpty) {
          _expectCommit();
        }
        return KeyEventResult.skipRemainingHandlers;
      }
    }

    // The IME owns every key while it composes (Enter commits, Backspace
    // edits the preedit, arrows pick candidates).
    if (_textInput.composingText.isNotEmpty) {
      return KeyEventResult.skipRemainingHandlers;
    }

    final latched = widget.keys.latchedModifiers.value;
    final vtEvent = mapper.map(event, extraModifiers: latched);
    final mods = vtEvent.modifiers;
    final textual =
        isTextKey(key) ||
        (key == VtKey.unidentified && vtEvent.text.isNotEmpty);
    if (_textInput.isAttached &&
        textual &&
        !mods.hasCtrl &&
        !mods.hasAlt &&
        !mods.hasSuper &&
        !_kittyWantsKeys) {
      // The platform text input produces the text (IME, dead keys).
      _platformPresses.add(physical);
      _expectCommit();
      return KeyEventResult.skipRemainingHandlers;
    }
    if (key == VtKey.unidentified && vtEvent.text.isEmpty) {
      return KeyEventResult.ignored;
    }
    // On Apple platforms Cmd belongs to the app and the system (menus,
    // Cmd+Q, Cmd+H, the emoji picker), as in Ghostty, where key
    // equivalents go to the menus first; never to the program.
    if (mods.hasSuper && _isApplePlatform) return KeyEventResult.ignored;
    if (!latched.isEmpty) {
      widget.keys.latchedModifiers.value = KeyModifiers.none;
    }
    return _encode(vtEvent, physical);
  }

  static bool get _isApplePlatform =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  KeyEventResult _encode(VtKeyEvent event, PhysicalKeyboardKey physical) {
    final sent = _sendKey(event);
    if (sent || reservedVtKeys.contains(event.key)) {
      _encodedPresses.add(physical);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Runs the shortcut matching [event], as [ShortcutManager.handleKeypress]
  /// does, but before the terminal encodes the key and only for the
  /// terminal's own map.
  KeyEventResult _handleShortcut(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final context = node.context;
    if (context == null) return KeyEventResult.ignored;
    final shortcuts =
        widget.shortcuts ?? defaultTerminalShortcuts(defaultTargetPlatform);
    for (final MapEntry(key: activator, value: intent) in shortcuts.entries) {
      if (!activator.accepts(event, HardwareKeyboard.instance)) continue;
      final action = Actions.maybeFind<Intent>(context, intent: intent);
      if (action == null) continue;
      final (enabled, result) = Actions.of(
        context,
      ).invokeActionIfEnabled(action, intent, context);
      if (enabled) return action.toKeyEventResult(intent, result);
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final composing = _textInput.composingText;
    final cell = _cursorCell;
    return Actions(
      actions: <Type, Action<Intent>>{
        CopySelectionTextIntent: _copyAction,
        CopyIfSelectedIntent: _copyIfSelectedAction,
        PasteTextIntent: _pasteAction,
      },
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onKeyEvent: _onKeyEvent,
        // Always a Stack, so starting to compose never remounts the child;
        // passthrough keeps the view's tight constraints for it.
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (composing.isNotEmpty && cell != null)
              ComposingOverlay(
                text: composing,
                origin: widget.geometry.cellOrigin(cell.x, cell.y),
                style: widget.textStyle,
                backgroundColor: _shownComposingBackground =
                    _composingBackgroundOrNull(),
              ),
          ],
        ),
      ),
    );
  }
}

enum _PendingKind { ready, text, paste }

/// One place in the input order: something ready to send, or a place held
/// for text the platform has not committed yet, or for a paste whose
/// clipboard read has not returned.
final class _Pending {
  _Pending(this.kind);

  _Pending.ready(VoidCallback this.send) : kind = _PendingKind.ready;

  final _PendingKind kind;
  VoidCallback? send;
  bool _filled = false;

  bool get isReady => kind == _PendingKind.ready || _filled;

  bool get waitsForText => kind == _PendingKind.text && !_filled;

  void fill(VoidCallback? value) {
    send = value;
    _filled = true;
  }
}
