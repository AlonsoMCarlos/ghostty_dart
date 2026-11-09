// Adversarial tests from the correctness review of the input encoders.
//
// Expected byte sequences come from the xterm control sequences document,
// the Kitty keyboard protocol spec and the upstream Zig encoders
// (`src/input/key_encode.zig`, `src/input/mouse_encode.zig`), not from the
// wrappers' own behaviour.

import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/expect_support.dart';
import '../support/terminal_support.dart';

/// The encoded bytes as a readable string (`ESC` for 0x1b).

VtKeyEvent _char(
  VtKey key,
  String text, {
  KeyModifiers modifiers = KeyModifiers.none,
  KeyAction action = KeyAction.press,
}) => VtKeyEvent(
  key: key,
  text: text,
  modifiers: modifiers,
  action: action,
  unshiftedCodepoint: text.isEmpty ? 0 : text.toLowerCase().runes.first,
);

void main() {
  group('KeyEncoder (review)', () {
    late KeyEncoder encoder;

    setUp(() => encoder = KeyEncoder());
    tearDown(() => encoder.dispose());

    void kitty(KittyKeyboardFlags flags) =>
        encoder.configure(kittyFlags: flags);

    test('rapid alternation of different texts never leaks stale text', () {
      final texts = ['a', 'bb', '', 'ü', 'x' * 100, '日本', 'a', '', '🙂'];
      for (var round = 0; round < 3; round++) {
        for (final text in texts) {
          final bytes = encoder.encode(
            VtKeyEvent(
              key: text.isEmpty ? VtKey.f1 : VtKey.a,
              text: text,
              unshiftedCodepoint: text.isEmpty ? 0 : text.runes.first,
            ),
          );
          expect(
            utf8.decode(bytes),
            text.isEmpty ? '\x1bOP' : text,
            reason: 'text "$text"',
          );
        }
      }
    });

    test('a text that grows the native buffer is set again correctly', () {
      // The first text fits the initial 32-byte buffer; the second forces a
      // reallocation, which must not leave the event pointing at freed
      // memory.
      expect(utf8.decode(encoder.encode(_char(VtKey.a, 'a'))), 'a');
      final long = 'é' * 5000;
      final event = VtKeyEvent(
        key: VtKey.e,
        text: long,
        unshiftedCodepoint: 0xE9,
      );
      expect(utf8.decode(encoder.encode(event)), long);
      // Encoding the same event again skips every setter (cached).
      expect(utf8.decode(encoder.encode(event)), long);
      expect(utf8.decode(encoder.encode(_char(VtKey.a, 'a'))), 'a');
    });

    test('toggling modifiers on the same key', () {
      const plain = VtKeyEvent(key: VtKey.arrowUp);
      for (var i = 0; i < 4; i++) {
        expect(showEscapes(encoder.encode(plain)), 'ESC[A');
        expect(
          showEscapes(
            encoder.encode(plain.copyWith(modifiers: KeyModifiers.ctrl)),
          ),
          'ESC[1;5A',
        );
        expect(
          showEscapes(
            encoder.encode(
              plain.copyWith(modifiers: KeyModifiers.shift | KeyModifiers.alt),
            ),
          ),
          'ESC[1;4A',
        );
      }
    });

    test('right-side modifier bits still count as the modifier', () {
      const rightCtrl = KeyModifiers(ctrl: true, rightCtrl: true);
      expect(encoder.encode(_char(VtKey.c, 'c', modifiers: rightCtrl)), [0x03]);
      kitty(KittyKeyboardFlags.disambiguate | KittyKeyboardFlags.reportAll);
      // Kitty functional key codes: left control 57442, right 57448.
      expect(
        showEscapes(
          encoder.encode(
            const VtKeyEvent(key: VtKey.controlRight, modifiers: rightCtrl),
          ),
        ),
        'ESC[57448;5u',
      );
      expect(
        showEscapes(
          encoder.encode(
            const VtKeyEvent(
              key: VtKey.controlLeft,
              modifiers: KeyModifiers.ctrl,
            ),
          ),
        ),
        'ESC[57442;5u',
      );
    });

    test('legacy encoding: releases and composing events send nothing', () {
      expect(
        encoder.encode(_char(VtKey.a, 'a', action: KeyAction.release)),
        isEmpty,
      );
      expect(
        encoder.encode(
          const VtKeyEvent(key: VtKey.enter, action: KeyAction.release),
        ),
        isEmpty,
      );
      expect(
        encoder.encode(
          const VtKeyEvent(key: VtKey.a, text: 'a', isComposing: true),
        ),
        isEmpty,
      );
      // After the composing event the next plain event is encoded again.
      expect(utf8.decode(encoder.encode(_char(VtKey.a, 'a'))), 'a');
    });

    test('repeat is encoded like a press in legacy mode', () {
      expect(
        utf8.decode(
          encoder.encode(_char(VtKey.a, 'a', action: KeyAction.repeat)),
        ),
        'a',
      );
    });

    test('empty text on a printable key falls back to the logical key', () {
      expect(
        encoder.encode(
          const VtKeyEvent(
            key: VtKey.c,
            modifiers: KeyModifiers.ctrl,
            unshiftedCodepoint: 0x63,
          ),
        ),
        [0x03],
      );
    });

    test('xterm legacy sequences', () {
      expect(
        showEscapes(
          encoder.encode(
            const VtKeyEvent(key: VtKey.tab, modifiers: KeyModifiers.shift),
          ),
        ),
        'ESC[Z',
      );
      expect(
        showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.f5))),
        'ESC[15~',
      );
      expect(
        showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.pageUp))),
        'ESC[5~',
      );
      expect(
        showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.home))),
        'ESC[H',
      );
      expect(
        encoder.encode(
          const VtKeyEvent(
            key: VtKey.space,
            modifiers: KeyModifiers.ctrl,
            text: ' ',
            unshiftedCodepoint: 0x20,
          ),
        ),
        [0x00],
      );
      // Alt sends an ESC prefix only with mode 1036, which is off in a new
      // encoder but on by default in a terminal. On a macOS build Alt is the
      // Option key and produces plain text unless Option acts as Alt
      // (key_encode.zig, `isDarwin`); `both` makes this host-independent and
      // is ignored on other platforms. setFromTerminal resets it, so set it
      // after each call.
      encoder.configure(macosOptionAsAlt: OptionAsAlt.both);
      final altA = _char(VtKey.a, 'a', modifiers: KeyModifiers.alt);
      expect(utf8.decode(encoder.encode(altA)), 'a');
      withTerminal(80, 24, encoder.setFromTerminal);
      encoder.configure(macosOptionAsAlt: OptionAsAlt.both);
      expect(showEscapes(encoder.encode(altA)), 'ESCa');
    });

    test('application cursor mode switches Home/End to SS3', () {
      encoder.configure(cursorKeyApplication: true);
      expect(
        showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.home))),
        'ESCOH',
      );
      expect(
        showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.end))),
        'ESCOF',
      );
    });

    test('application keypad mode (DECKPAM) via the terminal', () {
      // Mode 1035 (ignore keypad with NumLock) is on by default in the
      // terminal and forces the numeric keypad, so turn it off first.
      withTerminal(80, 24, (terminal) {
        writeText(terminal, '\x1b=');
        encoder.setFromTerminal(terminal);
      });
      expect(utf8.decode(encoder.encode(_char(VtKey.numpad1, '1'))), '1');
      withTerminal(80, 24, (terminal) {
        writeText(terminal, '\x1b[?1035l\x1b=');
        encoder.setFromTerminal(terminal);
      });
      expect(showEscapes(encoder.encode(_char(VtKey.numpad1, '1'))), 'ESCOq');
      expect(
        showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.numpadEnter))),
        'ESCOM',
      );
    });

    test('modifyOtherKeys 2 encodes Ctrl+Shift+letter', () {
      encoder.configure(modifyOtherKeysState2: true);
      // xterm: CSI 27 ; modifier ; code ~
      expect(
        showEscapes(
          encoder.encode(
            const VtKeyEvent(
              key: VtKey.i,
              modifiers: KeyModifiers.ctrl,
              text: 'i',
              unshiftedCodepoint: 0x69,
            ),
          ),
        ),
        'ESC[27;5;105~',
      );
    });

    test('consumed modifiers are not re-applied (macOS Option text)', () {
      encoder.configure(macosOptionAsAlt: OptionAsAlt.none);
      final bytes = encoder.encode(
        const VtKeyEvent(
          key: VtKey.a,
          modifiers: KeyModifiers.alt,
          consumedModifiers: KeyModifiers.alt,
          text: 'å',
          unshiftedCodepoint: 0x61,
        ),
      );
      expect(utf8.decode(bytes), 'å');
    });

    group('Kitty protocol (spec sequences)', () {
      test('disambiguate', () {
        kitty(KittyKeyboardFlags.disambiguate);
        expect(
          showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.escape))),
          'ESC[27u',
        );
        expect(
          showEscapes(
            encoder.encode(_char(VtKey.c, 'c', modifiers: KeyModifiers.ctrl)),
          ),
          'ESC[99;5u',
        );
        expect(
          showEscapes(
            encoder.encode(_char(VtKey.a, 'a', modifiers: KeyModifiers.alt)),
          ),
          'ESC[97;3u',
        );
        // Plain text and Enter/Tab/Backspace keep their legacy bytes.
        expect(utf8.decode(encoder.encode(_char(VtKey.a, 'a'))), 'a');
        expect(encoder.encode(const VtKeyEvent(key: VtKey.enter)), [0x0D]);
        // Releases still send nothing without reportEvents.
        expect(
          encoder.encode(_char(VtKey.a, 'a', action: KeyAction.release)),
          isEmpty,
        );
      });

      test('reportEvents: repeat and release suffixes', () {
        kitty(
          KittyKeyboardFlags.disambiguate | KittyKeyboardFlags.reportEvents,
        );
        expect(
          showEscapes(
            encoder.encode(
              _char(
                VtKey.a,
                'a',
                modifiers: KeyModifiers.ctrl,
                action: KeyAction.repeat,
              ),
            ),
          ),
          'ESC[97;5:2u',
        );
        expect(
          showEscapes(
            encoder.encode(
              _char(
                VtKey.a,
                'a',
                modifiers: KeyModifiers.ctrl,
                action: KeyAction.release,
              ),
            ),
          ),
          'ESC[97;5:3u',
        );
      });

      test('reportAll turns every key into an escape code', () {
        kitty(KittyKeyboardFlags.disambiguate | KittyKeyboardFlags.reportAll);
        expect(showEscapes(encoder.encode(_char(VtKey.a, 'a'))), 'ESC[97u');
        expect(
          showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.enter))),
          'ESC[13u',
        );
        // Caps Lock is reported as modifier bit 64 (+1).
        expect(
          showEscapes(
            encoder.encode(
              const VtKeyEvent(
                key: VtKey.a,
                modifiers: KeyModifiers.capsLock,
                text: 'A',
                unshiftedCodepoint: 0x61,
              ),
            ),
          ),
          'ESC[97;65u',
        );
      });

      test('reportAlternates and reportAssociated', () {
        kitty(
          KittyKeyboardFlags.disambiguate |
              KittyKeyboardFlags.reportAll |
              KittyKeyboardFlags.reportAlternates |
              KittyKeyboardFlags.reportAssociated,
        );
        expect(
          showEscapes(
            encoder.encode(
              const VtKeyEvent(
                key: VtKey.a,
                modifiers: KeyModifiers.shift,
                consumedModifiers: KeyModifiers.shift,
                text: 'A',
                unshiftedCodepoint: 0x61,
              ),
            ),
          ),
          'ESC[97:65;2;65u',
        );
      });

      test('flags popped by the program are dropped on the next sync', () {
        withTerminal(80, 24, (terminal) {
          writeText(terminal, '\x1b[>1u');
          encoder.setFromTerminal(terminal);
          expect(
            showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.escape))),
            'ESC[27u',
          );
          writeText(terminal, '\x1b[<u');
          encoder.setFromTerminal(terminal);
          expect(
            showEscapes(encoder.encode(const VtKeyEvent(key: VtKey.escape))),
            'ESC',
          );
        });
      });
    });

    test('configure after encodes takes effect on the cached event', () {
      // The cache covers the native event only; option changes must not be
      // swallowed by an unchanged event.
      const up = VtKeyEvent(key: VtKey.arrowUp);
      expect(showEscapes(encoder.encode(up)), 'ESC[A');
      encoder.configure(cursorKeyApplication: true);
      expect(showEscapes(encoder.encode(up)), 'ESCOA');
      encoder.resetOptions();
      expect(showEscapes(encoder.encode(up)), 'ESC[A');
      withTerminal(80, 24, (terminal) {
        writeText(terminal, '\x1b[?1h');
        encoder.setFromTerminal(terminal);
      });
      expect(showEscapes(encoder.encode(up)), 'ESCOA');
    });

    test('a rejected event does not corrupt the cache', () {
      final a = _char(VtKey.a, 'a');
      expect(utf8.decode(encoder.encode(a)), 'a');
      expect(
        () => encoder.encode(
          const VtKeyEvent(key: VtKey.b, text: 'b', unshiftedCodepoint: -1),
        ),
        throwsRangeError,
      );
      expect(
        () => encoder.encode(const VtKeyEvent(key: VtKey.unknown, text: 'b')),
        throwsArgumentError,
      );
      expect(utf8.decode(encoder.encode(a)), 'a');
      expect(
        utf8.decode(
          encoder.encode(
            const VtKeyEvent(key: VtKey.b, text: 'b', unshiftedCodepoint: 0x62),
          ),
        ),
        'b',
      );
    });

    test('many encoders interleaved keep their own state', () {
      final others = List.generate(8, (_) => KeyEncoder());
      try {
        for (var i = 0; i < others.length; i++) {
          others[i].configure(cursorKeyApplication: i.isOdd);
        }
        for (var round = 0; round < 3; round++) {
          for (var i = 0; i < others.length; i++) {
            final text = String.fromCharCode(0x61 + i);
            expect(utf8.decode(others[i].encode(_char(VtKey.a, text))), text);
            expect(
              showEscapes(
                others[i].encode(const VtKeyEvent(key: VtKey.arrowUp)),
              ),
              i.isOdd ? 'ESCOA' : 'ESC[A',
            );
          }
        }
      } finally {
        for (final other in others) {
          other.dispose();
        }
      }
    });

    test('dispose then GC pressure does not crash', () {
      for (var i = 0; i < 2000; i++) {
        final e = KeyEncoder();
        e.encode(_char(VtKey.a, 'a' * (i % 50 + 1)));
        if (i.isEven) e.dispose();
      }
    });
  });

  group('MouseEncoder (review)', () {
    late MouseEncoder encoder;

    setUp(() => encoder = MouseEncoder());
    tearDown(() => encoder.dispose());

    void sync(String modes) => withTerminal(80, 24, (terminal) {
      writeText(terminal, '\x1b[?${modes}h');
      encoder.setFromTerminal(terminal);
    });

    VtMouseEvent motion(double x, double y, {MouseButton? button}) =>
        VtMouseEvent(action: MouseAction.motion, button: button, x: x, y: y);

    test('positions are surface pixels: padding is subtracted', () {
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 810,
          screenHeight: 490,
          cellWidth: 10,
          cellHeight: 20,
          paddingLeft: 5,
          paddingTop: 5,
          paddingRight: 5,
          paddingBottom: 5,
        ),
      );
      sync('1000;1006');
      VtMouseEvent press(double x, double y) => VtMouseEvent(
        action: MouseAction.press,
        button: MouseButton.left,
        x: x,
        y: y,
      );
      // x 14 - 5 = 9 -> column 0; x 15 - 5 = 10 -> column 1.
      expect(showEscapes(encoder.encode(press(14, 24))), 'ESC[<0;1;1M');
      expect(showEscapes(encoder.encode(press(15, 25))), 'ESC[<0;2;2M');
      // Inside the left padding clamps to the first column.
      expect(showEscapes(encoder.encode(press(1, 1))), 'ESC[<0;1;1M');
      sync('1000;1016');
      // SGR-Pixels reports terminal-space pixels (padding removed).
      expect(showEscapes(encoder.encode(press(15, 25))), 'ESC[<0;10;20M');
    });

    test('trackLastCell drops motion within the same cell only', () {
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 800,
          screenHeight: 480,
          cellWidth: 10,
          cellHeight: 20,
        ),
        trackLastCell: true,
      );
      sync('1003;1006');
      expect(showEscapes(encoder.encode(motion(15, 25))), 'ESC[<35;2;2M');
      expect(encoder.encode(motion(16, 26)), isEmpty);
      expect(encoder.encode(motion(19, 39)), isEmpty);
      expect(showEscapes(encoder.encode(motion(20, 25))), 'ESC[<35;3;2M');
      // Back to the previous cell is a change.
      expect(showEscapes(encoder.encode(motion(15, 25))), 'ESC[<35;2;2M');
      // reset, setFromTerminal and a size change all clear the state.
      encoder.reset();
      expect(showEscapes(encoder.encode(motion(15, 25))), 'ESC[<35;2;2M');
      sync('1003;1006');
      expect(showEscapes(encoder.encode(motion(15, 25))), 'ESC[<35;2;2M');
      // A press in the same cell is never deduplicated.
      expect(
        showEscapes(
          encoder.encode(
            const VtMouseEvent(
              action: MouseAction.press,
              button: MouseButton.left,
              x: 15,
              y: 25,
            ),
          ),
        ),
        'ESC[<0;2;2M',
      );
      // Turning tracking off and on clears it too.
      encoder.configure(trackLastCell: false);
      encoder.configure(trackLastCell: true);
      expect(showEscapes(encoder.encode(motion(15, 25))), 'ESC[<35;2;2M');
    });

    test('without trackLastCell every motion is reported', () {
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 800,
          screenHeight: 480,
          cellWidth: 10,
          cellHeight: 20,
        ),
      );
      sync('1003;1006');
      expect(showEscapes(encoder.encode(motion(15, 25))), 'ESC[<35;2;2M');
      expect(showEscapes(encoder.encode(motion(16, 26))), 'ESC[<35;2;2M');
    });

    test('SGR-Pixels motion is never deduplicated', () {
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 800,
          screenHeight: 480,
          cellWidth: 10,
          cellHeight: 20,
        ),
        trackLastCell: true,
      );
      sync('1003;1016');
      expect(showEscapes(encoder.encode(motion(15, 25))), 'ESC[<35;15;25M');
      expect(showEscapes(encoder.encode(motion(16, 25))), 'ESC[<35;16;25M');
    });

    test('button tracking: motion only with a button; legacy release', () {
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 800,
          screenHeight: 480,
          cellWidth: 10,
          cellHeight: 20,
        ),
      );
      sync('1002');
      expect(encoder.encode(motion(15, 25)), isEmpty);
      // X10-style bytes: ESC [ M (32+b) (32+x+1) (32+y+1).
      expect(encoder.encode(motion(15, 25, button: MouseButton.left)), [
        0x1b,
        0x5b,
        0x4d,
        32 + 32,
        32 + 2,
        32 + 2,
      ]);
      // Legacy releases are button 3.
      expect(
        encoder.encode(
          const VtMouseEvent(
            action: MouseAction.release,
            button: MouseButton.left,
            x: 15,
            y: 25,
          ),
        ),
        [0x1b, 0x5b, 0x4d, 32 + 3, 32 + 2, 32 + 2],
      );
    });

    test('out-of-viewport: releases always, drags only with a button', () {
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 800,
          screenHeight: 480,
          cellWidth: 10,
          cellHeight: 20,
        ),
      );
      sync('1003;1006');
      final outside = motion(-5, 100, button: MouseButton.left);
      expect(encoder.encode(outside), isEmpty);
      encoder.configure(anyButtonPressed: true);
      expect(showEscapes(encoder.encode(outside)), 'ESC[<32;1;6M');
      encoder.configure(anyButtonPressed: false);
      expect(
        showEscapes(
          encoder.encode(
            const VtMouseEvent(
              action: MouseAction.release,
              button: MouseButton.left,
              x: 5000,
              y: 5000,
            ),
          ),
        ),
        'ESC[<0;80;24m',
      );
    });

    test('alternating button and no-button events', () {
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 800,
          screenHeight: 480,
          cellWidth: 10,
          cellHeight: 20,
        ),
      );
      sync('1003;1006');
      for (var i = 0; i < 3; i++) {
        expect(showEscapes(encoder.encode(motion(15, 25))), 'ESC[<35;2;2M');
        expect(
          showEscapes(
            encoder.encode(motion(15, 25, button: MouseButton.right)),
          ),
          'ESC[<34;2;2M',
        );
      }
    });

    test('non-finite positions are rejected before any native call', () {
      sync('1003;1016');
      for (final bad in [double.nan, double.infinity, -double.infinity]) {
        expect(
          () => encoder.encode(motion(bad, 0)),
          throwsArgumentError,
          reason: 'x = $bad',
        );
        expect(
          () => encoder.encode(
            VtMouseEvent(
              action: MouseAction.release,
              button: MouseButton.left,
              x: 0,
              y: bad,
            ),
          ),
          throwsArgumentError,
          reason: 'y = $bad',
        );
      }
      // The encoder still works afterwards.
      expect(
        showEscapes(
          encoder.encode(
            const VtMouseEvent(
              action: MouseAction.press,
              button: MouseButton.left,
              x: 0,
              y: 0,
            ),
          ),
        ),
        'ESC[<0;0;0M',
      );
    });

    test('huge finite positions produce sane, clamped reports', () {
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 800,
          screenHeight: 480,
          cellWidth: 10,
          cellHeight: 20,
        ),
        anyButtonPressed: true,
      );
      sync('1003;1006');
      expect(
        showEscapes(
          encoder.encode(motion(1e30, 1e30, button: MouseButton.left)),
        ),
        'ESC[<32;80;24M',
      );
      expect(
        showEscapes(
          encoder.encode(motion(-1e30, -1e30, button: MouseButton.left)),
        ),
        'ESC[<32;1;1M',
      );
    });

    test('clamped positions in SGR-Pixels stay within i32 and the grid', () {
      sync('1003;1016');
      // Default size: 1x1 screen of 1x1 cells, so the bound is 65535 px.
      expect(
        showEscapes(
          encoder.encode(
            const VtMouseEvent(
              action: MouseAction.release,
              button: MouseButton.left,
              x: 3e9,
              y: -3e9,
            ),
          ),
        ),
        'ESC[<0;65535;-16777216m',
      );
    });

    test('a size change re-clamps the cached event', () {
      encoder.configure(anyButtonPressed: true);
      sync('1003;1006');
      final far = motion(1e9, 0, button: MouseButton.left);
      // Default 1x1 grid.
      expect(showEscapes(encoder.encode(far)), 'ESC[<32;1;1M');
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 800,
          screenHeight: 480,
          cellWidth: 10,
          cellHeight: 20,
        ),
      );
      expect(showEscapes(encoder.encode(far)), 'ESC[<32;80;1M');
      encoder.resetOptions();
      sync('1003;1006');
      encoder.configure(anyButtonPressed: true);
      expect(showEscapes(encoder.encode(far)), 'ESC[<32;1;1M');
    });

    test('sizes the library cannot convert are rejected', () {
      for (final size in const [
        // More than 65535 columns: the library's u16 grid overflows.
        MouseEncoderSize(
          screenWidth: 70000,
          screenHeight: 10,
          cellWidth: 1,
          cellHeight: 1,
        ),
        MouseEncoderSize(
          screenWidth: 10,
          screenHeight: 70000,
          cellWidth: 1,
          cellHeight: 1,
        ),
        // Paddings whose sum overflows u32.
        MouseEncoderSize(
          screenWidth: 100,
          screenHeight: 10,
          cellWidth: 1,
          cellHeight: 1,
          paddingLeft: 0xFFFFFFFF,
          paddingRight: 2,
        ),
        MouseEncoderSize(
          screenWidth: 0xFFFFFFFF,
          screenHeight: 10,
          cellWidth: 0xFFFF,
          cellHeight: 1,
        ),
      ]) {
        expect(
          () => encoder.configure(size: size),
          throwsRangeError,
          reason: '$size',
        );
      }
      // The largest accepted geometry still encodes correctly.
      encoder.configure(
        size: const MouseEncoderSize(
          screenWidth: 65535,
          screenHeight: 65535,
          cellWidth: 1,
          cellHeight: 1,
        ),
      );
      sync('1000;1006');
      expect(
        showEscapes(
          encoder.encode(
            const VtMouseEvent(
              action: MouseAction.press,
              button: MouseButton.left,
              x: 65534.5,
              y: 65534.5,
            ),
          ),
        ),
        'ESC[<0;65535;65535M',
      );
    });

    test('encoders keep working after the source terminal is disposed', () {
      final terminal = VtTerminal(cols: 80, rows: 24);
      writeText(terminal, '\x1b[?1000;1006h');
      encoder.setFromTerminal(terminal);
      terminal.dispose();
      expect(() => encoder.setFromTerminal(terminal), throwsStateError);
      expect(
        showEscapes(
          encoder.encode(
            const VtMouseEvent(
              action: MouseAction.press,
              button: MouseButton.left,
              x: 0,
              y: 0,
            ),
          ),
        ),
        'ESC[<0;1;1M',
      );
    });
  });

  group('stateless encoders (review)', () {
    test('huge bracketed paste is complete and sanitised', () {
      final text = '${'line\n' * 50000}\x1b[201~tail\x00';
      final bytes = encodePaste(text, bracketed: true);
      final s = latin1.decode(bytes);
      expect(s.startsWith('\x1b[200~'), isTrue);
      expect(s.endsWith('\x1b[201~'), isTrue);
      final body = s.substring(6, s.length - 6);
      expect(body.contains('\x1b'), isFalse);
      expect(body.contains('\x00'), isFalse);
      expect(body.length, utf8.encode(text).length);
      expect(body.startsWith('line\nline\n'), isTrue);
    });

    test('unbracketed paste: CRLF and LF become CR, controls spaces', () {
      expect(
        latin1.decode(encodePaste('a\r\nb\nc\x7fd\te', bracketed: false)),
        // Tab survives; DEL becomes a space.
        'a\r\rb\rc d\te',
      );
    });

    test('paste of the same string twice gives the same bytes', () {
      // The library rewrites its input in place; the wrapper must not let
      // that leak into later calls.
      const text = 'a\x1bb\nc';
      final first = encodePaste(text, bracketed: false);
      final second = encodePaste(text, bracketed: false);
      expect(second, first);
      expect(latin1.decode(first), 'a b\rc');
    });

    test(
      'isPasteSafe: start marker, tab and CJK are safe; size is no limit',
      () {
        expect(isPasteSafe('x\x1b[200~y'), isTrue);
        expect(isPasteSafe('tab\tok'), isTrue);
        expect(isPasteSafe('日本語🙂'), isTrue);
        expect(isPasteSafe('${'a' * 100000}\n'), isFalse);
      },
    );

    test('mode reports for modes with large numbers', () {
      expect(
        showEscapes(
          encodeModeReport(
            TerminalMode.bracketedPaste,
            ModeReportState.permanentlyReset,
          ),
        ),
        r'ESC[?2004;4$y',
      );
      expect(
        showEscapes(
          encodeModeReport(
            const TerminalMode.dec(32767),
            ModeReportState.notRecognized,
          ),
        ),
        r'ESC[?32767;0$y',
      );
      expect(
        showEscapes(encodeModeReport(TerminalMode.insert, ModeReportState.set)),
        r'ESC[4;1$y',
      );
    });
  });
}
