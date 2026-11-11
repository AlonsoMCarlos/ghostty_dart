import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';
import 'package:ghostty_dart_xterm/src/core/input/keytab/keytab.dart';

import '../fake_state.dart';

void main() {
  late FakeState state;

  TerminalKeyboardEvent event(
    TerminalKey key, {
    bool shift = false,
    bool ctrl = false,
    bool alt = false,
    bool altBuffer = false,
    TerminalTargetPlatform platform = TerminalTargetPlatform.linux,
  }) {
    return TerminalKeyboardEvent(
      key: key,
      shift: shift,
      ctrl: ctrl,
      alt: alt,
      state: state,
      altBuffer: altBuffer,
      platform: platform,
    );
  }

  setUp(() => state = FakeState());

  group('defaultInputHandler', () {
    String? input(
      TerminalKey key, {
      bool shift = false,
      bool ctrl = false,
      bool alt = false,
      bool altBuffer = false,
      TerminalTargetPlatform platform = TerminalTargetPlatform.linux,
    }) {
      return defaultInputHandler(
        event(
          key,
          shift: shift,
          ctrl: ctrl,
          alt: alt,
          altBuffer: altBuffer,
          platform: platform,
        ),
      );
    }

    test('is the const cascade of the keytab, Ctrl and Alt handlers', () {
      expect(
        identical(
          defaultInputHandler,
          const CascadeInputHandler([
            KeytabInputHandler(),
            CtrlInputHandler(),
            AltInputHandler(),
          ]),
        ),
        isTrue,
      );
    });

    test('sends the keytab bytes for plain keys', () {
      expect(input(TerminalKey.enter), '\r');
      expect(input(TerminalKey.numpadEnter), '\r');
      expect(input(TerminalKey.returnKey), '\r');
      expect(input(TerminalKey.escape), '\x1b');
      expect(input(TerminalKey.tab), '\t');
      expect(input(TerminalKey.backspace), '\x7f');
      expect(input(TerminalKey.delete), '\x1b[3~');
      expect(input(TerminalKey.f1), '\x1bOP');
      expect(input(TerminalKey.f5), '\x1b[15~');
      expect(input(TerminalKey.home), '\x1b[H');
    });

    test('Enter follows line feed mode', () {
      state.lineFeedMode = true;
      expect(input(TerminalKey.enter), '\r\n');
      expect(input(TerminalKey.returnKey), '\r\n');
    });

    test('arrows follow cursor keys mode (DECCKM), not keypad mode', () {
      expect(input(TerminalKey.arrowUp), '\x1b[A');
      expect(input(TerminalKey.arrowLeft), '\x1b[D');

      // xterm 4.0.0 switched the arrows on appKeypadMode; the port does not.
      state.appKeypadMode = true;
      expect(input(TerminalKey.arrowUp), '\x1b[A');

      state
        ..appKeypadMode = false
        ..cursorKeysMode = true;
      expect(input(TerminalKey.arrowUp), '\x1bOA');
      expect(input(TerminalKey.arrowRight), '\x1bOC');
      expect(input(TerminalKey.home), '\x1bOH');
      expect(input(TerminalKey.end), '\x1bOF');
    });

    test('inserts the modifier parameter into keytab actions', () {
      expect(input(TerminalKey.delete, ctrl: true), '\x1b[3;5~');
      expect(input(TerminalKey.pageUp, ctrl: true), '\x1b[5;5~');
      expect(input(TerminalKey.home, alt: true), '\x1b[1;3H');
      expect(input(TerminalKey.insert, shift: true), '\x1b[2;2~');
      expect(input(TerminalKey.arrowUp, ctrl: true), '\x1b[1;5A');
      expect(input(TerminalKey.tab, shift: true), '\x1b[Z');
      expect(input(TerminalKey.backspace, ctrl: true), '\b');
    });

    test('Alt+arrow depends on the platform', () {
      expect(input(TerminalKey.arrowRight, alt: true), '\x1b[1;5C');
      expect(
        input(
          TerminalKey.arrowRight,
          alt: true,
          platform: TerminalTargetPlatform.macos,
        ),
        '\x1bf',
      );
    });

    test('Shift+Up sends what xterm 4.0.0 sends', () {
      // `key Up -Shift+AnyMod+Ansi` comes first and `+AnyMod` skips the
      // Shift check, so neither `Up +Shift+AppScreen` nor the
      // `scrollLineUp` shortcut line ever matches.
      expect(input(TerminalKey.arrowUp, shift: true), '\x1b[1;5A');
      expect(
        input(TerminalKey.arrowUp, shift: true, altBuffer: true),
        '\x1b[1;5A',
      );
      expect(input(TerminalKey.pageUp, shift: true), '\x1b[5;2~');
    });

    test('falls through to the Ctrl and Alt handlers', () {
      expect(input(TerminalKey.keyC, ctrl: true), '\x03');
      expect(input(TerminalKey.keyA, ctrl: true), '\x01');
      expect(input(TerminalKey.keyZ, ctrl: true), '\x1a');
      expect(input(TerminalKey.keyB, alt: true), '\x1bB');
      expect(
        input(
          TerminalKey.keyB,
          alt: true,
          platform: TerminalTargetPlatform.macos,
        ),
        isNull,
      );
      expect(input(TerminalKey.keyA), isNull);
      expect(input(TerminalKey.digit1, ctrl: true), isNull);
    });
  });

  group('KeytabInputHandler', () {
    test('uses its own keytab', () {
      final handler = KeytabInputHandler(Keytab.parse(r'key F1 : "\E[1;*P"'));
      expect(handler(event(TerminalKey.f1)), '\x1b[1;*P');
      expect(handler(event(TerminalKey.f1, shift: true)), '\x1b[1;2P');
      expect(handler(event(TerminalKey.f2)), isNull);
    });

    test('sends a matching shortcut line\'s name as text', () {
      final handler = KeytabInputHandler(
        Keytab.parse('key PgUp +Shift : scrollPageUp'),
      );
      expect(handler(event(TerminalKey.pageUp, shift: true)), 'scrollPageUp');
    });

    test('insertModifiers maps each combination to xterm\'s code', () {
      const handler = KeytabInputHandler();
      String codeFor({
        bool shift = false,
        bool ctrl = false,
        bool alt = false,
      }) {
        return handler.insertModifiers(
          event(TerminalKey.f1, shift: shift, ctrl: ctrl, alt: alt),
          '*',
        );
      }

      expect(codeFor(), '*');
      expect(codeFor(shift: true), '2');
      expect(codeFor(alt: true), '3');
      expect(codeFor(shift: true, alt: true), '4');
      expect(codeFor(ctrl: true), '5');
      expect(codeFor(shift: true, ctrl: true), '6');
      expect(codeFor(ctrl: true, alt: true), '7');
      expect(codeFor(shift: true, ctrl: true, alt: true), '8');
    });
  });

  group('CtrlInputHandler', () {
    const handler = CtrlInputHandler();

    test('maps Ctrl+letter to C0 controls', () {
      for (var i = 0; i < 26; i++) {
        final key = TerminalKey.values[TerminalKey.keyA.index + i];
        expect(handler(event(key, ctrl: true)), String.fromCharCode(i + 1));
      }
    });

    test('ignores other keys and other modifier combinations', () {
      expect(handler(event(TerminalKey.keyA)), isNull);
      expect(handler(event(TerminalKey.keyA, ctrl: true, shift: true)), isNull);
      expect(handler(event(TerminalKey.keyA, ctrl: true, alt: true)), isNull);
      expect(handler(event(TerminalKey.enter, ctrl: true)), isNull);
    });
  });

  group('AltInputHandler', () {
    const handler = AltInputHandler();

    test('maps Alt+letter to ESC and the upper-case letter', () {
      expect(handler(event(TerminalKey.keyA, alt: true)), '\x1bA');
      expect(handler(event(TerminalKey.keyZ, alt: true)), '\x1bZ');
    });

    test('ignores macOS, other keys and other modifiers', () {
      expect(
        handler(
          event(
            TerminalKey.keyA,
            alt: true,
            platform: TerminalTargetPlatform.macos,
          ),
        ),
        isNull,
      );
      expect(handler(event(TerminalKey.digit1, alt: true)), isNull);
      expect(handler(event(TerminalKey.keyA, alt: true, ctrl: true)), isNull);
      expect(handler(event(TerminalKey.keyA, alt: true, shift: true)), isNull);
    });
  });

  group('CascadeInputHandler', () {
    test('returns the first non-null result, in order', () {
      final calls = <String>[];
      final handler = CascadeInputHandler([
        _Recording('a', null, calls),
        _Recording('b', 'B', calls),
        _Recording('c', 'C', calls),
      ]);
      expect(handler(event(TerminalKey.keyA)), 'B');
      expect(calls, ['a', 'b']);
    });

    test('returns null when every handler does', () {
      expect(const CascadeInputHandler([])(event(TerminalKey.keyA)), isNull);
    });

    test('lets a handler run before the default one', () {
      final handler = CascadeInputHandler([
        _Recording('custom', 'X', []),
        defaultInputHandler,
      ]);
      expect(handler(event(TerminalKey.enter)), 'X');
    });
  });

  test('TerminalKeyboardEvent.copyWith replaces only the given fields', () {
    final original = event(TerminalKey.keyA, ctrl: true);
    final other = FakeState();
    final copy = original.copyWith(
      key: TerminalKey.keyB,
      alt: true,
      state: other,
      altBuffer: true,
      platform: TerminalTargetPlatform.macos,
    );
    expect(copy.key, TerminalKey.keyB);
    expect(copy.shift, isFalse);
    expect(copy.ctrl, isTrue);
    expect(copy.alt, isTrue);
    expect(copy.state, same(other));
    expect(copy.altBuffer, isTrue);
    expect(copy.platform, TerminalTargetPlatform.macos);

    final same0 = original.copyWith();
    expect(same0.key, original.key);
    expect(same0.state, same(original.state));
    expect(same0.platform, original.platform);
  });
}

class _Recording implements TerminalInputHandler {
  _Recording(this.name, this.result, this.calls);

  final String name;
  final String? result;
  final List<String> calls;

  @override
  String? call(TerminalKeyboardEvent event) {
    calls.add(name);
    return result;
  }
}
