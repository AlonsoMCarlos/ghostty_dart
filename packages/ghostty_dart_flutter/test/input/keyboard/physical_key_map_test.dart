import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/src/input/keyboard/key_event_mapper.dart';
import 'package:ghostty_dart_flutter/src/input/keyboard/physical_key_map.dart';

void main() {
  test('maps physical keys by their W3C code, independent of layout', () {
    expect(vtKeyForPhysicalKey(PhysicalKeyboardKey.keyA), VtKey.a);
    expect(vtKeyForPhysicalKey(PhysicalKeyboardKey.keyZ), VtKey.z);
    expect(vtKeyForPhysicalKey(PhysicalKeyboardKey.digit0), VtKey.digit0);
    expect(vtKeyForPhysicalKey(PhysicalKeyboardKey.enter), VtKey.enter);
    expect(
      vtKeyForPhysicalKey(PhysicalKeyboardKey.numpadEnter),
      VtKey.numpadEnter,
    );
    expect(vtKeyForPhysicalKey(PhysicalKeyboardKey.arrowUp), VtKey.arrowUp);
    expect(vtKeyForPhysicalKey(PhysicalKeyboardKey.f24), VtKey.f24);
    expect(
      vtKeyForPhysicalKey(PhysicalKeyboardKey.intlBackslash),
      VtKey.intlBackslash,
    );
    expect(vtKeyForPhysicalKey(PhysicalKeyboardKey.altRight), VtKey.altRight);
    expect(
      vtKeyForPhysicalKey(PhysicalKeyboardKey.gameButtonA),
      VtKey.unidentified,
    );
  });

  test('every VtKey Flutter can name is in the table, each once', () {
    // Keys with no Flutter physical key (W3C reports the numpad navigation
    // variants as the digit keys with Num Lock off).
    const absent = {
      VtKey.unidentified,
      VtKey.unknown,
      VtKey.numpadSeparator,
      VtKey.numpadUp,
      VtKey.numpadDown,
      VtKey.numpadRight,
      VtKey.numpadLeft,
      VtKey.numpadBegin,
      VtKey.numpadHome,
      VtKey.numpadEnd,
      VtKey.numpadInsert,
      VtKey.numpadDelete,
      VtKey.numpadPageUp,
      VtKey.numpadPageDown,
      VtKey.f25,
    };
    final mapped = physicalKeyToVtKey.values.toSet();
    expect(mapped, hasLength(physicalKeyToVtKey.length));
    expect(mapped, VtKey.values.toSet().difference(absent));
    // The names agree (keyA ↔ a, otherwise identical).
    for (final MapEntry(:key, :value) in physicalKeyToVtKey.entries) {
      final name = key.debugName!.replaceAll(' ', '').toLowerCase();
      final vtName = value.name.length == 1
          ? 'key${value.name}'
          : value.name.toLowerCase();
      expect(name, vtName, reason: '$key');
    }
  });

  test('text keys are the writing-system keys and Space', () {
    expect(isTextKey(VtKey.a), isTrue);
    expect(isTextKey(VtKey.slash), isTrue);
    expect(isTextKey(VtKey.intlYen), isTrue);
    expect(isTextKey(VtKey.space), isTrue);
    expect(isTextKey(VtKey.enter), isFalse);
    expect(isTextKey(VtKey.numpad1), isFalse);
    expect(isTextKey(VtKey.unidentified), isFalse);
  });

  test('encodable text drops controls and macOS function-key codes', () {
    expect(KeyEventMapper.encodableText('a'), 'a');
    expect(KeyEventMapper.encodableText('é'), 'é');
    expect(KeyEventMapper.encodableText(null), '');
    expect(KeyEventMapper.encodableText('\x03'), '');
    expect(KeyEventMapper.encodableText('\x7f'), '');
    expect(KeyEventMapper.encodableText(''), '');
  });

  test('unshifted codepoint comes from Unicode logical keys only', () {
    expect(KeyEventMapper.unshiftedCodepointOf(LogicalKeyboardKey.keyA), 0x61);
    expect(
      KeyEventMapper.unshiftedCodepointOf(LogicalKeyboardKey.digit1),
      0x31,
    );
    expect(KeyEventMapper.unshiftedCodepointOf(LogicalKeyboardKey.enter), 0);
    expect(KeyEventMapper.unshiftedCodepointOf(LogicalKeyboardKey.arrowUp), 0);
  });

  test('characters from a soft keyboard map to US keys', () {
    expect(
      keyEventForCharacter('c', KeyModifiers.ctrl),
      const VtKeyEvent(
        key: VtKey.c,
        modifiers: KeyModifiers.ctrl,
        text: 'c',
        unshiftedCodepoint: 0x63,
      ),
    );
    final upper = keyEventForCharacter('C', KeyModifiers.alt);
    expect(upper.key, VtKey.c);
    expect(upper.modifiers, KeyModifiers.alt | KeyModifiers.shift);
    expect(upper.consumedModifiers, KeyModifiers.shift);
    expect(upper.unshiftedCodepoint, 0x63);
    expect(keyEventForCharacter('7', KeyModifiers.ctrl).key, VtKey.digit7);
    expect(keyEventForCharacter('[', KeyModifiers.ctrl).key, VtKey.bracketLeft);
    expect(
      keyEventForCharacter('ñ', KeyModifiers.ctrl).key,
      VtKey.unidentified,
    );
  });

  test('the VtKey ranges the index arithmetic relies on', () {
    List<String> names(VtKey first, VtKey last) => VtKey.values
        .sublist(first.index, last.index + 1)
        .map((key) => key.name)
        .toList();
    expect(names(VtKey.a, VtKey.z), 'abcdefghijklmnopqrstuvwxyz'.split(''));
    expect(names(VtKey.digit0, VtKey.digit9), [
      for (var i = 0; i < 10; i++) 'digit$i',
    ]);
    expect(names(VtKey.backquote, VtKey.slash).first, 'backquote');
    expect(names(VtKey.backquote, VtKey.slash), hasLength(50));
    expect(names(VtKey.backquote, VtKey.slash), isNot(contains('altLeft')));
  });

  test('the table cannot be modified', () {
    expect(
      () => physicalKeyToVtKey[PhysicalKeyboardKey.gameButtonA] = VtKey.a,
      throwsUnsupportedError,
    );
  });
}
