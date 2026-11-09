import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/expect_support.dart';
import '../support/terminal_support.dart';

/// The encoded bytes as a readable string (`ESC` for 0x1b).

const _arrowUp = VtKeyEvent(key: VtKey.arrowUp);
const _ctrlC = VtKeyEvent(
  key: VtKey.c,
  modifiers: KeyModifiers.ctrl,
  text: 'c',
  unshiftedCodepoint: 0x63,
);

void main() {
  late KeyEncoder encoder;

  setUp(() => encoder = KeyEncoder());
  tearDown(() => encoder.dispose());

  group('legacy encoding', () {
    test('plain text keys send their text', () {
      final bytes = encoder.encode(
        const VtKeyEvent(key: VtKey.a, text: 'a', unshiftedCodepoint: 0x61),
      );
      expect(utf8.decode(bytes), 'a');
    });

    test('non-ASCII text is sent as UTF-8', () {
      final bytes = encoder.encode(
        const VtKeyEvent(key: VtKey.semicolon, text: 'ñ'),
      );
      expect(bytes, utf8.encode('ñ'));
    });

    test('Ctrl+C is 0x03', () {
      expect(encoder.encode(_ctrlC), [0x03]);
    });

    test('Enter, Tab, Escape and Backspace', () {
      expect(encoder.encode(const VtKeyEvent(key: VtKey.enter)), [0x0d]);
      expect(encoder.encode(const VtKeyEvent(key: VtKey.tab)), [0x09]);
      expect(encoder.encode(const VtKeyEvent(key: VtKey.escape)), [0x1b]);
      expect(encoder.encode(const VtKeyEvent(key: VtKey.backspace)), [0x7f]);
    });

    test('backarrowKeyMode makes Backspace send 0x08', () {
      encoder.configure(backarrowKeyMode: true);
      expect(encoder.encode(const VtKeyEvent(key: VtKey.backspace)), [0x08]);
    });

    test('lone modifiers and releases produce no output', () {
      expect(encoder.encode(const VtKeyEvent(key: VtKey.shiftLeft)), isEmpty);
      expect(
        encoder.encode(_ctrlC.copyWith(action: KeyAction.release)),
        isEmpty,
      );
    });

    test('modified arrows use the CSI 1;mod form', () {
      final bytes = encoder.encode(
        _arrowUp.copyWith(modifiers: KeyModifiers.shift),
      );
      expect(showEscapes(bytes), 'ESC[1;2A');
    });

    test('F1 and Delete', () {
      expect(
        showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.f1))),
        'ESCOP',
      );
      expect(
        showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.delete))),
        'ESC[3~',
      );
    });
  });

  group('cursor key application mode', () {
    test('arrows are CSI in normal mode and SS3 in application mode', () {
      withTerminal(80, 24, (terminal) {
        encoder.setFromTerminal(terminal);
        expect(showEscapes(encoder.encode(_arrowUp)), 'ESC[A');

        writeText(terminal, '\x1b[?1h');
        encoder.setFromTerminal(terminal);
        expect(showEscapes(encoder.encode(_arrowUp)), 'ESCOA');

        writeText(terminal, '\x1b[?1l');
        encoder.setFromTerminal(terminal);
        expect(showEscapes(encoder.encode(_arrowUp)), 'ESC[A');
      });
    });

    test('configure sets the same mode without a terminal', () {
      encoder.configure(cursorKeyApplication: true);
      expect(showEscapes(encoder.encode(_arrowUp)), 'ESCOA');
      encoder.configure(cursorKeyApplication: false);
      expect(showEscapes(encoder.encode(_arrowUp)), 'ESC[A');
    });

    test('resetOptions restores the defaults', () {
      encoder.configure(
        cursorKeyApplication: true,
        kittyFlags: KittyKeyboardFlags.all,
        macosOptionAsAlt: OptionAsAlt.both,
        backarrowKeyMode: true,
      );
      encoder.resetOptions();
      expect(showEscapes(encoder.encode(_arrowUp)), 'ESC[A');
      expect(encoder.encode(_ctrlC), [0x03]);
      expect(encoder.encode(const VtKeyEvent(key: VtKey.backspace)), [0x7f]);
    });
  });

  group('Kitty keyboard protocol', () {
    test('flags pushed by the program are picked up from the terminal', () {
      withTerminal(80, 24, (terminal) {
        writeText(terminal, '\x1b[>1u');
        encoder.setFromTerminal(terminal);
        expect(showEscapes(encoder.encode(_ctrlC)), 'ESC[99;5u');
        expect(
          showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.escape))),
          'ESC[27u',
        );
        // Plain text is still plain text with only "disambiguate".
        expect(
          utf8.decode(
            encoder.encode(
              const VtKeyEvent(
                key: VtKey.a,
                text: 'a',
                unshiftedCodepoint: 0x61,
              ),
            ),
          ),
          'a',
        );

        writeText(terminal, '\x1b[<u');
        encoder.setFromTerminal(terminal);
        expect(encoder.encode(_ctrlC), [0x03]);
      });
    });

    test('reportEvents reports releases', () {
      encoder.configure(
        kittyFlags:
            KittyKeyboardFlags.disambiguate | KittyKeyboardFlags.reportEvents,
      );
      final release = encoder.encode(
        const VtKeyEvent(
          key: VtKey.a,
          action: KeyAction.release,
          unshiftedCodepoint: 0x61,
        ),
      );
      expect(showEscapes(release), 'ESC[97;1:3u');
    });

    test('output longer than the initial buffer is retried and complete', () {
      encoder.configure(
        kittyFlags:
            KittyKeyboardFlags.reportAll | KittyKeyboardFlags.reportAssociated,
      );
      final text = 'a' * 40;
      final bytes = encoder.encode(
        VtKeyEvent(key: VtKey.a, text: text, unshiftedCodepoint: 0x61),
      );
      final shown = showEscapes(bytes);
      expect(bytes.length, greaterThan(64));
      expect(shown, startsWith('ESC[97;;97:97'));
      expect(shown, endsWith('u'));
      expect(':'.allMatches(shown).length, 39);
    });
  });

  group('event reuse', () {
    test('alternating events encode independently', () {
      for (var i = 0; i < 3; i++) {
        expect(encoder.encode(_ctrlC), [0x03]);
        expect(showEscapes(encoder.encode(_arrowUp)), 'ESC[A');
        expect(
          utf8.decode(
            encoder.encode(const VtKeyEvent(key: VtKey.b, text: 'b')),
          ),
          'b',
        );
      }
    });

    test('changing only the text re-sets it', () {
      expect(
        utf8.decode(encoder.encode(const VtKeyEvent(key: VtKey.a, text: 'a'))),
        'a',
      );
      expect(
        utf8.decode(encoder.encode(const VtKeyEvent(key: VtKey.a, text: 'A'))),
        'A',
      );
      expect(
        encoder.encode(VtKeyEvent(key: VtKey.a, text: 'é' * 100)),
        utf8.encode('é' * 100),
      );
      expect(encoder.encode(const VtKeyEvent(key: VtKey.shiftLeft)), isEmpty);
    });
  });

  group('errors', () {
    test('unknown enum values are rejected before any native call', () {
      expect(
        () => encoder.encode(const VtKeyEvent(key: VtKey.unknown)),
        throwsArgumentError,
      );
      expect(
        () => encoder.encode(
          const VtKeyEvent(key: VtKey.a, action: KeyAction.unknown),
        ),
        throwsArgumentError,
      );
      expect(
        () => encoder.configure(macosOptionAsAlt: OptionAsAlt.unknown),
        throwsArgumentError,
      );
      // The encoder still works afterwards.
      expect(encoder.encode(_ctrlC), [0x03]);
    });

    test('an out-of-range codepoint is a RangeError', () {
      expect(
        () => encoder.encode(
          const VtKeyEvent(key: VtKey.a, unshiftedCodepoint: 0x110000),
        ),
        throwsRangeError,
      );
      expect(
        () => encoder.encode(
          const VtKeyEvent(key: VtKey.a, unshiftedCodepoint: -1),
        ),
        throwsRangeError,
      );
    });

    test('every option value is accepted', () {
      for (final option in OptionAsAlt.values) {
        if (option == OptionAsAlt.unknown) continue;
        encoder.configure(macosOptionAsAlt: option);
      }
      encoder.configure(
        keypadKeyApplication: true,
        ignoreKeypadWithNumLock: true,
        altEscPrefix: true,
        modifyOtherKeysState2: true,
      );
      expect(encoder.encode(_ctrlC), isNotEmpty);
    });
  });

  group('dispose', () {
    test('is idempotent and blocks further use', () {
      final local = KeyEncoder();
      expect(local.isDisposed, isFalse);
      local.encode(_ctrlC);
      local.dispose();
      local.dispose();
      expect(local.isDisposed, isTrue);
      expect(
        () => local.encode(_ctrlC),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'KeyEncoder has been disposed',
          ),
        ),
      );
      expect(() => local.configure(altEscPrefix: true), throwsStateError);
      expect(local.resetOptions, throwsStateError);
      withTerminal(10, 2, (t) {
        expect(() => local.setFromTerminal(t), throwsStateError);
      });
    });

    test('setFromTerminal with a disposed terminal throws', () {
      final terminal = VtTerminal(cols: 10, rows: 2)..dispose();
      expect(() => encoder.setFromTerminal(terminal), throwsStateError);
    });

    test('the encoder does not depend on the terminal staying alive', () {
      final terminal = VtTerminal(cols: 10, rows: 2);
      writeText(terminal, '\x1b[?1h');
      encoder.setFromTerminal(terminal);
      terminal.dispose();
      expect(showEscapes(encoder.encode(_arrowUp)), 'ESCOA');
    });
  });
}
