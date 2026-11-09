/// Key events (`key/event.h`): physical key codes, key actions and the
/// immutable [VtKeyEvent] that a `KeyEncoder` turns into bytes.
///
/// Pure Dart: no `dart:ffi`, so a future web backend can reuse it.
library;

import '../core/enum_codec.dart';
import '../core/modifiers.dart';
import '../terminal/kitty_keyboard_flags.dart';

/// A physical key (`GhosttyKey`), independent of the keyboard layout.
///
/// Based on the W3C UI Events `KeyboardEvent.code` values
/// (https://www.w3.org/TR/uievents-code): the "a" key on a US keyboard and
/// the "ф" key on a Russian keyboard are both [VtKey.a]. The text the key
/// produces for the current layout goes in [VtKeyEvent.text].
///
/// Named `VtKey` because `Key` clashes with Flutter's `Key`.
enum VtKey {
  /// A key the platform could not identify.
  unidentified(0),

  // Writing System Keys (W3C § 3.1.1)

  /// The `Backquote` key.
  backquote(1),

  /// The `Backslash` key.
  backslash(2),

  /// The `BracketLeft` key.
  bracketLeft(3),

  /// The `BracketRight` key.
  bracketRight(4),

  /// The `Comma` key.
  comma(5),

  /// The `Digit0` key.
  digit0(6),

  /// The `Digit1` key.
  digit1(7),

  /// The `Digit2` key.
  digit2(8),

  /// The `Digit3` key.
  digit3(9),

  /// The `Digit4` key.
  digit4(10),

  /// The `Digit5` key.
  digit5(11),

  /// The `Digit6` key.
  digit6(12),

  /// The `Digit7` key.
  digit7(13),

  /// The `Digit8` key.
  digit8(14),

  /// The `Digit9` key.
  digit9(15),

  /// The `Equal` key.
  equal(16),

  /// The `IntlBackslash` key.
  intlBackslash(17),

  /// The `IntlRo` key.
  intlRo(18),

  /// The `IntlYen` key.
  intlYen(19),

  /// The `KeyA` key.
  a(20),

  /// The `KeyB` key.
  b(21),

  /// The `KeyC` key.
  c(22),

  /// The `KeyD` key.
  d(23),

  /// The `KeyE` key.
  e(24),

  /// The `KeyF` key.
  f(25),

  /// The `KeyG` key.
  g(26),

  /// The `KeyH` key.
  h(27),

  /// The `KeyI` key.
  i(28),

  /// The `KeyJ` key.
  j(29),

  /// The `KeyK` key.
  k(30),

  /// The `KeyL` key.
  l(31),

  /// The `KeyM` key.
  m(32),

  /// The `KeyN` key.
  n(33),

  /// The `KeyO` key.
  o(34),

  /// The `KeyP` key.
  p(35),

  /// The `KeyQ` key.
  q(36),

  /// The `KeyR` key.
  r(37),

  /// The `KeyS` key.
  s(38),

  /// The `KeyT` key.
  t(39),

  /// The `KeyU` key.
  u(40),

  /// The `KeyV` key.
  v(41),

  /// The `KeyW` key.
  w(42),

  /// The `KeyX` key.
  x(43),

  /// The `KeyY` key.
  y(44),

  /// The `KeyZ` key.
  z(45),

  /// The `Minus` key.
  minus(46),

  /// The `Period` key.
  period(47),

  /// The `Quote` key.
  quote(48),

  /// The `Semicolon` key.
  semicolon(49),

  /// The `Slash` key.
  slash(50),

  // Functional Keys (W3C § 3.1.2)

  /// The `AltLeft` key.
  altLeft(51),

  /// The `AltRight` key.
  altRight(52),

  /// The `Backspace` key.
  backspace(53),

  /// The `CapsLock` key.
  capsLock(54),

  /// The `ContextMenu` key.
  contextMenu(55),

  /// The `ControlLeft` key.
  controlLeft(56),

  /// The `ControlRight` key.
  controlRight(57),

  /// The `Enter` key.
  enter(58),

  /// The `MetaLeft` key.
  metaLeft(59),

  /// The `MetaRight` key.
  metaRight(60),

  /// The `ShiftLeft` key.
  shiftLeft(61),

  /// The `ShiftRight` key.
  shiftRight(62),

