import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';
import 'package:ghostty_dart_xterm/src/internal/terminal_internals.dart';

/// A terminal disposed after the test.
Terminal newTerminal({
  int maxLines = 1000,
  void Function()? onBell,
  void Function(String title)? onTitleChange,
  void Function(String icon)? onIconChange,
  void Function(String data)? onOutput,
  void Function(int width, int height, int pixelWidth, int pixelHeight)?
  onResize,
  TerminalTargetPlatform platform = TerminalTargetPlatform.unknown,
  TerminalInputHandler? inputHandler = defaultInputHandler,
  void Function(String code, List<String> args)? onPrivateOSC,
  bool reflowEnabled = true,
  void Function(Uint8List data)? onOutputBytes,
}) {
  final terminal = Terminal(
    maxLines: maxLines,
    onBell: onBell,
    onTitleChange: onTitleChange,
    onIconChange: onIconChange,
    onOutput: onOutput,
    onResize: onResize,
    platform: platform,
    inputHandler: inputHandler,
    onPrivateOSC: onPrivateOSC,
    reflowEnabled: reflowEnabled,
    onOutputBytes: onOutputBytes,
  );
  addTearDown(terminal.dispose);
  return terminal;
}

void main() {
  group('construction', () {
    test('has xterm defaults', () {
      final terminal = newTerminal();
      expect(terminal.maxLines, 1000);
      expect(terminal.viewWidth, 80);
      expect(terminal.viewHeight, 24);
      expect(terminal.platform, TerminalTargetPlatform.unknown);
      expect(identical(terminal.inputHandler, defaultInputHandler), isTrue);
      expect(identical(terminal.mouseHandler, defaultMouseHandler), isTrue);
      expect(terminal.reflowEnabled, isTrue);
      expect(terminal.isUsingAltBuffer, isFalse);
      expect(terminal.buffer, same(terminal.mainBuffer));
      expect(terminal.lines.length, 24);
      expect(terminal.autoWrapMode, isTrue);
      expect(terminal.cursorVisibleMode, isTrue);
      expect(terminal.mouseMode, MouseMode.none);
      expect(terminal.mouseReportMode, MouseReportMode.normal);
    });

    test('maps maxLines to a scrollback line limit', () {
      final terminal = newTerminal(maxLines: 500);
      final vt = terminalInternals(terminal).vtController.terminal;
      expect(vt.scrollbackMaxLines, 500 - 24);
      expect(vt.scrollbackMaxBytes, isNull);
      terminal.resize(80, 100);
      expect(vt.scrollbackMaxLines, 400);
    });

    test('keeps at least maxLines lines', () {
      final terminal = newTerminal(maxLines: 100);
      terminal.write('\r\n' * 5000);
      expect(terminal.buffer.height, greaterThanOrEqualTo(100));
      expect(terminal.buffer.height, lessThan(5000));
    });
  });

  group('write', () {
    test('notifies listeners once per chunk', () {
      final terminal = newTerminal();
      var calls = 0;
      terminal.addListener(() => calls++);
      terminal.write('hello');
      terminal.writeBytes(Uint8List.fromList(utf8.encode(' world')));
      expect(calls, 2);
      expect(terminal.buffer.lines[0].toString(), 'hello world');
      expect(terminal.listeners, hasLength(1));
    });

    test('writeBytes keeps a UTF-8 character split across chunks', () {
      final terminal = newTerminal();
      final bytes = utf8.encode('é');
      terminal.writeBytes(Uint8List.fromList(bytes.sublist(0, 1)));
      terminal.writeBytes(Uint8List.fromList(bytes.sublist(1)));
      expect(terminal.buffer.lines[0].toString(), 'é');
    });
  });

  group('callbacks', () {
    test('onBell and onTitleChange', () {
      var bells = 0;
      final titles = <String>[];
      final terminal = newTerminal(
        onBell: () => bells++,
        onTitleChange: titles.add,
      );
      terminal.write('\x07\x1b]2;one\x07\x1b]0;two\x1b\\');
      expect(bells, 1);
      expect(titles, ['one', 'two']);
    });

    test('callbacks can be reassigned after construction', () {
      final terminal = newTerminal();
      var bells = 0;
      terminal.onBell = () => bells++;
      terminal.write('\x07');
      expect(bells, 1);
    });

    test('onIconChange is called by setIconName only', () {
      final icons = <String>[];
      final terminal = newTerminal(onIconChange: icons.add);
      terminal.write('\x1b]1;icon\x07\x1b]0;both\x07');
      expect(icons, isEmpty);
      terminal.setIconName('mine');
      expect(icons, ['mine']);
    });

    test('onPrivateOSC gets OSCs libghostty-vt does not implement', () {
      final calls = <String>[];
      final terminal = newTerminal(
        onPrivateOSC: (code, args) =>
            calls.add('$code${args.map((a) => '|$a').join()}'),
      );
      terminal.write('\x1b]6\x07');
      terminal.write('\x1b]666;hello;world\x1b\\');
      terminal.write('\x1b]hello;world\x07');
      // Implemented by libghostty-vt: OSC 0 (title), OSC 66 (text sizing).
      terminal.write('\x1b]0;title\x07\x1b]66;hello world\x07');
      expect(calls, ['6', '666|hello|world', 'hello|world']);
    });

    test('a callback may write again', () {
      late Terminal terminal;
      terminal = newTerminal(
        onPrivateOSC: (code, args) => terminal.write('[$code]'),
      );
      terminal.write('\x1b]7777;x\x07after');
      expect(terminal.buffer.lines[0].toString(), 'after[7777]');
    });

    test('a window resize request resizes the terminal', () {
      final sizes = <List<int>>[];
      final terminal = newTerminal(
        onResize: (w, h, pw, ph) => sizes.add([w, h, pw, ph]),
      );
      terminal.write('\x1b[8;20;60t');
      expect(sizes, [
        [60, 20, 0, 0],
      ]);
      expect(terminal.viewWidth, 60);
      expect(terminal.viewHeight, 20);
    });
  });

  group('output', () {
    test('Dart input goes to onOutputBytes, then onOutput', () {
      final events = <Object>[];
      final terminal = newTerminal(
        onOutput: (data) => events.add('text:$data'),
        onOutputBytes: (data) => events.add(data.toList()),
      );
      terminal.textInput('é');
      expect(events, [
        [0xc3, 0xa9],
        'text:é',
      ]);
    });

    test('replies from libghostty-vt reach both callbacks', () {
      final text = <String>[];
      final bytes = <List<int>>[];
      final terminal = newTerminal(
        onOutput: text.add,
        onOutputBytes: (data) => bytes.add(data.toList()),
      );
      terminal.write('\x1b[3;5H\x1b[6n');
      expect(text, ['\x1b[3;5R']);
      expect(bytes, [utf8.encode('\x1b[3;5R')]);
    });

    test('engine bytes that are not UTF-8 are decoded as Latin-1', () {
      final text = <String>[];
      final bytes = <List<int>>[];
      final terminal = newTerminal(
        onOutput: text.add,
        onOutputBytes: (data) => bytes.add(data.toList()),
      );
      // An X10 mouse report at column 223 (a byte >= 0x80), as the view's
      // encoder sends it through the controller.
      final report = [0x1b, 0x5b, 0x4d, 0x20, 0xff, 0x21];
      terminalInternals(terminal).vtController.onOutput!(
        Uint8List.fromList(report),
      );
      expect(bytes, [report]);
      expect(text, ['\x1b[M ÿ!']);
      expect(latin1.encode(text.single), report);
    });

    test('keyInput runs the input handler', () {
      final output = <String>[];
      final terminal = newTerminal(onOutput: output.add);
      expect(terminal.keyInput(TerminalKey.enter), isTrue);
      expect(terminal.keyInput(TerminalKey.keyC, ctrl: true), isTrue);
      expect(output, ['\r', '\x03']);
    });

    test('keyInput works without an input handler', () {
      final terminal = newTerminal(inputHandler: null);
      expect(terminal.keyInput(TerminalKey.keyA), isFalse);
    });

    test('charInput and textInput', () {
      final output = <String>[];
      final terminal = newTerminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.linux,
      );
      expect(terminal.charInput('c'.codeUnitAt(0), ctrl: true), isTrue);
      expect(terminal.charInput('['.codeUnitAt(0), ctrl: true), isTrue);
      expect(terminal.charInput('x'.codeUnitAt(0), alt: true), isTrue);
      expect(terminal.charInput('x'.codeUnitAt(0)), isFalse);
      terminal.textInput('ls');
      expect(output, ['\x03', '\x1b', '\x1bX', 'ls']);
    });

    test('paste wraps text in bracketed paste mode', () {
      final output = <String>[];
      final terminal = newTerminal(onOutput: output.add);
      terminal.paste('a\nb');
      terminal.write('\x1b[?2004h');
      terminal.paste('c');
      expect(output, ['a\nb', '\x1b[200~c\x1b[201~']);
    });

    test('mouseInput reports once the program tracks the mouse', () {
      final output = <String>[];
      final terminal = newTerminal(onOutput: output.add);
      const at = CellOffset(10, 10);
      expect(
        terminal.mouseInput(
          TerminalMouseButton.left,
          TerminalMouseButtonState.down,
          at,
        ),
        isFalse,
      );
      terminal.write('\x1b[?1000h\x1b[?1006h');
      expect(terminal.mouseMode, MouseMode.upDownScroll);
      expect(terminal.mouseReportMode, MouseReportMode.sgr);
      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        at,
      );
      expect(output, ['\x1b[<0;11;11M']);
    });
  });

  group('resize', () {
    test('calls onResize with its own arguments, before resizing', () {
      final calls = <List<int>>[];
      late Terminal terminal;
      terminal = newTerminal(
        onResize: (w, h, pw, ph) =>
            calls.add([w, h, pw, ph, terminal.viewWidth]),
      );
      terminal.resize(100, 30, 9, 18);
      terminal.resize(100, 30);
      terminal.resize(0, -5);
      expect(calls, [
        [100, 30, 9, 18, 80],
        [100, 30, 0, 0, 100],
        [1, 1, 0, 0, 100],
      ]);
      expect(terminal.viewWidth, 1);
      expect(terminal.viewHeight, 1);
    });

    test('converts a view resize to cell pixels from the view ratio', () {
      final calls = <List<int>>[];
      final terminal = newTerminal(
        onResize: (w, h, pw, ph) => calls.add([w, h, pw, ph]),
      );
      final internals = terminalInternals(terminal);
      internals.vtController.resize(100, 30, cellWidthPx: 18, cellHeightPx: 37);
      internals.viewDevicePixelRatio = 2;
      internals.vtController.resize(90, 30);
      expect(calls, [
        [100, 30, 0, 0],
        [90, 30, 9, 19],
      ]);
    });

    test('reflows unless reflowEnabled is false', () {
      final terminal = newTerminal();
      terminal.write('1234567890abcdefg');
      terminal.resize(10, 10);
      expect(terminal.buffer.lines[0].toString(), '1234567890');
      expect(terminal.buffer.lines[1].toString(), 'abcdefg');
      expect(terminal.buffer.lines[1].isWrapped, isTrue);

      terminal.reflowEnabled = false;
      terminal.resize(20, 10);
      expect(terminal.buffer.lines[0].toString(), '1234567890');
      expect(terminal.buffer.lines[1].toString(), 'abcdefg');
      // Autowrap is restored after the resize.
      expect(terminal.autoWrapMode, isTrue);
    });
  });

  group('modes', () {
    test('read the terminal', () {
      final terminal = newTerminal();
      terminal.write(
        '\x1b[4h\x1b[20h\x1b[?1h\x1b[?5h\x1b[?12h\x1b[?25l\x1b[?66h'
        '\x1b[?1004h\x1b[?2004h\x1b[?1003h\x1b[?1015h',
      );
      expect(terminal.insertMode, isTrue);
      expect(terminal.lineFeedMode, isTrue);
      expect(terminal.cursorKeysMode, isTrue);
      expect(terminal.reverseDisplayMode, isTrue);
      expect(terminal.cursorBlinkMode, isTrue);
      expect(terminal.cursorVisibleMode, isFalse);
      expect(terminal.appKeypadMode, isTrue);
      expect(terminal.reportFocusMode, isTrue);
      expect(terminal.bracketedPasteMode, isTrue);
      expect(terminal.mouseMode, MouseMode.upDownScrollMove);
      expect(terminal.mouseReportMode, MouseReportMode.urxvt);
    });

    test('mode setters write the DEC and ANSI sequences', () {
      final terminal = newTerminal();
      terminal
        ..setInsertMode(true)
        ..setCursorKeysMode(true)
        ..setOriginMode(true)
        ..setAutoWrapMode(false)
        ..setCursorVisibleMode(false)
        ..setAppKeypadMode(true)
        ..setReportFocusMode(true)
        ..setAltBufferMouseScrollMode(false)
        ..setBracketedPasteMode(true)
        ..setMouseMode(MouseMode.upDownScrollDrag)
        ..setMouseReportMode(MouseReportMode.utf);
      expect(terminal.insertMode, isTrue);
      expect(terminal.cursorKeysMode, isTrue);
      expect(terminal.originMode, isTrue);
      expect(terminal.autoWrapMode, isFalse);
      expect(terminal.cursorVisibleMode, isFalse);
      expect(terminal.appKeypadMode, isTrue);
      expect(terminal.reportFocusMode, isTrue);
      expect(terminal.altBufferMouseScrollMode, isFalse);
      expect(terminal.bracketedPasteMode, isTrue);
      expect(terminal.mouseMode, MouseMode.upDownScrollDrag);
      expect(terminal.mouseReportMode, MouseReportMode.utf);

      terminal
        ..setMouseMode(MouseMode.clickOnly)
        ..setMouseReportMode(MouseReportMode.sgr);
      expect(terminal.mouseMode, MouseMode.clickOnly);
      expect(terminal.mouseReportMode, MouseReportMode.sgr);
      terminal
        ..setMouseMode(MouseMode.none)
        ..setMouseReportMode(MouseReportMode.normal);
      expect(terminal.mouseMode, MouseMode.none);
      expect(terminal.mouseReportMode, MouseReportMode.normal);
    });

    test('useAltBuffer and useMainBuffer switch screens', () {
      final terminal = newTerminal();
      terminal.write('main');
      terminal.useAltBuffer();
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(terminal.buffer, same(terminal.altBuffer));
      terminal.useMainBuffer();
      expect(terminal.isUsingAltBuffer, isFalse);
      expect(terminal.buffer.lines[0].toString(), 'main');
    });
  });

  group('EscapeHandler methods', () {
    test('move the cursor and edit the screen', () {
      final terminal = newTerminal();
      terminal.write('abcdef\r\nghijkl');
      terminal.setCursor(2, 0);
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (2, 0));
      terminal.deleteChars(2);
      expect(terminal.buffer.lines[0].toString(), 'abef');
      terminal.insertBlankChars(1);
      expect(terminal.buffer.lines[0].getText(), 'abef');
      expect(terminal.buffer.lines[0].getCodePoint(2), 0);
      terminal.eraseLineRight();
      expect(terminal.buffer.lines[0].toString(), 'ab');
      terminal.setCursorY(1);
      terminal.setCursorX(3);
      terminal.eraseChars(2);
      expect(terminal.buffer.lines[1].toString(), 'ghil');
      terminal.moveCursorX(-1);
      terminal.moveCursorY(-1);
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (2, 0));
      terminal.eraseDisplay();
      expect(terminal.buffer.getText().trim(), isEmpty);
    });

    test('setMargins keeps the cursor and limits insertLines', () {
      final terminal = newTerminal();
      terminal.resize(10, 10);
      for (var i = 0; i < 10; i++) {
        terminal.write('line$i${i < 9 ? '\r\n' : ''}');
      }
      terminal.setCursor(4, 7);
      terminal.setMargins(2, 6);
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (4, 7));
      terminal.setCursor(0, 4);
      terminal.insertLines(1);
      expect(
        [for (var i = 1; i < 9; i++) terminal.buffer.lines[i].toString()],
        ['line1', 'line2', 'line3', '', 'line4', 'line5', 'line7', 'line8'],
      );
    });

    test('SGR setters change the cursor style', () {
      final terminal = newTerminal();
      terminal
        ..setCursorBold()
        ..setCursorFaint()
        ..setCursorItalic()
        ..setForegroundColor16(9)
        ..setBackgroundColorRgb(1, 2, 3);
      var style = terminal.cursor;
      expect(style.isBold, isTrue);
      expect(style.isFaint, isTrue);
      expect(style.isItalis, isTrue);
      expect(style.foreground, CellColor.named | 9);
      expect(style.background, CellColor.rgb | 0x010203);

      terminal.unsetCursorBold();
      style = terminal.cursor;
      expect(style.isBold, isFalse);
      expect(style.isFaint, isTrue, reason: 'SGR 22 must not drop faint');

      terminal
        ..setForegroundColor256(200)
        ..resetBackground()
        ..unsetCursorItalic();
      style = terminal.cursor;
      expect(style.foreground, CellColor.palette | 200);
      expect(style.background, 0);
      expect(style.isItalis, isFalse);

      terminal.resetCursorStyle();
      style = terminal.cursor;
      expect((style.foreground, style.background, style.attrs), (0, 0, 0));
    });

    test('the cursor style is a copy', () {
      final terminal = newTerminal();
      terminal.cursor.setBold();
      expect(terminal.cursor.isBold, isFalse);
    });

    test('setTitle, bell and unknownOSC call the callbacks', () {
      final titles = <String>[];
      final osc = <String>[];
      var bells = 0;
      final terminal = newTerminal(
        onTitleChange: titles.add,
        onBell: () => bells++,
        onPrivateOSC: (code, args) => osc.add('$code:${args.join(',')}'),
      );
      terminal
        ..setTitle('a\x07b')
        ..bell()
        ..unknownOSC('1337', ['x']);
      expect(titles, ['ab']);
      expect(bells, 1);
      expect(osc, ['1337:x']);
    });

    test('send* methods emit xterm replies', () {
      final output = <String>[];
      final terminal = newTerminal(onOutput: output.add);
      terminal.setCursor(4, 2);
      terminal
        ..sendPrimaryDeviceAttributes()
        ..sendSecondaryDeviceAttributes()
        ..sendOperatingStatus()
        ..sendCursorPosition()
        ..sendSize();
      expect(output, [
        '\x1b[?1;2c',
        '\x1b[>0;0;0c',
        '\x1b[0n',
        '\x1b[2;4R',
        '\x1b[8;24;80t',
      ]);
    });

    test('do not notify listeners', () {
      final terminal = newTerminal();
      var calls = 0;
      terminal.addListener(() => calls++);
      terminal
        ..setCursor(1, 1)
        ..eraseDisplay();
      expect(calls, 0);
    });

    test('throw StateError inside an escape sequence', () {
      final terminal = newTerminal();
      terminal.write('\x1b[3');
      expect(() => terminal.setCursor(0, 0), throwsStateError);
      expect(() => terminal.buffer.clear(), throwsStateError);
      // The sequence in flight is intact.
      terminal.write('1mX');
      final line = terminal.buffer.lines[0];
      expect(line.toString(), 'X');
      expect(line.getForeground(0), CellColor.named | 1);
      terminal.setCursor(0, 1);
      expect(terminal.buffer.cursorY, 1);
    });

    test('writeChar prints and drops control characters', () {
      final terminal = newTerminal();
      terminal
        ..writeChar('a'.codeUnitAt(0))
        ..writeChar(0x1b)
        ..writeChar('b'.codeUnitAt(0));
      expect(terminal.buffer.lines[0].toString(), 'ab');
    });
  });

  group('dispose', () {
    test('is idempotent and stops engine access', () {
      final terminal = Terminal();
      final anchor = terminal.buffer.createAnchor(1, 1);
      terminal.dispose();
      terminal.dispose();
      expect(() => terminal.write('x'), throwsStateError);
      expect(() => terminal.viewWidth, throwsStateError);
      expect(() => terminal.buffer.lines, throwsStateError);
      expect(() => terminal.setCursor(0, 0), throwsStateError);
      expect(anchor.attached, isFalse);
      expect(terminal.toString(), contains('disposed'));
      expect(terminalInternals(terminal).vtController.isDisposed, isTrue);
    });
  });
}
