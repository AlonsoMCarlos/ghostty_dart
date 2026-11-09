/// The key encoder (`key/encoder.h`): turns [VtKeyEvent]s into the bytes a
/// program expects, in legacy or Kitty keyboard protocol encoding.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../terminal/terminal.dart';
import 'encode_buffer.dart';
import 'key.dart';

/// Encodes key events into terminal input bytes (`GhosttyKeyEncoder`),
/// following the terminal's keyboard modes.
///
/// Sync it with the terminal before encoding, because programs change the
/// modes it depends on (application cursor keys, Kitty flags, ...):
///
/// ```dart
/// final encoder = KeyEncoder();
/// encoder.setFromTerminal(terminal);
/// final bytes = encoder.encode(
///   const VtKeyEvent(key: VtKey.arrowUp),
/// ); // ESC [ A, or ESC O A in application cursor mode
/// pty.write(bytes);
/// encoder.dispose();
/// ```
///
/// ## Ownership
///
/// The encoder owns a native encoder, a native key event that it reuses for
/// every [encode], and a reusable output buffer, so encoding allocates no
/// native memory. Call [dispose] when done; a finalizer frees everything if
/// you forget. After [dispose], every member except [isDisposed] and
/// [dispose] throws [StateError]. The encoder does not keep a reference to
/// any terminal.
final class KeyEncoder implements Finalizable {
  /// Creates an encoder with default options: legacy encoding, every mode
  /// off.
  ///
  /// Throws [GhosttyException] if the library fails to allocate it and
  /// [IncompatibleLibraryException] if the loaded libghostty-vt is not a
  /// supported 1.x version.
  KeyEncoder() : _handle = _createEncoder() {
    try {
      _event = _createEvent();
    } catch (_) {
      _handle.dispose();
      rethrow;
    }
    bindHandle(this, _handle);
    _handle
      ..addCleanup(_event.dispose)
      ..addCleanup(_output.dispose)
      ..addCleanup(_text.dispose);
  }