  /// The `Space` key.
  space(63),

  /// The `Tab` key.
  tab(64),

  /// The `Convert` key.
  convert(65),

  /// The `KanaMode` key.
  kanaMode(66),

  /// The `NonConvert` key.
  nonConvert(67),

  // Control Pad Section (W3C § 3.2)

  /// The `Delete` key.
  delete(68),

  /// The `End` key.
  end(69),

  /// The `Help` key.
  help(70),

  /// The `Home` key.
  home(71),

  /// The `Insert` key.
  insert(72),

  /// The `PageDown` key.
  pageDown(73),

  /// The `PageUp` key.
  pageUp(74),

  // Arrow Pad Section (W3C § 3.3)

  /// The `ArrowDown` key.
  arrowDown(75),

  /// The `ArrowLeft` key.
  arrowLeft(76),

  /// The `ArrowRight` key.
  arrowRight(77),

  /// The `ArrowUp` key.
  arrowUp(78),

  // Numpad Section (W3C § 3.4)

  /// The `NumLock` key.
  numLock(79),

  /// The `Numpad0` key.
  numpad0(80),

  /// The `Numpad1` key.
  numpad1(81),

  /// The `Numpad2` key.
  numpad2(82),

  /// The `Numpad3` key.
  numpad3(83),

  /// The `Numpad4` key.
  numpad4(84),

  /// The `Numpad5` key.
  numpad5(85),

  /// The `Numpad6` key.
  numpad6(86),

  /// The `Numpad7` key.
  numpad7(87),

  /// The `Numpad8` key.
  numpad8(88),

  /// The `Numpad9` key.
  numpad9(89),

  /// The `NumpadAdd` key.
  numpadAdd(90),

  /// The `NumpadBackspace` key.
  numpadBackspace(91),

  /// The `NumpadClear` key.
  numpadClear(92),

  /// The `NumpadClearEntry` key.
  numpadClearEntry(93),

  /// The `NumpadComma` key.
  numpadComma(94),

  /// The `NumpadDecimal` key.
  numpadDecimal(95),

  /// The `NumpadDivide` key.
  numpadDivide(96),

  /// The `NumpadEnter` key.
  numpadEnter(97),

  /// The `NumpadEqual` key.
  numpadEqual(98),

  /// The `NumpadMemoryAdd` key.
  numpadMemoryAdd(99),

  /// The `NumpadMemoryClear` key.
  numpadMemoryClear(100),

  /// The `NumpadMemoryRecall` key.
  numpadMemoryRecall(101),

  /// The `NumpadMemoryStore` key.
  numpadMemoryStore(102),

  /// The `NumpadMemorySubtract` key.
  numpadMemorySubtract(103),

  /// The `NumpadMultiply` key.
  numpadMultiply(104),

  /// The `NumpadParenLeft` key.
  numpadParenLeft(105),

  /// The `NumpadParenRight` key.
  numpadParenRight(106),

  /// The `NumpadSubtract` key.
  numpadSubtract(107),

  /// The `NumpadSeparator` key.
  numpadSeparator(108),

  /// The `NumpadUp` key.
  numpadUp(109),

  /// The `NumpadDown` key.
  numpadDown(110),

  /// The `NumpadRight` key.
  numpadRight(111),

  /// The `NumpadLeft` key.
  numpadLeft(112),

  /// The `NumpadBegin` key.
  numpadBegin(113),

  /// The `NumpadHome` key.
  numpadHome(114),

  /// The `NumpadEnd` key.
  numpadEnd(115),

  /// The `NumpadInsert` key.
  numpadInsert(116),

  /// The `NumpadDelete` key.
  numpadDelete(117),

  /// The `NumpadPageUp` key.
  numpadPageUp(118),

  /// The `NumpadPageDown` key.
  numpadPageDown(119),

  // Function Section (W3C § 3.5)

  /// The `Escape` key.
  escape(120),

  /// The `F1` key.
  f1(121),

  /// The `F2` key.
  f2(122),

  /// The `F3` key.
  f3(123),

  /// The `F4` key.
  f4(124),

  /// The `F5` key.
  f5(125),

  /// The `F6` key.
  f6(126),

  /// The `F7` key.
  f7(127),

  /// The `F8` key.
  f8(128),

  /// The `F9` key.
  f9(129),

  /// The `F10` key.
  f10(130),

