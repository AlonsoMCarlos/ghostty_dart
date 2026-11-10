import 'package:flutter/services.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import 'physical_key_map.dart';

/// The modifier keys, which are reported to the encoder on press and
/// release (the Kitty protocol reports them) but never produce text. Never
/// exported.
const Set<VtKey> modifierVtKeys = {
  VtKey.shiftLeft,
  VtKey.shiftRight,
  VtKey.controlLeft,
  VtKey.controlRight,
  VtKey.altLeft,
  VtKey.altRight,
  VtKey.metaLeft,
  VtKey.metaRight,
  VtKey.capsLock,
  VtKey.numLock,
};

/// The keys Flutter's default shortcuts would take (focus traversal,
/// activation, dismissal): the terminal always handles them, even when the
/// encoder produced nothing. Never exported.
const Set<VtKey> reservedVtKeys = {
  VtKey.tab,
  VtKey.escape,
  VtKey.enter,
  VtKey.numpadEnter,
  VtKey.space,
  VtKey.arrowUp,
  VtKey.arrowDown,
  VtKey.arrowLeft,
  VtKey.arrowRight,
};

/// Whether [key] is a writing-system key (W3C § 3.1.1: letters, digits,
/// punctuation, the `Intl*` keys) or Space: the keys whose text the
/// platform's text input (IME, dead keys, compose) should produce. Numpad
/// keys are not included: they follow the keypad application mode. Never
/// exported.
///
/// Relies on [VtKey] declaring the writing-system keys contiguously from
/// `backquote` to `slash`, as `key/event.h` numbers them (tested).
bool isTextKey(VtKey key) =>
    key == VtKey.space ||
    (key.index >= VtKey.backquote.index && key.index <= VtKey.slash.index);

/// Whether the platform is macOS or iOS, where Option is a text modifier.
bool _isApple(TargetPlatform platform) =>
    platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;

/// Turns Flutter [KeyEvent]s into [VtKeyEvent]s (ADR 0011, Input). Never
/// exported.
///
/// - The key is the **physical** key ([vtKeyForPhysicalKey]).
/// - The modifiers come from [HardwareKeyboard], with the right-side bits
///   and Caps/Num Lock.
/// - **AltGr** (never on Apple platforms) removes Ctrl and Alt, so
///   `AltGr+q` sends `@`, not `ESC ^@` (research
///   `docs/internal/research/2026-11-09-flutter-input.md` §1.2). It is
///   active when the logical `AltGraph` key is held (Linux reports
///   `ISO_Level3_Shift` so, `fl_key_mapping.g.cc`), or on Windows when right
///   Alt and Ctrl are held **and the key produced a character**: Win32
///   precedes AltGr with a fake left Ctrl press (Flutter 3.47.9
///   `shell/platform/windows/keyboard_manager.cc`, comment above
///   `IsKeyDownAltRight`, and `keyboard_unittests.cc` `AltGrModifiedKey`:
///   Ctrl, right Alt, then `q` with character `@`), while a real
///   Ctrl+right Alt on a layout without AltGr produces no character.
/// - **Option** (macOS and iOS): unless [optionAsAlt] makes the held Option
///   key Alt, Alt is removed as well ([isOptionText]); Option then composes
///   characters (and dead keys) through the platform text input, as in
///   Ghostty's default `macos-option-as-alt = false`. When Option is Alt on
///   iOS, whose libghostty-vt build ignores the setting (`key_encode.zig`
///   gates it on macOS), the text is the unshifted character, so
///   Option+w sends `ESC w` there too.
/// - [VtKeyEvent.text] is [KeyEvent.character] without C0 controls, DEL or
///   the macOS function-key codes (`NSEvent` function-key Unicode values
///   U+F700–U+F8FF), as `key/event.h` requires.
/// - [VtKeyEvent.unshiftedCodepoint] is the logical key's codepoint when it
///   is in Flutter's Unicode plane (the character of the key without
///   modifiers on the current layout).
/// - Shift is consumed when it changed the text (`A` from the `a` key).
final class KeyEventMapper {
  /// A mapper reading modifier state from [keyboard] for [platform].
  const KeyEventMapper({
    required this.keyboard,
    required this.platform,
    this.optionAsAlt = OptionAsAlt.none,
  });

