/// Keyboard modifier flags (`GhosttyMods` in `key/event.h`), shared by key
/// and mouse events.
library;

/// The modifier keys held during a key or mouse event (`GhosttyMods`).
///
/// Immutable. Combine with `|`:
///
/// ```dart
/// final mods = KeyModifiers.ctrl | KeyModifiers.shift;
/// ```
///
/// The `right*` flags say which side of a modifier is pressed. They are only
/// meaningful when the modifier itself is set, and not every platform
/// reports them.
final class KeyModifiers {
  /// A set of modifiers from individual flags.
  const KeyModifiers({
    bool shift = false,
    bool ctrl = false,
    bool alt = false,
    bool superKey = false,
    bool capsLock = false,
    bool numLock = false,
    bool rightShift = false,
    bool rightCtrl = false,
    bool rightAlt = false,
    bool rightSuper = false,
  }) : _bits =
           (shift ? _shift : 0) |
           (ctrl ? _ctrl : 0) |
           (alt ? _alt : 0) |
           (superKey ? _super : 0) |
           (capsLock ? _capsLock : 0) |
           (numLock ? _numLock : 0) |
           (rightShift ? _shiftSide : 0) |
           (rightCtrl ? _ctrlSide : 0) |
           (rightAlt ? _altSide : 0) |
           (rightSuper ? _superSide : 0);

  const KeyModifiers._(this._bits);

  static const _shift = 1 << 0;
  static const _ctrl = 1 << 1;
  static const _alt = 1 << 2;
  static const _super = 1 << 3;
  static const _capsLock = 1 << 4;
  static const _numLock = 1 << 5;
  static const _shiftSide = 1 << 6;
  static const _ctrlSide = 1 << 7;
  static const _altSide = 1 << 8;
  static const _superSide = 1 << 9;

  /// No modifiers.
  static const none = KeyModifiers._(0);

  /// Only Shift.
  static const shift = KeyModifiers._(_shift);

  /// Only Control.
  static const ctrl = KeyModifiers._(_ctrl);

  /// Only Alt/Option.
  static const alt = KeyModifiers._(_alt);

  /// Only Super/Command/Windows.
  static const superKey = KeyModifiers._(_super);

  /// Only Caps Lock.
  static const capsLock = KeyModifiers._(_capsLock);

  /// Only Num Lock.
  static const numLock = KeyModifiers._(_numLock);

  /// The raw `GhosttyMods` bits. Unknown bits from a newer library are kept
  /// so values round-trip unchanged.
  final int _bits;

  /// Whether Shift is pressed.
  bool get hasShift => _bits & _shift != 0;

  /// Whether Control is pressed.
  bool get hasCtrl => _bits & _ctrl != 0;

  /// Whether Alt/Option is pressed.
  bool get hasAlt => _bits & _alt != 0;

  /// Whether Super/Command/Windows is pressed.
  bool get hasSuper => _bits & _super != 0;

  /// Whether Caps Lock is active.
  bool get hasCapsLock => _bits & _capsLock != 0;

  /// Whether Num Lock is active.
  bool get hasNumLock => _bits & _numLock != 0;

  /// Whether the pressed Shift is the right one.
  bool get isRightShift => _bits & _shiftSide != 0;

  /// Whether the pressed Control is the right one.
  bool get isRightCtrl => _bits & _ctrlSide != 0;

  /// Whether the pressed Alt is the right one.
  bool get isRightAlt => _bits & _altSide != 0;

  /// Whether the pressed Super is the right one.
  bool get isRightSuper => _bits & _superSide != 0;

  /// Whether no modifier flag is set.
  bool get isEmpty => _bits == 0;

  /// Whether every flag set in [other] is also set here.
  bool containsAll(KeyModifiers other) => _bits & other._bits == other._bits;

  /// The union of both sets.
  KeyModifiers operator |(KeyModifiers other) =>
      KeyModifiers._(_bits | other._bits);

  /// The flags set in both.
  KeyModifiers operator &(KeyModifiers other) =>
      KeyModifiers._(_bits & other._bits);

  @override
  bool operator ==(Object other) =>
      other is KeyModifiers && other._bits == _bits;

  @override
  int get hashCode => Object.hash(KeyModifiers, _bits);

  @override
  String toString() {
    final names = <String>[
      if (hasShift) isRightShift ? 'rightShift' : 'shift',
      if (hasCtrl) isRightCtrl ? 'rightCtrl' : 'ctrl',
      if (hasAlt) isRightAlt ? 'rightAlt' : 'alt',
      if (hasSuper) isRightSuper ? 'rightSuper' : 'super',
      if (hasCapsLock) 'capsLock',
      if (hasNumLock) 'numLock',
    ];
    return 'KeyModifiers(${names.join(' | ')})';
  }
}

/// The raw `GhosttyMods` value of [modifiers].
int keyModifiersToRaw(KeyModifiers modifiers) => modifiers._bits;

/// Decodes a raw `GhosttyMods` value, keeping unknown bits.
KeyModifiers keyModifiersFromRaw(int raw) => KeyModifiers._(raw & 0xFFFF);