  /// The `F11` key.
  f11(131),

  /// The `F12` key.
  f12(132),

  /// The `F13` key.
  f13(133),

  /// The `F14` key.
  f14(134),

  /// The `F15` key.
  f15(135),

  /// The `F16` key.
  f16(136),

  /// The `F17` key.
  f17(137),

  /// The `F18` key.
  f18(138),

  /// The `F19` key.
  f19(139),

  /// The `F20` key.
  f20(140),

  /// The `F21` key.
  f21(141),

  /// The `F22` key.
  f22(142),

  /// The `F23` key.
  f23(143),

  /// The `F24` key.
  f24(144),

  /// The `F25` key.
  f25(145),

  /// The `Fn` key.
  fn(146),

  /// The `FnLock` key.
  fnLock(147),

  /// The `PrintScreen` key.
  printScreen(148),

  /// The `ScrollLock` key.
  scrollLock(149),

  /// The `Pause` key.
  pause(150),

  // Media Keys (W3C § 3.6)

  /// The `BrowserBack` key.
  browserBack(151),

  /// The `BrowserFavorites` key.
  browserFavorites(152),

  /// The `BrowserForward` key.
  browserForward(153),

  /// The `BrowserHome` key.
  browserHome(154),

  /// The `BrowserRefresh` key.
  browserRefresh(155),

  /// The `BrowserSearch` key.
  browserSearch(156),

  /// The `BrowserStop` key.
  browserStop(157),

  /// The `Eject` key.
  eject(158),

  /// The `LaunchApp1` key.
  launchApp1(159),

  /// The `LaunchApp2` key.
  launchApp2(160),

  /// The `LaunchMail` key.
  launchMail(161),

  /// The `MediaPlayPause` key.
  mediaPlayPause(162),

  /// The `MediaSelect` key.
  mediaSelect(163),

  /// The `MediaStop` key.
  mediaStop(164),

  /// The `MediaTrackNext` key.
  mediaTrackNext(165),

  /// The `MediaTrackPrevious` key.
  mediaTrackPrevious(166),

  /// The `Power` key.
  power(167),

  /// The `Sleep` key.
  sleep(168),

  /// The `AudioVolumeDown` key.
  audioVolumeDown(169),

  /// The `AudioVolumeMute` key.
  audioVolumeMute(170),

  /// The `AudioVolumeUp` key.
  audioVolumeUp(171),

  /// The `WakeUp` key.
  wakeUp(172),

  // Legacy, Non-standard, and Special Keys (W3C § 3.7)

  /// The `Copy` key.
  copy(173),

  /// The `Cut` key.
  cut(174),

  /// The `Paste` key.
  paste(175),

  /// A key added by a later libghostty-vt release.
  unknown(null);

