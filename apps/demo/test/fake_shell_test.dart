import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_demo/src/fake_shell/fake_shell.dart';
import 'package:ghostty_dart_demo/src/fake_shell/screens.dart';

/// A fake shell whose output is collected as text, and a manual `top`
/// timer.
final class _Harness {
  _Harness({int cols = 80, int rows = 24}) {
    shell = FakeShell(
      cols: cols,
      rows: rows,
      periodicTimer: (period, callback) {
        final timer = _ManualTimer(callback);
        timers.add(timer);
        return timer;
      },
    );
    shell.output.listen(
      (bytes) => _out.write(utf8.decode(bytes)),
      onDone: () => done = true,
    );
  }

  late final FakeShell shell;
  final timers = <_ManualTimer>[];
  final _out = StringBuffer();
  var done = false;

  /// Types [text] and returns what the shell wrote since the last call.
  Future<String> type(String text) async {
    shell.write(utf8.encode(text));
    return flush();
  }

  Future<String> flush() async {
    await Future<void>.delayed(Duration.zero);
    final text = _out.toString();
    _out.clear();
    return text;
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function(Timer) _callback;
  var _active = true;
  var _ticks = 0;

  void fire() {
    if (!_active) return;
    _ticks++;
    _callback(this);
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;
}

const _prompt = 'demo@ghostty';

void main() {
  test('greets with the motd and a prompt in the home directory', () async {
    final h = _Harness();
    final out = await h.flush();
    expect(out, contains('Welcome to the ghostty_dart fake shell.\r\n'));
    expect(out, contains(_prompt));
    expect(out, contains('~'));
    expect(h.shell.workingDirectory, '/home/demo');
  });

  test('a notice comes before the motd', () async {
    final shell = FakeShell(notice: 'no pty here');
    final out = StringBuffer();
    shell.output.listen((b) => out.write(utf8.decode(b)));
    await Future<void>.delayed(Duration.zero);
    expect(out.toString(), startsWith('\x1b[33mno pty here\x1b[0m\r\nWelcome'));
    shell.dispose();
  });

  test('echoes typed characters and runs echo on Enter', () async {
    final h = _Harness();
    await h.flush();
    expect(await h.type('echo hi "a  b"'), 'echo hi "a  b"');
    final out = await h.type('\r');
    expect(out, startsWith('\r\nhi a  b\r\n'));
    expect(out, contains(_prompt));
  });

  test('Backspace deletes before the cursor (DEL and BS)', () async {
    final h = _Harness();
    await h.flush();
    await h.type('echo abX\x7f');
    await h.type('Y\x08');
    expect(await h.type('\r'), startsWith('\r\nab\r\n'));
  });

  test('left arrow, insert in the middle, Home and End', () async {
    final h = _Harness();
    await h.flush();
    await h.type('echo ac');
    await h.type('\x1b[D'); // left
    await h.type('b');
    await h.type('\x1b[H'); // home
    await h.type('\x1b[F'); // end
    await h.type('d');
    expect(await h.type('\r'), startsWith('\r\nabcd\r\n'));
  });

  test('a redraw moves the cursor back over wide characters', () async {
    final h = _Harness();
    await h.flush();
    await h.type('漢字');
    await h.type('\x1b[D');
    final out = await h.type('\x1b[D');
    // Two wide characters right of the cursor: four columns.
    expect(out, endsWith('漢字\x1b[K\x1b[4D'));
  });

  test('up and down recall the history', () async {
    final h = _Harness();
    await h.flush();
    await h.type('echo one\r');
    await h.type('echo two\r');
    await h.type('\x1b[A');
    final up2 = await h.type('\x1bOA'); // SS3 form (application cursor keys)
    expect(up2, contains('echo one'));
    await h.type('\x1b[B');
    expect(await h.type('\r'), startsWith('\r\ntwo\r\n'));
  });

  test('ignores terminal replies, focus reports and OSC strings', () async {
    final h = _Harness();
    await h.flush();
    final out = await h.type(
      '\x1b[?62;22c' // DA1 reply
      '\x1b[I\x1b[O' // focus in/out
      '\x1b]11;rgb:0000/0000/0000\x1b\\' // OSC 11 reply, ST
      '\x1b]10;rgb:ffff/ffff/ffff\x07' // OSC 10 reply, BEL
      '\x1bPpayload\x1b\\', // DCS
    );
    expect(out, isEmpty);
    expect(await h.type('echo ok\r'), contains('\r\nok\r\n'));
  });

  test('Ctrl+C abandons the line; CRLF in a paste is one Enter', () async {
    final h = _Harness();
    await h.flush();
    await h.type('echo nope');
    final out = await h.type('\x03');
    expect(out, startsWith('^C\r\n'));
    final pasted = await h.type('echo a\r\necho b\r\n');
    expect(pasted, contains('\r\na\r\n'));
    expect(pasted, contains('\r\nb\r\n'));
    expect(_prompt.allMatches(pasted).length, 2);
  });

  test('cd, pwd, ls and cat over the fake file system', () async {
    final h = _Harness();
    await h.flush();
    final ls = await h.type('ls\r');
    expect(ls, contains('README.md'));
    expect(ls, contains('\x1b[1;34mprojects\x1b[0m'));
    await h.type('cd projects\r');
    expect(h.shell.workingDirectory, '/home/demo/projects');
    expect(await h.type('pwd\r'), contains('/home/demo/projects\r\n'));
    final long = await h.type('ls -l\r');
    expect(long, contains('-rwxr-xr-x demo demo'));
    expect(long, contains('\x1b[1;32mhello.sh\x1b[0m'));
    expect(await h.type('cat todo.txt\r'), contains('- write more tests\r\n'));
    expect(await h.type('cat nope\r'), contains('cat: nope: no such file'));
    expect(await h.type('cd /nowhere\r'), contains('no such directory'));
    await h.type('cd ..\r');
    expect(h.shell.workingDirectory, '/home/demo');
    await h.type('cd\r');
    expect(h.shell.workingDirectory, '/home/demo');
  });

  test('Tab completes a unique name', () async {
    final h = _Harness();
    await h.flush();
    await h.type('cat no');
    expect(await h.type('\t'), 'tes.txt ');
    expect(await h.type('\r'), contains('Wide characters'));
  });

  test('unknown commands and title', () async {
    final h = _Harness();
    await h.flush();
    expect(
      await h.type('frobnicate\r'),
      contains('fake-sh: command not found: frobnicate'),
    );
    expect(await h.type('title my tab\r'), contains('\x1b]0;my tab\x07'));
  });

  test('colors prints 16, 256 and truecolor samples', () async {
    final h = _Harness();
    await h.flush();
    final out = await h.type('colors\r');
    expect(out, contains('\x1b[97;40m'));
    expect(out, contains('\x1b[48;5;196m'));
    expect(out, contains('\x1b[48;5;255m'));
    expect(out, contains('\x1b[48;2;255;0;0m'));
    expect(out, contains('\x1b[4:3m'));
    expect(out, isNot(contains(RegExp(r'[^\r]\n'))));
  });

  test('top runs on the alternate screen until q', () async {
    final h = _Harness(cols: 100, rows: 30);
    await h.flush();
    final start = await h.type('top\r');
    expect(h.shell.isTopRunning, isTrue);
    expect(start, contains('\x1b[?1049h\x1b[?25l'));
    expect(start, contains(topFrame(cols: 100, rows: 30, tick: 0)));
    expect(start, isNot(contains(_prompt)));

    h.timers.single.fire();
    expect(await h.flush(), topFrame(cols: 100, rows: 30, tick: 1));

    h.shell.resize(120, 40);
    expect(await h.flush(), topFrame(cols: 120, rows: 40, tick: 1));

    // Other keys are ignored while top runs.
    expect(await h.type('x\x1b[A'), isEmpty);

    final stop = await h.type('q');
    expect(stop, startsWith('\x1b[?25h\x1b[?1049l'));
    expect(stop, contains(_prompt));
    expect(h.shell.isTopRunning, isFalse);
    expect(h.timers.single.isActive, isFalse);
  });

  test(
    'exit ends the shell with the given code and closes the output',
    () async {
      final h = _Harness();
      await h.flush();
      expect(await h.type('exit 3\r'), contains('logout\r\n'));
      expect(await h.shell.exitCode, 3);
      expect(h.done, isTrue);
      // Writes after the end are ignored.
      expect(await h.type('echo x\r'), isEmpty);
    },
  );

  test('Ctrl+D on an empty line exits with 0', () async {
    final h = _Harness();
    await h.flush();
    await h.type('\x04');
    expect(await h.shell.exitCode, 0);
  });

  test('dispose stops top and closes the output; idempotent', () async {
    final h = _Harness();
    await h.flush();
    await h.type('top\r');
    h.shell
      ..dispose()
      ..dispose();
    await h.flush();
    expect(h.done, isTrue);
    expect(h.timers.single.isActive, isFalse);
  });

  test('multi-byte input split across writes is decoded', () async {
    final h = _Harness();
    await h.flush();
    final bytes = utf8.encode('echo ñ\r');
    h.shell.write(bytes.sublist(0, 6)); // 'echo ' + first byte of ñ
    h.shell.write(bytes.sublist(6));
    expect(await h.flush(), contains('\r\nñ\r\n'));
  });
}