  /// Where the held modifiers and lock modes are read from.
  final HardwareKeyboard keyboard;

  /// The platform, for the AltGr and Option rules.
  final TargetPlatform platform;

  /// Which Option keys act as Alt on macOS and iOS.
  final OptionAsAlt optionAsAlt;

  /// Whether AltGr is active for [event].
  bool isAltGraphActive(KeyEvent event) {
    if (_isApple(platform)) return false;
    if (event.logicalKey == LogicalKeyboardKey.altGraph ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.altGraph)) {
      return true;
    }
    if (platform != TargetPlatform.windows || !keyboard.isControlPressed) {
      return false;
    }
    final rightAlt =
        keyboard.isPhysicalKeyPressed(PhysicalKeyboardKey.altRight) ||
        (event is KeyUpEvent &&
            event.physicalKey == PhysicalKeyboardKey.altRight);
    return rightAlt &&
        (event is KeyUpEvent || encodableText(event.character).isNotEmpty);
  }

  /// Whether Option is held on macOS or iOS, is not Alt for the side held,
  /// and [event] is a text key (or produced text), so Option is a text
  /// modifier. Option with a function key (arrows, Backspace) stays Alt.
  bool isOptionText(KeyEvent event) {
    if (!_isApple(platform) || !keyboard.isAltPressed || _optionIsAlt) {
      return false;
    }
    return isTextKey(vtKeyForPhysicalKey(event.physicalKey)) ||
        encodableText(event.character).isNotEmpty;
  }

  bool get _optionIsAlt {
    final left = keyboard.isPhysicalKeyPressed(PhysicalKeyboardKey.altLeft);
    final right = keyboard.isPhysicalKeyPressed(PhysicalKeyboardKey.altRight);
    return switch (optionAsAlt) {
      OptionAsAlt.both => true,
      OptionAsAlt.left => left,
      OptionAsAlt.right => right,
      OptionAsAlt.none || OptionAsAlt.unknown => false,
    };
  }

  /// The modifiers held during [event], with Ctrl and Alt removed while
  /// AltGr is active and Alt removed while Option is a text modifier.
  KeyModifiers modifiersFor(KeyEvent event) {
    final altGraph = isAltGraphActive(event);
    final optionText = isOptionText(event);
    final lockModes = keyboard.lockModesEnabled;
    bool pressed(PhysicalKeyboardKey key) => keyboard.isPhysicalKeyPressed(key);
    bool onlyRight(PhysicalKeyboardKey left, PhysicalKeyboardKey right) =>
        pressed(right) && !pressed(left);
    final ctrl = keyboard.isControlPressed && !altGraph;
    final alt = keyboard.isAltPressed && !altGraph && !optionText;
    return KeyModifiers(
      shift: keyboard.isShiftPressed,
      ctrl: ctrl,
      alt: alt,
      superKey: keyboard.isMetaPressed,
      capsLock: lockModes.contains(KeyboardLockMode.capsLock),
      numLock: lockModes.contains(KeyboardLockMode.numLock),
      rightShift: onlyRight(
        PhysicalKeyboardKey.shiftLeft,
        PhysicalKeyboardKey.shiftRight,
      ),
      rightCtrl:
          ctrl &&
          onlyRight(
            PhysicalKeyboardKey.controlLeft,
            PhysicalKeyboardKey.controlRight,
          ),
      rightAlt:
          alt &&
          onlyRight(PhysicalKeyboardKey.altLeft, PhysicalKeyboardKey.altRight),
      rightSuper: onlyRight(
        PhysicalKeyboardKey.metaLeft,
        PhysicalKeyboardKey.metaRight,
      ),
    );
  }

  /// The [VtKeyEvent] for [event], with [extraModifiers] (latched by the
  /// on-screen toolbar) added to the held ones.
  VtKeyEvent map(
    KeyEvent event, {
    KeyModifiers extraModifiers = KeyModifiers.none,
  }) {
    final action = switch (event) {
      KeyUpEvent() => KeyAction.release,
      KeyRepeatEvent() => KeyAction.repeat,
      _ => KeyAction.press,
    };
    final modifiers = modifiersFor(event) | extraModifiers;
    final unshifted = unshiftedCodepointOf(event.logicalKey);
    var text = action == KeyAction.release
        ? ''
        : encodableText(event.character);
    if (platform == TargetPlatform.iOS &&
        modifiers.hasAlt &&
        unshifted != 0 &&
        text.isNotEmpty) {
      // Option is Alt here: send the key's own character with the prefix.
      text = String.fromCharCode(unshifted);
    }
    final shiftConsumed =
        modifiers.hasShift &&
        text.isNotEmpty &&
        unshifted != 0 &&
        text != String.fromCharCode(unshifted);
    return VtKeyEvent(
      key: vtKeyForPhysicalKey(event.physicalKey),
      action: action,
      modifiers: modifiers,
      consumedModifiers: shiftConsumed ? KeyModifiers.shift : KeyModifiers.none,
      text: text,
      unshiftedCodepoint: unshifted,
    );
  }

  /// [character] without what the encoder must never see in
  /// [VtKeyEvent.text]: C0 controls, DEL and macOS function-key codes.
  static String encodableText(String? character) {
    if (character == null || character.isEmpty) return '';
    for (final rune in character.runes) {
      if (rune < 0x20 ||
          rune == 0x7F ||
          (rune >= _macFunctionKeyFirst && rune <= _macFunctionKeyLast)) {
        return '';
      }
    }
    return character;
  }

  /// The codepoint of [key] when it is a Unicode logical key, else 0.
  static int unshiftedCodepointOf(LogicalKeyboardKey key) {
    if (key.keyId & LogicalKeyboardKey.planeMask !=
        LogicalKeyboardKey.unicodePlane) {
      return 0;
    }
    final codepoint = key.keyId & LogicalKeyboardKey.valueMask;
    // Flutter's Unicode plane holds lowercase letters; keep controls out.
    return codepoint < 0x20 || codepoint == 0x7F ? 0 : codepoint;
  }
}