  const VtKey(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyKey` values to [VtKey] and back.
final vtKeyCodec = RawEnumCodec<VtKey>(
  VtKey.values,
  raw: (v) => v._raw,
  unknown: VtKey.unknown,
);

/// What happened to a key (`GhosttyKeyAction`).
enum KeyAction {
  /// The key was released.
  release(0),

  /// The key was pressed.
  press(1),

  /// The key is held down and the platform repeats it.
  repeat(2),

  /// An action added by a later libghostty-vt release.
  unknown(null);

  const KeyAction(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyKeyAction` values to [KeyAction] and back.
final keyActionCodec = RawEnumCodec<KeyAction>(
  KeyAction.values,
  raw: (v) => v._raw,
  unknown: KeyAction.unknown,
);

/// One keyboard event, as input to `KeyEncoder.encode`.
///
/// An immutable value: build one per platform key event. The encoder copies
/// it into a native key event that it reuses, so creating these costs no
/// native allocation.
///
/// ```dart
/// // Ctrl+C on a US layout.
/// const event = VtKeyEvent(
///   key: VtKey.c,
///   modifiers: KeyModifiers.ctrl,
///   text: 'c',
///   unshiftedCodepoint: 0x63,
/// );
/// ```
///
/// Named `VtKeyEvent` because `KeyEvent` clashes with Flutter's `KeyEvent`.
final class VtKeyEvent {
  /// Creates a key event. Only [key] is required; the other fields default
  /// to a plain press with no modifiers and no text.
  ///
  /// See each field for what the encoder expects in it.
  const VtKeyEvent({
    required this.key,
    this.action = KeyAction.press,
    this.modifiers = KeyModifiers.none,
    this.consumedModifiers = KeyModifiers.none,
    this.isComposing = false,
    this.text = '',
    this.unshiftedCodepoint = 0,
  });

  /// The physical key.
  final VtKey key;

  /// Press, release or repeat. Releases only produce output with the Kitty
  /// protocol's [KittyKeyboardFlags.reportEvents] flag.
  final KeyAction action;

  /// The modifiers held during the event.
  final KeyModifiers modifiers;

  /// The modifiers the platform already used to produce [text] (for example
  /// Shift for "A", or Option for "å" on macOS). The encoder does not
  /// report them again as modifiers.
  final KeyModifiers consumedModifiers;

  /// Whether the event is part of an IME composition sequence. Composing
  /// events normally produce no output.
  final bool isComposing;

  /// The text the key produces for the current layout, before any Ctrl or
  /// Meta transformation (for Ctrl+C this is `'c'`, not `'\x03'`).
  ///
  /// Leave it empty for keys that do not produce text, and never put C0
  /// control characters (U+0000–U+001F, U+007F) or platform function-key
  /// codes (macOS U+F700–U+F8FF) here: the encoder then falls back to
  /// [key], as the header requires.
  final String text;

  /// The Unicode codepoint the key produces with no modifiers applied
  /// (`0x61` for the "a" key on a US layout), or 0 if unknown. Used by the
  /// Kitty protocol and modifier encodings.
  final int unshiftedCodepoint;

  /// A copy with the given fields replaced.
  VtKeyEvent copyWith({
    VtKey? key,
    KeyAction? action,
    KeyModifiers? modifiers,
    KeyModifiers? consumedModifiers,
    bool? isComposing,
    String? text,
    int? unshiftedCodepoint,
  }) => VtKeyEvent(
    key: key ?? this.key,
    action: action ?? this.action,
    modifiers: modifiers ?? this.modifiers,
    consumedModifiers: consumedModifiers ?? this.consumedModifiers,
    isComposing: isComposing ?? this.isComposing,
    text: text ?? this.text,
    unshiftedCodepoint: unshiftedCodepoint ?? this.unshiftedCodepoint,
  );

  @override
  bool operator ==(Object other) =>
      other is VtKeyEvent &&
      other.key == key &&
      other.action == action &&
      other.modifiers == modifiers &&
      other.consumedModifiers == consumedModifiers &&
      other.isComposing == isComposing &&
      other.text == text &&
      other.unshiftedCodepoint == unshiftedCodepoint;

  @override
  int get hashCode => Object.hash(
    key,
    action,
    modifiers,
    consumedModifiers,
    isComposing,
    text,
    unshiftedCodepoint,
  );

  @override
  String toString() =>
      'VtKeyEvent(${key.name}, ${action.name}, $modifiers'
      '${consumedModifiers.isEmpty ? '' : ', consumed: $consumedModifiers'}'
      '${isComposing ? ', composing' : ''}'
      '${text.isEmpty ? '' : ', text: ${_quote(text)}'}'
      '${unshiftedCodepoint == 0 ? '' : ', unshifted: U+${unshiftedCodepoint.toRadixString(16).toUpperCase()}'})';
}

String _quote(String text) => "'${text.replaceAll("'", r"\'")}'";

/// Whether the macOS Option key acts as Alt (`GhosttyOptionAsAlt`, the
/// Ghostty `macos-option-as-alt` setting).
///
/// The C values are `FALSE`, `TRUE`, `LEFT` and `RIGHT`; `false`/`true` are
/// Dart keywords, hence [none] and [both].
enum OptionAsAlt {
  /// Option is not Alt: it produces the layout's characters (the default).
  none(0),

  /// Both Option keys act as Alt.
  both(1),

  /// Only the left Option key acts as Alt.
  left(2),

  /// Only the right Option key acts as Alt.
  right(3),

  /// A value added by a later libghostty-vt release.
  unknown(null);

  const OptionAsAlt(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyOptionAsAlt` values to [OptionAsAlt] and back.
final optionAsAltCodec = RawEnumCodec<OptionAsAlt>(
  OptionAsAlt.values,
  raw: (v) => v._raw,
  unknown: OptionAsAlt.unknown,
);
