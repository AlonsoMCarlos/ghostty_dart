import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

void main() {
  group('colours', () {
    test('RgbColor value semantics', () {
      const a = RgbColor(0x12, 0xab, 0xff);
      expect(a, const RgbColor.fromValue(0x12abff));
      expect(a.hashCode, const RgbColor.fromValue(0x12abff).hashCode);
      expect(a.value, 0x12abff);
      expect(a.toHex(), '#12abff');
      expect(const RgbColor(0, 0, 1).toHex(), '#000001');
      expect(const RgbColor.fromValue(0xff000000), const RgbColor(0, 0, 0));
      expect(a, isNot(const RgbColor(0x12, 0xab, 0xfe)));
      expect('$a', 'RgbColor(18, 171, 255)');
    });

    test('PaletteColor and DefaultColor value semantics', () {
      expect(PaletteColor.brightWhite, const PaletteColor(15));
      expect(PaletteColor.red.index, 1);
      expect(const PaletteColor(3).hashCode, PaletteColor.yellow.hashCode);
      expect(const PaletteColor(1), isNot(const RgbColor(1, 0, 0)));
      // ignore: prefer_const_constructors
      expect(DefaultColor(), const DefaultColor());
      expect(const DefaultColor(), isNot(const PaletteColor(0)));
    });

    test('round-trip through GhosttyStyleColor', () {
      using((arena) {
        final raw = arena<GhosttyStyleColor>();
        for (final color in const <ColorRef>[
          DefaultColor(),
          PaletteColor(0),
          PaletteColor(255),
          RgbColor(1, 2, 3),
        ]) {
          styleColorToNative(color, raw.ref);
          expect(styleColorFromNative(raw.ref), color);
        }
      });
    });

    test('palette colours zero the unused value bytes', () {
      using((arena) {
        final raw = arena<GhosttyStyleColor>();
        styleColorToNative(const RgbColor(9, 9, 9), raw.ref);
        styleColorToNative(const PaletteColor(7), raw.ref);
        expect(raw.cast<Uint8>().asTypedList(4), [
          GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE,
          7,
          0,
          0,
        ]);
      });
    });

    test('unknown colour tags decode to DefaultColor', () {
      using((arena) {
        final raw = arena<GhosttyStyleColor>()..ref.tag = 99;
        expect(styleColorFromNative(raw.ref), const DefaultColor());
      });
    });

    test('rgb round-trips through GhosttyColorRgb', () {
      using((arena) {
        final raw = arena<GhosttyColorRgb>();
        rgbToNative(const RgbColor(255, 0, 128), raw.ref);
        expect(rgbFromNative(raw.ref), const RgbColor(255, 0, 128));
      });
    });
  });

  group('CellStyle', () {
    const fancy = CellStyle(
      foreground: PaletteColor.red,
      background: RgbColor(10, 20, 30),
      underlineColor: PaletteColor(200),
      bold: true,
      italic: true,
      faint: true,
      blink: true,
      inverse: true,
      invisible: true,
      strikethrough: true,
      overline: true,
      underline: UnderlineStyle.curly,
    );

    test('default style', () {
      expect(const CellStyle().isDefault, isTrue);
      expect(const CellStyle(bold: true).isDefault, isFalse);
      expect('${const CellStyle()}', 'CellStyle()');
    });

    test('value semantics and copyWith', () {
      expect(fancy, fancy.copyWith());
      expect(fancy.hashCode, fancy.copyWith().hashCode);
      expect(fancy.copyWith(bold: false), isNot(fancy));
      expect(fancy.copyWith(bold: false).bold, isFalse);
      expect('$fancy', allOf(contains('bold'), contains('curly')));
    });

    test('round-trips through GhosttyStyle and agrees with the library', () {
      using((arena) {
        final raw = arena<GhosttyStyle>();
        cellStyleToNative(fancy, raw.ref);
        expect(cellStyleFromNative(raw.ref), fancy);
        expect(ghostty_style_is_default(raw), isFalse);
        expect(raw.ref.reserved, 0);

        ghostty_style_default(raw);
        expect(cellStyleFromNative(raw.ref), const CellStyle());
        cellStyleToNative(const CellStyle(), raw.ref);
        expect(ghostty_style_is_default(raw), isTrue);
      });
    });

    test('flags use the header bit layout', () {
      expect(
        cellStyleFlags(const CellStyle(bold: true, overline: true)),
        GHOSTTY_STYLE_FLAG_BOLD | GHOSTTY_STYLE_FLAG_OVERLINE,
      );
      expect(
        cellStyleFlags(const CellStyle(underline: UnderlineStyle.dashed)),
        GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DASHED <<
            GHOSTTY_STYLE_UNDERLINE_SHIFT,
      );
      expect(
        () =>
            cellStyleFlags(const CellStyle(underline: UnderlineStyle.unknown)),
        throwsArgumentError,
      );
    });

    test('unknown underline values decode to unknown', () {
      final style = cellStyleFromParts(
        flags: 7 << GHOSTTY_STYLE_UNDERLINE_SHIFT,
        foreground: const DefaultColor(),
        background: const DefaultColor(),
        underlineColor: const DefaultColor(),
      );
      expect(style.underline, UnderlineStyle.unknown);
    });
  });

  group('GridPoint', () {
    test('value semantics', () {
      expect(
        const GridPoint.viewport(4, 0),
        const GridPoint(PointSpace.viewport, 4, 0),
      );
      expect(const GridPoint.active(1, 2), isNot(const GridPoint.screen(1, 2)));
      expect('${const GridPoint.history(3, 9)}', 'GridPoint.history(3, 9)');
    });

    test('round-trips through GhosttyPoint', () {
      using((arena) {
        final raw = arena<GhosttyPoint>();
        for (final point in const [
          GridPoint.active(0, 0),
          GridPoint.viewport(65535, 1),
          GridPoint.screen(3, 0xFFFFFFFF),
          GridPoint.history(7, 100000),
        ]) {
          gridPointToNative(point, raw.ref);
          expect(gridPointFromNative(raw.ref), point);
        }
        expect(
          () => gridPointToNative(
            const GridPoint(PointSpace.unknown, 0, 0),
            raw.ref,
          ),
          throwsArgumentError,
        );
        raw.ref.tag = 42;
        expect(gridPointFromNative(raw.ref).space, PointSpace.unknown);
      });
    });
  });

  group('KeyModifiers', () {
    test('bits match GHOSTTY_MODS_*', () {
      final expected = {
        const KeyModifiers(shift: true): GHOSTTY_MODS_SHIFT,
        const KeyModifiers(ctrl: true): GHOSTTY_MODS_CTRL,
        const KeyModifiers(alt: true): GHOSTTY_MODS_ALT,
        const KeyModifiers(superKey: true): GHOSTTY_MODS_SUPER,
        const KeyModifiers(capsLock: true): GHOSTTY_MODS_CAPS_LOCK,
        const KeyModifiers(numLock: true): GHOSTTY_MODS_NUM_LOCK,
        const KeyModifiers(rightShift: true): GHOSTTY_MODS_SHIFT_SIDE,
        const KeyModifiers(rightCtrl: true): GHOSTTY_MODS_CTRL_SIDE,
        const KeyModifiers(rightAlt: true): GHOSTTY_MODS_ALT_SIDE,
        const KeyModifiers(rightSuper: true): GHOSTTY_MODS_SUPER_SIDE,
      };
      expected.forEach((mods, raw) {
        expect(keyModifiersToRaw(mods), raw, reason: '$mods');
        expect(keyModifiersFromRaw(raw), mods);
      });
    });

    test('set operations and getters', () {
      final mods = KeyModifiers.ctrl | KeyModifiers.shift;
      expect(mods, const KeyModifiers(ctrl: true, shift: true));
      expect(mods.hasCtrl && mods.hasShift, isTrue);
      expect(mods.hasAlt || mods.hasSuper || mods.isRightCtrl, isFalse);
      expect(mods.containsAll(KeyModifiers.ctrl), isTrue);
      expect(mods.containsAll(KeyModifiers.alt), isFalse);
      expect(mods & KeyModifiers.ctrl, KeyModifiers.ctrl);
      expect(KeyModifiers.none.isEmpty, isTrue);
      expect('$mods', 'KeyModifiers(shift | ctrl)');
      expect(
        '${const KeyModifiers(alt: true, rightAlt: true)}',
        'KeyModifiers(rightAlt)',
      );
    });

    test('unknown bits round-trip', () {
      expect(keyModifiersToRaw(keyModifiersFromRaw(0x8001)), 0x8001);
    });
  });

  group('TerminalMode', () {
    test('packs like ghostty_mode_new', () {
      expect(terminalModeToRaw(TerminalMode.cursorKeys), 1);
      expect(terminalModeToRaw(TerminalMode.insert), 4 | 0x8000);
      expect(terminalModeToRaw(const TerminalMode.dec(0x7FFF)), 0x7FFF);
      for (final mode in TerminalMode.named) {
        expect(terminalModeFromRaw(terminalModeToRaw(mode)), mode);
      }
      expect(terminalModeFromRaw(0xFFFF), const TerminalMode.ansi(0x7FFF));
      expect(terminalModeFromRaw(0x7FFF), const TerminalMode.dec(0x7FFF));
    });

    test('ANSI and DEC modes with the same number differ', () {
      expect(TerminalMode.insert.value, TerminalMode.slowScroll.value);
      expect(TerminalMode.insert, isNot(TerminalMode.slowScroll));
      expect('${TerminalMode.insert}', 'TerminalMode.ansi(4)');
      expect('${TerminalMode.bracketedPaste}', 'TerminalMode.dec(2004)');
    });

    test('named modes are unique and encode DECRPM as the library expects', () {
      expect(TerminalMode.named.toSet(), hasLength(TerminalMode.named.length));
      final bytes = callWithSizeQuery(
        'ghostty_mode_report_encode',
        (buffer, capacity, outLength) => ghostty_mode_report_encode(
          terminalModeToRaw(TerminalMode.insert),
          GhosttyModeReportState.GHOSTTY_MODE_REPORT_RESET,
          buffer,
          capacity,
          outLength,
        ),
      );
      expect(String.fromCharCodes(bytes), '\x1b[4;2\$y');
    });
  });
}