  static final _encoderFinalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyKeyEncoder)>>(
      ghostty_key_encoder_free,
    ).cast(),
  );

  static final _eventFinalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyKeyEvent)>>(
      ghostty_key_event_free,
    ).cast(),
  );

  static NativeHandle<GhosttyKeyEncoderImpl> _createEncoder() => NativeHandle(
    createNative<GhosttyKeyEncoderImpl>(
      'ghostty_key_encoder_new',
      (out) => ghostty_key_encoder_new(nullptr, out),
    ),
    typeName: 'KeyEncoder',
    free: (p) => ghostty_key_encoder_free(p),
    finalizer: _encoderFinalizer,
  );

  static NativeHandle<GhosttyKeyEventImpl> _createEvent() => NativeHandle(
    createNative<GhosttyKeyEventImpl>(
      'ghostty_key_event_new',
      (out) => ghostty_key_event_new(nullptr, out),
    ),
    typeName: 'KeyEncoder',
    free: (p) => ghostty_key_event_free(p),
    finalizer: _eventFinalizer,
  );

  final NativeHandle<GhosttyKeyEncoderImpl> _handle;
  late final NativeHandle<GhosttyKeyEventImpl> _event;
  final EncodeBuffer _output = EncodeBuffer();

  /// Holds the UTF-8 text of the native event: `ghostty_key_event_set_utf8`
  /// does not copy, so the bytes must stay valid until the text is set
  /// again or the event is freed.
  final GrowableNativeBuffer _text = GrowableNativeBuffer(32);

  /// The event last copied into the native event, so [encode] only calls
  /// the setters for fields that changed. `null` until the first [encode].
  VtKeyEvent? _applied;

  /// Whether [dispose] has been called.
  bool get isDisposed => _handle.isDisposed;

  /// Sets encoder options. Only the arguments you pass change; the others
  /// keep their current values.
  ///
  /// - [cursorKeyApplication]: DEC mode 1, application cursor keys.
  /// - [keypadKeyApplication]: DEC mode 66, application keypad.
  /// - [ignoreKeypadWithNumLock]: DEC mode 1035.
  /// - [altEscPrefix]: DEC mode 1036, Alt sends an ESC prefix.
  /// - [modifyOtherKeysState2]: xterm `modifyOtherKeys` mode 2.
  /// - [kittyFlags]: the Kitty keyboard protocol flags
  ///   ([KittyKeyboardFlags.disabled] for legacy encoding).
  /// - [macosOptionAsAlt]: whether macOS Option acts as Alt.
  /// - [backarrowKeyMode]: DEC mode 67; Backspace sends 0x08 instead of
  ///   0x7F.
  ///
  /// Every option except [macosOptionAsAlt] comes from the terminal; prefer
  /// [setFromTerminal] for those. Throws [ArgumentError] for
  /// [OptionAsAlt.unknown] (before changing anything).
  void configure({
    bool? cursorKeyApplication,
    bool? keypadKeyApplication,
    bool? ignoreKeypadWithNumLock,
    bool? altEscPrefix,
    bool? modifyOtherKeysState2,
    KittyKeyboardFlags? kittyFlags,
    OptionAsAlt? macosOptionAsAlt,
    bool? backarrowKeyMode,
  }) {
    final optionAsAlt = macosOptionAsAlt == null
        ? null
        : optionAsAltCodec.encode(macosOptionAsAlt);
    final encoder = _handle.pointer;
    withScratch(sizeOf<Int32>(), (memory) {
      void setBool(int option, bool? value) {
        if (value == null) return;
        memory.cast<Bool>().value = value;
        _set(encoder, option, memory.cast());
      }

      setBool(_Option.cursorKeyApplication, cursorKeyApplication);
      setBool(_Option.keypadKeyApplication, keypadKeyApplication);
      setBool(_Option.ignoreKeypadWithNumLock, ignoreKeypadWithNumLock);
      setBool(_Option.altEscPrefix, altEscPrefix);
      setBool(_Option.modifyOtherKeysState2, modifyOtherKeysState2);
      setBool(_Option.backarrowKeyMode, backarrowKeyMode);
      if (kittyFlags != null) {
        memory.cast<Uint8>().value = kittyFlags.value;
        _set(encoder, _Option.kittyFlags, memory.cast());
      }
      if (optionAsAlt != null) {
        memory.cast<Int32>().value = optionAsAlt;
        _set(encoder, _Option.macosOptionAsAlt, memory.cast());
      }
    });
  }

  /// Puts every option back to its default, as on a new encoder: legacy
  /// encoding, every mode off, [OptionAsAlt.none].
  void resetOptions() {
    final encoder = _handle.pointer;
    for (final option in _Option.all) {
      _set(encoder, option, nullptr);
    }
  }

  /// Copies the keyboard modes of [terminal] into the encoder: cursor key
  /// and keypad application modes, backarrow key mode,
  /// ignore-keypad-with-NumLock, Alt ESC prefix, `modifyOtherKeys` and the
  /// Kitty keyboard flags.
  ///
  /// Call it before encoding whenever the terminal may have received output
  /// since the last call. The terminal is read once; no reference to it is
  /// kept.
  ///
  /// The Option-as-Alt setting cannot come from the terminal: this resets
  /// it to [OptionAsAlt.none], as the library does. Call [configure] with
  /// `macosOptionAsAlt` afterwards if you use it.
  ///
  /// Throws [StateError] if either object is disposed.
  void setFromTerminal(VtTerminal terminal) {
    final terminalPointer = handleOf<GhosttyTerminalImpl>(terminal).pointer;
    checkResult(
      ghostty_key_encoder_set_from_terminal(_handle.pointer, terminalPointer),
      'ghostty_key_encoder_set_from_terminal',
    );
  }

  /// Encodes [event] with the current options and returns the bytes to send
  /// to the pty.
  ///
  /// Returns an empty list for events that produce no output, such as a
  /// lone modifier key in legacy mode or a release without Kitty
  /// [KittyKeyboardFlags.reportEvents].
  ///
  /// Throws [ArgumentError] for [VtKey.unknown] or [KeyAction.unknown],
  /// [RangeError] if [VtKeyEvent.unshiftedCodepoint] is not 0–0x10FFFF, and
  /// [StateError] after [dispose].
  Uint8List encode(VtKeyEvent event) {
    _apply(event);
    final encoder = _handle.pointer;
    final nativeEvent = _event.pointer;
    return _output.encode(
      'ghostty_key_encoder_encode',
      (buffer, capacity, written) => ghostty_key_encoder_encode(
        encoder,
        nativeEvent,
        buffer,
        capacity,
        written,
      ),
    );
  }

  /// Frees the encoder and its buffers. Safe to call more than once.
  void dispose() => _handle.dispose();

  /// Copies the fields of [event] that differ from [_applied] into the
  /// native event. Validates everything first, so a bad event leaves the
  /// native event unchanged.
  void _apply(VtKeyEvent event) {
    _handle.checkNotDisposed();
    final previous = _applied;
    if (previous == event) return;
    final key = vtKeyCodec.encode(event.key);
    final action = keyActionCodec.encode(event.action);
    RangeError.checkValueInInterval(
      event.unshiftedCodepoint,
      0,
      0x10FFFF,
      'unshiftedCodepoint',
    );
    final p = _event.pointer;
    // Forget the cache first: if a setter throws, the native event is
    // partly updated and the next encode must set every field again.
    _applied = null;
    if (previous?.key != event.key) {
      checkResult(
        ghostty_key_event_set_key(p, key),
        'ghostty_key_event_set_key',
      );
    }
    if (previous?.action != event.action) {
      checkResult(
        ghostty_key_event_set_action(p, action),
        'ghostty_key_event_set_action',
      );
    }
    if (previous?.modifiers != event.modifiers) {
      checkResult(
        ghostty_key_event_set_mods(p, keyModifiersToRaw(event.modifiers)),
        'ghostty_key_event_set_mods',
      );
    }
    if (previous?.consumedModifiers != event.consumedModifiers) {
      checkResult(
        ghostty_key_event_set_consumed_mods(
          p,
          keyModifiersToRaw(event.consumedModifiers),
        ),
        'ghostty_key_event_set_consumed_mods',
      );
    }
    if (previous?.isComposing != event.isComposing) {
      checkResult(
        ghostty_key_event_set_composing(p, event.isComposing),
        'ghostty_key_event_set_composing',
      );
    }
    if (previous?.unshiftedCodepoint != event.unshiftedCodepoint) {
      checkResult(
        ghostty_key_event_set_unshifted_codepoint(p, event.unshiftedCodepoint),
        'ghostty_key_event_set_unshifted_codepoint',
      );
    }
    if (previous?.text != event.text) _setText(p, event.text);
    _applied = event;
  }

  void _setText(Pointer<GhosttyKeyEventImpl> event, String text) {
    final bytes = utf8.encode(text);
    _text.ensureCapacity(bytes.length);
    final data = _text.pointer;
    data.asTypedList(bytes.length).setAll(0, bytes);
    withScratch(sizeOf<GhosttyString>(), (memory) {
      final string = memory.cast<GhosttyString>().ref
        ..ptr = bytes.isEmpty ? nullptr : data
        ..len = bytes.length;
      checkResult(
        ghostty_key_event_set_utf8(event, string),
        'ghostty_key_event_set_utf8',
      );
    });
  }

  static void _set(
    Pointer<GhosttyKeyEncoderImpl> encoder,
    int option,
    Pointer<Void> value,
  ) => checkResult(
    ghostty_key_encoder_set(encoder, option, value),
    'ghostty_key_encoder_set',
  );
}

/// `GhosttyKeyEncoderOption` values.
abstract final class _Option {
  static const cursorKeyApplication =
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION;
  static const keypadKeyApplication =
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION;
  static const ignoreKeypadWithNumLock = GhosttyKeyEncoderOption
      .GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK;
  static const altEscPrefix =
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX;
  static const modifyOtherKeysState2 =
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2;
  static const kittyFlags =
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS;
  static const macosOptionAsAlt =
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT;
  static const backarrowKeyMode =
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_BACKARROW_KEY_MODE;

  static const all = [
    cursorKeyApplication,
    keypadKeyApplication,
    ignoreKeypadWithNumLock,
    altEscPrefix,
    modifyOtherKeysState2,
    kittyFlags,
    macosOptionAsAlt,
    backarrowKeyMode,
  ];
}