/// The first and last of the `NSEvent` function-key Unicode values
/// (`NSUpArrowFunctionKey` ... ), which macOS puts in a key's characters.
const _macFunctionKeyFirst = 0xF700;
const _macFunctionKeyLast = 0xF8FF;

/// The key, unshifted codepoint and consumed Shift for one character typed
/// on a soft keyboard while the toolbar latched a modifier, so Ctrl+`c`
/// becomes `^C`. ASCII letters, digits and punctuation map to their US
/// physical key; anything else to [VtKey.unidentified] with its text.
/// Never exported.
///
/// Relies on `a`...`z` and `digit0`...`digit9` being contiguous in [VtKey]
/// (tested).
VtKeyEvent keyEventForCharacter(String character, KeyModifiers modifiers) {
  final rune = character.runes.length == 1 ? character.runes.first : -1;
  var key = VtKey.unidentified;
  var unshifted = rune;
  var consumed = KeyModifiers.none;
  if (rune >= 0x61 && rune <= 0x7A) {
    key = VtKey.values[VtKey.a.index + rune - 0x61];
  } else if (rune >= 0x41 && rune <= 0x5A) {
    key = VtKey.values[VtKey.a.index + rune - 0x41];
    unshifted = rune + 0x20;
    modifiers = modifiers | KeyModifiers.shift;
    consumed = KeyModifiers.shift;
  } else if (rune >= 0x30 && rune <= 0x39) {
    key = VtKey.values[VtKey.digit0.index + rune - 0x30];
  } else if (_usPunctuation[rune] case final punctuation?) {
    key = punctuation;
  }
  return VtKeyEvent(
    key: key,
    modifiers: modifiers,
    consumedModifiers: consumed,
    text: KeyEventMapper.encodableText(character),
    unshiftedCodepoint: unshifted < 0 ? 0 : unshifted,
  );
}

const _usPunctuation = <int, VtKey>{
  0x20: VtKey.space,
  0x60: VtKey.backquote,
  0x5C: VtKey.backslash,
  0x5B: VtKey.bracketLeft,
  0x5D: VtKey.bracketRight,
  0x2C: VtKey.comma,
  0x3D: VtKey.equal,
  0x2D: VtKey.minus,
  0x2E: VtKey.period,
  0x27: VtKey.quote,
  0x3B: VtKey.semicolon,
  0x2F: VtKey.slash,
};
