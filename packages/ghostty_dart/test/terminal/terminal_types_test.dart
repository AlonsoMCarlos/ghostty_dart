// Enum codecs against the bindings constants, and pure value types.

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/terminal/memory.dart';
import 'package:ghostty_dart/src/terminal/mouse_shape.dart';
import 'package:ghostty_dart/src/terminal/paste.dart';
import 'package:ghostty_dart/src/terminal/write_stop.dart';
import 'package:test/test.dart';

import '../support/expect_support.dart';

typedef _Shape = GhosttyMouseShape;
typedef _Result = GhosttyTerminalCompressionResult;
typedef _Mode = GhosttyTerminalCompressionMode;
typedef _Location = GhosttyClipboardLocation;
typedef _Kind = GhosttyTerminalStringKind;
typedef _Introducer = GhosttyTerminalStringIntroducer;
typedef _End = GhosttyTerminalStringEnd;
typedef _Boundary = GhosttyTerminalBoundary;

/// Checks that [codec] maps exactly [expected] (member -> raw constant) and
/// sends every other value to [unknown]. Copied from
/// test/core/enum_codec_test.dart, as contratos.md §3 asks.

void main() {
  group('codecs match the bindings', () {
    test('MouseShape', () {
      expectCodec(mouseShapeCodec, MouseShape.values, MouseShape.unknown, {
        MouseShape.defaultShape: _Shape.GHOSTTY_MOUSE_SHAPE_DEFAULT,
        MouseShape.contextMenu: _Shape.GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU,
        MouseShape.help: _Shape.GHOSTTY_MOUSE_SHAPE_HELP,
        MouseShape.pointer: _Shape.GHOSTTY_MOUSE_SHAPE_POINTER,
        MouseShape.progress: _Shape.GHOSTTY_MOUSE_SHAPE_PROGRESS,
        MouseShape.wait: _Shape.GHOSTTY_MOUSE_SHAPE_WAIT,
        MouseShape.cell: _Shape.GHOSTTY_MOUSE_SHAPE_CELL,
        MouseShape.crosshair: _Shape.GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
        MouseShape.text: _Shape.GHOSTTY_MOUSE_SHAPE_TEXT,
        MouseShape.verticalText: _Shape.GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT,
        MouseShape.alias: _Shape.GHOSTTY_MOUSE_SHAPE_ALIAS,
        MouseShape.copy: _Shape.GHOSTTY_MOUSE_SHAPE_COPY,
        MouseShape.move: _Shape.GHOSTTY_MOUSE_SHAPE_MOVE,
        MouseShape.noDrop: _Shape.GHOSTTY_MOUSE_SHAPE_NO_DROP,
        MouseShape.notAllowed: _Shape.GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
        MouseShape.grab: _Shape.GHOSTTY_MOUSE_SHAPE_GRAB,
        MouseShape.grabbing: _Shape.GHOSTTY_MOUSE_SHAPE_GRABBING,
        MouseShape.allScroll: _Shape.GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
        MouseShape.colResize: _Shape.GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
        MouseShape.rowResize: _Shape.GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
        MouseShape.nResize: _Shape.GHOSTTY_MOUSE_SHAPE_N_RESIZE,
        MouseShape.eResize: _Shape.GHOSTTY_MOUSE_SHAPE_E_RESIZE,
        MouseShape.sResize: _Shape.GHOSTTY_MOUSE_SHAPE_S_RESIZE,
        MouseShape.wResize: _Shape.GHOSTTY_MOUSE_SHAPE_W_RESIZE,
        MouseShape.neResize: _Shape.GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
        MouseShape.nwResize: _Shape.GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
        MouseShape.seResize: _Shape.GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
        MouseShape.swResize: _Shape.GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
        MouseShape.ewResize: _Shape.GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
        MouseShape.nsResize: _Shape.GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
        MouseShape.neswResize: _Shape.GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
        MouseShape.nwseResize: _Shape.GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
        MouseShape.zoomIn: _Shape.GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
        MouseShape.zoomOut: _Shape.GHOSTTY_MOUSE_SHAPE_ZOOM_OUT,
      });
    });

    test('CompressionResult and CompressionMode', () {
      expectCodec(
        compressionResultCodec,
        CompressionResult.values,
        CompressionResult.unknown,
        {
          CompressionResult.unsupported:
              _Result.GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED,
          CompressionResult.pending:
              _Result.GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING,
          CompressionResult.complete:
              _Result.GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE,
        },
      );
      expect(
        compressionModeToRaw(CompressionMode.incremental),
        _Mode.GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL,
      );
      expect(
        compressionModeToRaw(CompressionMode.full),
        _Mode.GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL,
      );
    });

    test('ClipboardLocation and PasteSource', () {
      expectCodec(
        clipboardLocationCodec,
        ClipboardLocation.values,
        ClipboardLocation.unknown,
        {
          ClipboardLocation.standard:
              _Location.GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
          ClipboardLocation.selection:
              _Location.GHOSTTY_CLIPBOARD_LOCATION_SELECTION,
          ClipboardLocation.primary:
              _Location.GHOSTTY_CLIPBOARD_LOCATION_PRIMARY,
        },
      );
      expect(
        pasteSourceToRaw(PasteSource.clipboard),
        GhosttyPasteSource.GHOSTTY_PASTE_SOURCE_CLIPBOARD,
      );
      expect(
        pasteSourceToRaw(PasteSource.text),
        GhosttyPasteSource.GHOSTTY_PASTE_SOURCE_TEXT,
      );
    });

    test('control string enums', () {
      expectCodec(
        controlStringKindCodec,
        ControlStringKind.values,
        ControlStringKind.unknown,
        {
          ControlStringKind.apc: _Kind.GHOSTTY_TERMINAL_STRING_KIND_APC,
          ControlStringKind.dcs: _Kind.GHOSTTY_TERMINAL_STRING_KIND_DCS,
          ControlStringKind.osc: _Kind.GHOSTTY_TERMINAL_STRING_KIND_OSC,
        },
      );
      expectCodec(
        controlStringIntroducerCodec,
        ControlStringIntroducer.values,
        ControlStringIntroducer.unknown,
        {
          ControlStringIntroducer.esc:
              _Introducer.GHOSTTY_TERMINAL_STRING_INTRODUCER_ESC,
          ControlStringIntroducer.c1:
              _Introducer.GHOSTTY_TERMINAL_STRING_INTRODUCER_C1,
        },
      );
      expectCodec(
        controlStringEndCodec,
        ControlStringEnd.values,
        ControlStringEnd.unknown,
        {
          ControlStringEnd.stEsc: _End.GHOSTTY_TERMINAL_STRING_END_ST_ESC,
          ControlStringEnd.stC1: _End.GHOSTTY_TERMINAL_STRING_END_ST_C1,
          ControlStringEnd.cancelled:
              _End.GHOSTTY_TERMINAL_STRING_END_CANCELLED,
          ControlStringEnd.aborted: _End.GHOSTTY_TERMINAL_STRING_END_ABORTED,
          ControlStringEnd.bel: _End.GHOSTTY_TERMINAL_STRING_END_BEL,
        },
      );
    });

    test('WriteBoundaries flags', () {
      final expected = {
        WriteBoundaries.ground: _Boundary.GHOSTTY_TERMINAL_BOUNDARY_GROUND,
        WriteBoundaries.apcStart: _Boundary.GHOSTTY_TERMINAL_BOUNDARY_APC_START,
        WriteBoundaries.apcEnd: _Boundary.GHOSTTY_TERMINAL_BOUNDARY_APC_END,
        WriteBoundaries.dcsStart: _Boundary.GHOSTTY_TERMINAL_BOUNDARY_DCS_START,
        WriteBoundaries.dcsEnd: _Boundary.GHOSTTY_TERMINAL_BOUNDARY_DCS_END,
        WriteBoundaries.oscStart: _Boundary.GHOSTTY_TERMINAL_BOUNDARY_OSC_START,
        WriteBoundaries.oscEnd: _Boundary.GHOSTTY_TERMINAL_BOUNDARY_OSC_END,
      };
      expected.forEach((flag, raw) {
        expect(writeBoundariesToRaw(flag), raw, reason: '$flag');
        expect(writeBoundariesFromRaw(raw), flag);
      });
      expect(
        writeBoundariesToRaw(WriteBoundaries.all),
        expected.values.reduce((a, b) => a | b),
      );
    });

    test('KittyKeyboardFlags values', () {
      expect(KittyKeyboardFlags.disabled.value, GHOSTTY_KITTY_KEY_DISABLED);
      expect(
        KittyKeyboardFlags.disambiguate.value,
        GHOSTTY_KITTY_KEY_DISAMBIGUATE,
      );
      expect(
        KittyKeyboardFlags.reportEvents.value,
        GHOSTTY_KITTY_KEY_REPORT_EVENTS,
      );
      expect(
        KittyKeyboardFlags.reportAlternates.value,
        GHOSTTY_KITTY_KEY_REPORT_ALTERNATES,
      );
      expect(KittyKeyboardFlags.reportAll.value, GHOSTTY_KITTY_KEY_REPORT_ALL);
      expect(
        KittyKeyboardFlags.reportAssociated.value,
        GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED,
      );
      expect(KittyKeyboardFlags.all.value, GHOSTTY_KITTY_KEY_ALL);
    });
  });

  group('value types', () {
    test('KittyKeyboardFlags set algebra keeps unknown bits', () {
      final flags =
          KittyKeyboardFlags.disambiguate | KittyKeyboardFlags.reportAll;
      expect(flags.value, 9);
      expect(flags.containsAll(KittyKeyboardFlags.reportAll), isTrue);
      expect(flags.containsAll(KittyKeyboardFlags.all), isFalse);
      expect(
        flags & KittyKeyboardFlags.reportAll,
        KittyKeyboardFlags.reportAll,
      );
      expect(const KittyKeyboardFlags.fromValue(0x1FF).value, 0xFF);
      expect(
        '${const KittyKeyboardFlags.fromValue(0x41)}',
        'KittyKeyboardFlags(disambiguate | 0x40)',
      );
    });

    test('WriteBoundaries set algebra', () {
      final both = WriteBoundaries.oscStart | WriteBoundaries.oscEnd;
      expect(both.containsAll(WriteBoundaries.oscEnd), isTrue);
      expect(both.containsAny(WriteBoundaries.anyStart), isTrue);
      expect(both - WriteBoundaries.oscStart, WriteBoundaries.oscEnd);
      expect(both & WriteBoundaries.anyEnd, WriteBoundaries.oscEnd);
      expect(WriteBoundaries.none.isEmpty, isTrue);
      expect('$both', 'WriteBoundaries(oscStart | oscEnd)');
    });

    test('writeStopFromRaw nulls the fields that do not apply', () {
      final none = writeStopFromRaw(
        consumed: 7,
        reached: 0,
        kind: 2,
        introducer: 1,
        end: 4,
        byte: 9,
      );
      expect(none, const WriteStop(consumed: 7, reached: WriteBoundaries.none));
      final ground = writeStopFromRaw(
        consumed: 0,
        reached: 1,
        kind: 0,
        introducer: 0,
        end: 0,
        byte: 0,
      );
      expect(ground.kind, isNull);
      expect(ground.byte, isNull);
      // An APC aborted by a C1 OSC introducer: end and start in one byte.
      final both = writeStopFromRaw(
        consumed: 3,
        reached: (1 << 2) | (1 << 5),
        kind: 0,
        introducer: 1,
        end: 3,
        byte: 0x9D,
      );
      expect(both.kind, ControlStringKind.apc);
      expect(both.introducer, ControlStringIntroducer.c1);
      expect(both.end, ControlStringEnd.aborted);
      expect(both.byte, 0x9D);
      final future = writeStopFromRaw(
        consumed: 1,
        reached: 1 << 2,
        kind: 77,
        introducer: 0,
        end: 77,
        byte: 0,
      );
      expect(future.kind, ControlStringKind.unknown);
      expect(future.end, ControlStringEnd.unknown);
    });

    test('memory usage adds per screen', () {
      const one = ScreenMemoryUsage(
        pages: 1,
        virtualBytes: 2,
        residentBytes: 3,
        compressedPages: 4,
        compressedBytes: 5,
        imageBytes: 6,
      );
      expect(one + ScreenMemoryUsage.empty, one);
      expect((one + one).residentBytes, 6);
      const usage = TerminalMemoryUsage(
        compressionSupported: true,
        primary: one,
        alternate: one,
      );
      expect(usage.total, one + one);
      expect(
        usage,
        const TerminalMemoryUsage(
          compressionSupported: true,
          primary: one,
          alternate: one,
        ),
      );
    });

    test('TerminalCursor and ViewportScrollbar equality', () {
      const a = TerminalCursor(
        x: 1,
        y: 2,
        isVisible: true,
        hasPendingWrap: false,
        style: CellStyle(bold: true),
      );
      expect(
        a,
        const TerminalCursor(
          x: 1,
          y: 2,
          isVisible: true,
          hasPendingWrap: false,
          style: CellStyle(bold: true),
        ),
      );
      expect(
        a.hashCode,
        isNot(
          const TerminalCursor(
            x: 1,
            y: 3,
            isVisible: true,
            hasPendingWrap: false,
            style: CellStyle(bold: true),
          ).hashCode,
        ),
      );
      expect(
        const ViewportScrollbar(total: 10, offset: 2, length: 3).isAtBottom,
        isFalse,
      );
    });
  });
}
