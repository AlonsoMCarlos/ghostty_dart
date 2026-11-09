import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/input/key.dart';
import 'package:ghostty_dart/src/input/mouse.dart';
import 'package:ghostty_dart/src/input/reports.dart';
import 'package:test/test.dart';

import '../support/expect_support.dart';

/// Checks that [codec] maps exactly [expected] (member -> raw constant) and
/// sends every other value to [unknown]. Copied from
/// `test/core/enum_codec_test.dart`.

void main() {
  test('VtKey matches GhosttyKey', () {
    expectCodec(vtKeyCodec, VtKey.values, VtKey.unknown, {
      VtKey.unidentified: GhosttyKey.GHOSTTY_KEY_UNIDENTIFIED,
      VtKey.backquote: GhosttyKey.GHOSTTY_KEY_BACKQUOTE,
      VtKey.backslash: GhosttyKey.GHOSTTY_KEY_BACKSLASH,
      VtKey.bracketLeft: GhosttyKey.GHOSTTY_KEY_BRACKET_LEFT,
      VtKey.bracketRight: GhosttyKey.GHOSTTY_KEY_BRACKET_RIGHT,
      VtKey.comma: GhosttyKey.GHOSTTY_KEY_COMMA,
      VtKey.digit0: GhosttyKey.GHOSTTY_KEY_DIGIT_0,
      VtKey.digit1: GhosttyKey.GHOSTTY_KEY_DIGIT_1,
      VtKey.digit2: GhosttyKey.GHOSTTY_KEY_DIGIT_2,
      VtKey.digit3: GhosttyKey.GHOSTTY_KEY_DIGIT_3,
      VtKey.digit4: GhosttyKey.GHOSTTY_KEY_DIGIT_4,
      VtKey.digit5: GhosttyKey.GHOSTTY_KEY_DIGIT_5,
      VtKey.digit6: GhosttyKey.GHOSTTY_KEY_DIGIT_6,
      VtKey.digit7: GhosttyKey.GHOSTTY_KEY_DIGIT_7,
      VtKey.digit8: GhosttyKey.GHOSTTY_KEY_DIGIT_8,
      VtKey.digit9: GhosttyKey.GHOSTTY_KEY_DIGIT_9,
      VtKey.equal: GhosttyKey.GHOSTTY_KEY_EQUAL,
      VtKey.intlBackslash: GhosttyKey.GHOSTTY_KEY_INTL_BACKSLASH,
      VtKey.intlRo: GhosttyKey.GHOSTTY_KEY_INTL_RO,
      VtKey.intlYen: GhosttyKey.GHOSTTY_KEY_INTL_YEN,
      VtKey.a: GhosttyKey.GHOSTTY_KEY_A,
      VtKey.b: GhosttyKey.GHOSTTY_KEY_B,
      VtKey.c: GhosttyKey.GHOSTTY_KEY_C,
      VtKey.d: GhosttyKey.GHOSTTY_KEY_D,
      VtKey.e: GhosttyKey.GHOSTTY_KEY_E,
      VtKey.f: GhosttyKey.GHOSTTY_KEY_F,
      VtKey.g: GhosttyKey.GHOSTTY_KEY_G,
      VtKey.h: GhosttyKey.GHOSTTY_KEY_H,
      VtKey.i: GhosttyKey.GHOSTTY_KEY_I,
      VtKey.j: GhosttyKey.GHOSTTY_KEY_J,
      VtKey.k: GhosttyKey.GHOSTTY_KEY_K,
      VtKey.l: GhosttyKey.GHOSTTY_KEY_L,
      VtKey.m: GhosttyKey.GHOSTTY_KEY_M,
      VtKey.n: GhosttyKey.GHOSTTY_KEY_N,
      VtKey.o: GhosttyKey.GHOSTTY_KEY_O,
      VtKey.p: GhosttyKey.GHOSTTY_KEY_P,
      VtKey.q: GhosttyKey.GHOSTTY_KEY_Q,
      VtKey.r: GhosttyKey.GHOSTTY_KEY_R,
      VtKey.s: GhosttyKey.GHOSTTY_KEY_S,
      VtKey.t: GhosttyKey.GHOSTTY_KEY_T,
      VtKey.u: GhosttyKey.GHOSTTY_KEY_U,
      VtKey.v: GhosttyKey.GHOSTTY_KEY_V,
      VtKey.w: GhosttyKey.GHOSTTY_KEY_W,
      VtKey.x: GhosttyKey.GHOSTTY_KEY_X,
      VtKey.y: GhosttyKey.GHOSTTY_KEY_Y,
      VtKey.z: GhosttyKey.GHOSTTY_KEY_Z,
      VtKey.minus: GhosttyKey.GHOSTTY_KEY_MINUS,
      VtKey.period: GhosttyKey.GHOSTTY_KEY_PERIOD,
      VtKey.quote: GhosttyKey.GHOSTTY_KEY_QUOTE,
      VtKey.semicolon: GhosttyKey.GHOSTTY_KEY_SEMICOLON,
      VtKey.slash: GhosttyKey.GHOSTTY_KEY_SLASH,
      VtKey.altLeft: GhosttyKey.GHOSTTY_KEY_ALT_LEFT,
      VtKey.altRight: GhosttyKey.GHOSTTY_KEY_ALT_RIGHT,
      VtKey.backspace: GhosttyKey.GHOSTTY_KEY_BACKSPACE,
      VtKey.capsLock: GhosttyKey.GHOSTTY_KEY_CAPS_LOCK,
      VtKey.contextMenu: GhosttyKey.GHOSTTY_KEY_CONTEXT_MENU,
      VtKey.controlLeft: GhosttyKey.GHOSTTY_KEY_CONTROL_LEFT,
      VtKey.controlRight: GhosttyKey.GHOSTTY_KEY_CONTROL_RIGHT,
      VtKey.enter: GhosttyKey.GHOSTTY_KEY_ENTER,
      VtKey.metaLeft: GhosttyKey.GHOSTTY_KEY_META_LEFT,
      VtKey.metaRight: GhosttyKey.GHOSTTY_KEY_META_RIGHT,
      VtKey.shiftLeft: GhosttyKey.GHOSTTY_KEY_SHIFT_LEFT,
      VtKey.shiftRight: GhosttyKey.GHOSTTY_KEY_SHIFT_RIGHT,
      VtKey.space: GhosttyKey.GHOSTTY_KEY_SPACE,
      VtKey.tab: GhosttyKey.GHOSTTY_KEY_TAB,
      VtKey.convert: GhosttyKey.GHOSTTY_KEY_CONVERT,
      VtKey.kanaMode: GhosttyKey.GHOSTTY_KEY_KANA_MODE,
      VtKey.nonConvert: GhosttyKey.GHOSTTY_KEY_NON_CONVERT,
      VtKey.delete: GhosttyKey.GHOSTTY_KEY_DELETE,
      VtKey.end: GhosttyKey.GHOSTTY_KEY_END,
      VtKey.help: GhosttyKey.GHOSTTY_KEY_HELP,
      VtKey.home: GhosttyKey.GHOSTTY_KEY_HOME,
      VtKey.insert: GhosttyKey.GHOSTTY_KEY_INSERT,
      VtKey.pageDown: GhosttyKey.GHOSTTY_KEY_PAGE_DOWN,
      VtKey.pageUp: GhosttyKey.GHOSTTY_KEY_PAGE_UP,
      VtKey.arrowDown: GhosttyKey.GHOSTTY_KEY_ARROW_DOWN,
      VtKey.arrowLeft: GhosttyKey.GHOSTTY_KEY_ARROW_LEFT,
      VtKey.arrowRight: GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT,
      VtKey.arrowUp: GhosttyKey.GHOSTTY_KEY_ARROW_UP,
      VtKey.numLock: GhosttyKey.GHOSTTY_KEY_NUM_LOCK,
      VtKey.numpad0: GhosttyKey.GHOSTTY_KEY_NUMPAD_0,
      VtKey.numpad1: GhosttyKey.GHOSTTY_KEY_NUMPAD_1,
      VtKey.numpad2: GhosttyKey.GHOSTTY_KEY_NUMPAD_2,
      VtKey.numpad3: GhosttyKey.GHOSTTY_KEY_NUMPAD_3,
      VtKey.numpad4: GhosttyKey.GHOSTTY_KEY_NUMPAD_4,
      VtKey.numpad5: GhosttyKey.GHOSTTY_KEY_NUMPAD_5,
      VtKey.numpad6: GhosttyKey.GHOSTTY_KEY_NUMPAD_6,
      VtKey.numpad7: GhosttyKey.GHOSTTY_KEY_NUMPAD_7,
      VtKey.numpad8: GhosttyKey.GHOSTTY_KEY_NUMPAD_8,
      VtKey.numpad9: GhosttyKey.GHOSTTY_KEY_NUMPAD_9,
      VtKey.numpadAdd: GhosttyKey.GHOSTTY_KEY_NUMPAD_ADD,
      VtKey.numpadBackspace: GhosttyKey.GHOSTTY_KEY_NUMPAD_BACKSPACE,
      VtKey.numpadClear: GhosttyKey.GHOSTTY_KEY_NUMPAD_CLEAR,
      VtKey.numpadClearEntry: GhosttyKey.GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY,
      VtKey.numpadComma: GhosttyKey.GHOSTTY_KEY_NUMPAD_COMMA,
      VtKey.numpadDecimal: GhosttyKey.GHOSTTY_KEY_NUMPAD_DECIMAL,
      VtKey.numpadDivide: GhosttyKey.GHOSTTY_KEY_NUMPAD_DIVIDE,
      VtKey.numpadEnter: GhosttyKey.GHOSTTY_KEY_NUMPAD_ENTER,
      VtKey.numpadEqual: GhosttyKey.GHOSTTY_KEY_NUMPAD_EQUAL,
      VtKey.numpadMemoryAdd: GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_ADD,
      VtKey.numpadMemoryClear: GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR,
      VtKey.numpadMemoryRecall: GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_RECALL,
      VtKey.numpadMemoryStore: GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_STORE,
      VtKey.numpadMemorySubtract: GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT,
      VtKey.numpadMultiply: GhosttyKey.GHOSTTY_KEY_NUMPAD_MULTIPLY,
      VtKey.numpadParenLeft: GhosttyKey.GHOSTTY_KEY_NUMPAD_PAREN_LEFT,
      VtKey.numpadParenRight: GhosttyKey.GHOSTTY_KEY_NUMPAD_PAREN_RIGHT,
      VtKey.numpadSubtract: GhosttyKey.GHOSTTY_KEY_NUMPAD_SUBTRACT,
      VtKey.numpadSeparator: GhosttyKey.GHOSTTY_KEY_NUMPAD_SEPARATOR,
      VtKey.numpadUp: GhosttyKey.GHOSTTY_KEY_NUMPAD_UP,
      VtKey.numpadDown: GhosttyKey.GHOSTTY_KEY_NUMPAD_DOWN,
      VtKey.numpadRight: GhosttyKey.GHOSTTY_KEY_NUMPAD_RIGHT,
      VtKey.numpadLeft: GhosttyKey.GHOSTTY_KEY_NUMPAD_LEFT,
      VtKey.numpadBegin: GhosttyKey.GHOSTTY_KEY_NUMPAD_BEGIN,
      VtKey.numpadHome: GhosttyKey.GHOSTTY_KEY_NUMPAD_HOME,
      VtKey.numpadEnd: GhosttyKey.GHOSTTY_KEY_NUMPAD_END,
      VtKey.numpadInsert: GhosttyKey.GHOSTTY_KEY_NUMPAD_INSERT,
      VtKey.numpadDelete: GhosttyKey.GHOSTTY_KEY_NUMPAD_DELETE,
      VtKey.numpadPageUp: GhosttyKey.GHOSTTY_KEY_NUMPAD_PAGE_UP,
      VtKey.numpadPageDown: GhosttyKey.GHOSTTY_KEY_NUMPAD_PAGE_DOWN,
      VtKey.escape: GhosttyKey.GHOSTTY_KEY_ESCAPE,
      VtKey.f1: GhosttyKey.GHOSTTY_KEY_F1,
      VtKey.f2: GhosttyKey.GHOSTTY_KEY_F2,
      VtKey.f3: GhosttyKey.GHOSTTY_KEY_F3,
      VtKey.f4: GhosttyKey.GHOSTTY_KEY_F4,
      VtKey.f5: GhosttyKey.GHOSTTY_KEY_F5,
      VtKey.f6: GhosttyKey.GHOSTTY_KEY_F6,
      VtKey.f7: GhosttyKey.GHOSTTY_KEY_F7,
      VtKey.f8: GhosttyKey.GHOSTTY_KEY_F8,
      VtKey.f9: GhosttyKey.GHOSTTY_KEY_F9,
      VtKey.f10: GhosttyKey.GHOSTTY_KEY_F10,
      VtKey.f11: GhosttyKey.GHOSTTY_KEY_F11,
      VtKey.f12: GhosttyKey.GHOSTTY_KEY_F12,
      VtKey.f13: GhosttyKey.GHOSTTY_KEY_F13,
      VtKey.f14: GhosttyKey.GHOSTTY_KEY_F14,
      VtKey.f15: GhosttyKey.GHOSTTY_KEY_F15,
      VtKey.f16: GhosttyKey.GHOSTTY_KEY_F16,
      VtKey.f17: GhosttyKey.GHOSTTY_KEY_F17,
      VtKey.f18: GhosttyKey.GHOSTTY_KEY_F18,
      VtKey.f19: GhosttyKey.GHOSTTY_KEY_F19,
      VtKey.f20: GhosttyKey.GHOSTTY_KEY_F20,
      VtKey.f21: GhosttyKey.GHOSTTY_KEY_F21,
      VtKey.f22: GhosttyKey.GHOSTTY_KEY_F22,
      VtKey.f23: GhosttyKey.GHOSTTY_KEY_F23,
      VtKey.f24: GhosttyKey.GHOSTTY_KEY_F24,
      VtKey.f25: GhosttyKey.GHOSTTY_KEY_F25,
      VtKey.fn: GhosttyKey.GHOSTTY_KEY_FN,
      VtKey.fnLock: GhosttyKey.GHOSTTY_KEY_FN_LOCK,
      VtKey.printScreen: GhosttyKey.GHOSTTY_KEY_PRINT_SCREEN,
      VtKey.scrollLock: GhosttyKey.GHOSTTY_KEY_SCROLL_LOCK,
      VtKey.pause: GhosttyKey.GHOSTTY_KEY_PAUSE,
      VtKey.browserBack: GhosttyKey.GHOSTTY_KEY_BROWSER_BACK,
      VtKey.browserFavorites: GhosttyKey.GHOSTTY_KEY_BROWSER_FAVORITES,
      VtKey.browserForward: GhosttyKey.GHOSTTY_KEY_BROWSER_FORWARD,
      VtKey.browserHome: GhosttyKey.GHOSTTY_KEY_BROWSER_HOME,
      VtKey.browserRefresh: GhosttyKey.GHOSTTY_KEY_BROWSER_REFRESH,
      VtKey.browserSearch: GhosttyKey.GHOSTTY_KEY_BROWSER_SEARCH,
      VtKey.browserStop: GhosttyKey.GHOSTTY_KEY_BROWSER_STOP,
      VtKey.eject: GhosttyKey.GHOSTTY_KEY_EJECT,
      VtKey.launchApp1: GhosttyKey.GHOSTTY_KEY_LAUNCH_APP_1,
      VtKey.launchApp2: GhosttyKey.GHOSTTY_KEY_LAUNCH_APP_2,
      VtKey.launchMail: GhosttyKey.GHOSTTY_KEY_LAUNCH_MAIL,
      VtKey.mediaPlayPause: GhosttyKey.GHOSTTY_KEY_MEDIA_PLAY_PAUSE,
      VtKey.mediaSelect: GhosttyKey.GHOSTTY_KEY_MEDIA_SELECT,
      VtKey.mediaStop: GhosttyKey.GHOSTTY_KEY_MEDIA_STOP,
      VtKey.mediaTrackNext: GhosttyKey.GHOSTTY_KEY_MEDIA_TRACK_NEXT,
      VtKey.mediaTrackPrevious: GhosttyKey.GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS,
      VtKey.power: GhosttyKey.GHOSTTY_KEY_POWER,
      VtKey.sleep: GhosttyKey.GHOSTTY_KEY_SLEEP,
      VtKey.audioVolumeDown: GhosttyKey.GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
      VtKey.audioVolumeMute: GhosttyKey.GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
      VtKey.audioVolumeUp: GhosttyKey.GHOSTTY_KEY_AUDIO_VOLUME_UP,
      VtKey.wakeUp: GhosttyKey.GHOSTTY_KEY_WAKE_UP,
      VtKey.copy: GhosttyKey.GHOSTTY_KEY_COPY,
      VtKey.cut: GhosttyKey.GHOSTTY_KEY_CUT,
      VtKey.paste: GhosttyKey.GHOSTTY_KEY_PASTE,
    });
  });

  test('KeyAction matches GhosttyKeyAction', () {
    expectCodec(keyActionCodec, KeyAction.values, KeyAction.unknown, {
      KeyAction.release: GhosttyKeyAction.GHOSTTY_KEY_ACTION_RELEASE,
      KeyAction.press: GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
      KeyAction.repeat: GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT,
    });
  });

  test('OptionAsAlt matches GhosttyOptionAsAlt', () {
    expectCodec(optionAsAltCodec, OptionAsAlt.values, OptionAsAlt.unknown, {
      OptionAsAlt.none: GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_FALSE,
      OptionAsAlt.both: GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_TRUE,
      OptionAsAlt.left: GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_LEFT,
      OptionAsAlt.right: GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_RIGHT,
    });
  });

  test('MouseAction matches GhosttyMouseAction', () {
    expectCodec(mouseActionCodec, MouseAction.values, MouseAction.unknown, {
      MouseAction.press: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
      MouseAction.release: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
      MouseAction.motion: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
    });
  });

  test('MouseButton matches GhosttyMouseButton', () {
    expectCodec(mouseButtonCodec, MouseButton.values, MouseButton.unknown, {
      MouseButton.unidentified: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_UNKNOWN,
      MouseButton.left: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
      MouseButton.right: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_RIGHT,
      MouseButton.middle: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_MIDDLE,
      MouseButton.four: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FOUR,
      MouseButton.five: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FIVE,
      MouseButton.six: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_SIX,
      MouseButton.seven: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_SEVEN,
      MouseButton.eight: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_EIGHT,
      MouseButton.nine: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_NINE,
      MouseButton.ten: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_TEN,
      MouseButton.eleven: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_ELEVEN,
    });
  });

  test('MouseTrackingMode matches GhosttyMouseTrackingMode', () {
    expectCodec(
      mouseTrackingModeCodec,
      MouseTrackingMode.values,
      MouseTrackingMode.unknown,
      {
        MouseTrackingMode.none:
            GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NONE,
        MouseTrackingMode.x10:
            GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_X10,
        MouseTrackingMode.normal:
            GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL,
        MouseTrackingMode.button:
            GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_BUTTON,
        MouseTrackingMode.any:
            GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY,
      },
    );
  });

  test('MouseFormat matches GhosttyMouseFormat', () {
    expectCodec(mouseFormatCodec, MouseFormat.values, MouseFormat.unknown, {
      MouseFormat.x10: GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_X10,
      MouseFormat.utf8: GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_UTF8,
      MouseFormat.sgr: GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR,
      MouseFormat.urxvt: GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_URXVT,
      MouseFormat.sgrPixels: GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR_PIXELS,
    });
  });

  test('VtFocusEvent matches GhosttyFocusEvent', () {
    expectCodec(vtFocusEventCodec, VtFocusEvent.values, VtFocusEvent.unknown, {
      VtFocusEvent.gained: GhosttyFocusEvent.GHOSTTY_FOCUS_GAINED,
      VtFocusEvent.lost: GhosttyFocusEvent.GHOSTTY_FOCUS_LOST,
    });
  });

  test('ModeReportState matches GhosttyModeReportState', () {
    expectCodec(
      modeReportStateCodec,
      ModeReportState.values,
      ModeReportState.unknown,
      {
        ModeReportState.notRecognized:
            GhosttyModeReportState.GHOSTTY_MODE_REPORT_NOT_RECOGNIZED,
        ModeReportState.set: GhosttyModeReportState.GHOSTTY_MODE_REPORT_SET,
        ModeReportState.reset: GhosttyModeReportState.GHOSTTY_MODE_REPORT_RESET,
        ModeReportState.permanentlySet:
            GhosttyModeReportState.GHOSTTY_MODE_REPORT_PERMANENTLY_SET,
        ModeReportState.permanentlyReset:
            GhosttyModeReportState.GHOSTTY_MODE_REPORT_PERMANENTLY_RESET,
      },
    );
  });

  test('VtColorScheme matches GhosttyColorScheme', () {
    expectCodec(
      vtColorSchemeCodec,
      VtColorScheme.values,
      VtColorScheme.unknown,
      {
        VtColorScheme.light: GhosttyColorScheme.GHOSTTY_COLOR_SCHEME_LIGHT,
        VtColorScheme.dark: GhosttyColorScheme.GHOSTTY_COLOR_SCHEME_DARK,
      },
    );
  });

  test('SizeReportStyle matches GhosttySizeReportStyle', () {
    expectCodec(
      sizeReportStyleCodec,
      SizeReportStyle.values,
      SizeReportStyle.unknown,
      {
        SizeReportStyle.mode2048:
            GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_MODE_2048,
        SizeReportStyle.csi14t:
            GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_CSI_14_T,
        SizeReportStyle.csi16t:
            GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_CSI_16_T,
        SizeReportStyle.csi18t:
            GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_CSI_18_T,
        SizeReportStyle.csi19t:
            GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_CSI_19_T,
      },
    );
  });

  group('value types', () {
    test('VtKeyEvent defaults, equality and copyWith', () {
      const event = VtKeyEvent(key: VtKey.a, text: 'a');
      expect(event.action, KeyAction.press);
      expect(event.modifiers, KeyModifiers.none);
      expect(event.consumedModifiers, KeyModifiers.none);
      expect(event.isComposing, isFalse);
      expect(event.unshiftedCodepoint, 0);
      final copy = event.copyWith(action: KeyAction.release);
      expect(copy.action, KeyAction.release);
      expect(copy.text, 'a');
      expect(copy, isNot(event));
      expect(copy.copyWith(action: KeyAction.press), event);
      expect(copy.copyWith(action: KeyAction.press).hashCode, event.hashCode);
      expect('$event', "VtKeyEvent(a, press, KeyModifiers(), text: 'a')");
    });

    test('VtMouseEvent equality and copyWith(clearButton)', () {
      const event = VtMouseEvent(
        action: MouseAction.press,
        button: MouseButton.left,
        x: 1,
        y: 2,
      );
      final motion = event.copyWith(
        action: MouseAction.motion,
        clearButton: true,
      );
      expect(motion.button, isNull);
      expect(motion.x, 1);
      expect(event.copyWith(), event);
      expect(event.copyWith().hashCode, event.hashCode);
      expect(motion, isNot(event));
    });

    test('MouseEncoderSize and SizeReportSize equality', () {
      const a = MouseEncoderSize(
        screenWidth: 100,
        screenHeight: 50,
        cellWidth: 10,
        cellHeight: 25,
      );
      const b = MouseEncoderSize(
        screenWidth: 100,
        screenHeight: 50,
        cellWidth: 10,
        cellHeight: 25,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.paddingLeft, 0);
      const s = SizeReportSize(
        rows: 1,
        columns: 2,
        cellWidth: 3,
        cellHeight: 4,
      );
      expect(
        s,
        const SizeReportSize(rows: 1, columns: 2, cellWidth: 3, cellHeight: 4),
      );
      expect(
        s,
        isNot(
          const SizeReportSize(
            rows: 2,
            columns: 1,
            cellWidth: 3,
            cellHeight: 4,
          ),
        ),
      );
    });
  });
}
