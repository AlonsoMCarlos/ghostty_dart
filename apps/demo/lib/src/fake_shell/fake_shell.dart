import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../shell/demo_shell.dart';
import 'fake_fs.dart';
import 'screens.dart';

/// Creates the periodic timer of `top` (tests pass a fake one).
typedef PeriodicTimerFactory =
    Timer Function(Duration period, void Function(Timer timer) callback);

/// A shell written in pure Dart, for platforms without a pty (the web).
///
/// It behaves like a small interactive shell behind a pty: it reads the
/// terminal's input bytes, echoes and edits the command line (arrows,
/// Home/End, history, Ctrl+A/E/U/L/C/D, Tab completion), and runs a few
/// built-in commands over a [FakeFileSystem]: `help`, `echo`, `ls`, `cd`,
/// `pwd`, `cat`, `clear`, `colors`, `top`, `title`, `uname`, `whoami`,
/// `exit`.
///
/// Output uses CRLF line endings, as a pty's `onlcr` would produce, and is
/// delivered asynchronously on [output]. Escape sequences in the input
/// (terminal replies, focus and mouse reports) are parsed and ignored
/// unless they are editing keys.
final class FakeShell implements DemoShell {
  /// Starts the shell for a [cols] × [rows] terminal and queues the
  /// welcome text (after [notice], if given) and the first prompt on
  /// [output].
  FakeShell({
    String? notice,
    int cols = 80,
    int rows = 24,
    FakeFileSystem? fileSystem,
    PeriodicTimerFactory? periodicTimer,
    this.topInterval = const Duration(milliseconds: 500),
  }) : _cols = cols,
       _rows = rows,
       _fs = fileSystem ?? FakeFileSystem.demo(),
       _periodic = periodicTimer ?? Timer.periodic {
    _cwd = _fs.home;
    _input = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_CallbackSink(_onText));
    if (notice != null) _emit('${csi}33m$notice$reset\r\n');
    final motd = _fs.lookup('/etc/motd');
    _emit(
      '${motd is FakeFile ? motd.content.replaceAll('\n', '\r\n') : ''}'
      'Type ${csi}1mhelp$reset for the commands.\r\n',
    );
    _prompt();
  }

  /// How often `top` redraws.
  final Duration topInterval;

  final FakeFileSystem _fs;
  final PeriodicTimerFactory _periodic;
  final _out = StreamController<Uint8List>();
  final _exit = Completer<int>();
  late final Sink<List<int>> _input;

  int _cols;
  int _rows;
  late String _cwd;

  // Input parser state.
  _State _state = _State.ground;
  final _params = StringBuffer();
  var _lastWasCr = false;

  // Line editor: the line as runes, the cursor index into it, history.
  final _line = <int>[];
  var _cursor = 0;
  final _history = <String>[];
  var _historyIndex = 0;

  // `top`, while it runs.
  Timer? _topTimer;
  var _topTick = 0;

  var _closed = false;

  @override
  String get name => 'fake shell';

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int> get exitCode => _exit.future;

  /// The current directory (absolute).
  String get workingDirectory => _cwd;

  /// Whether `top` is on screen.
  bool get isTopRunning => _topTimer != null;

  @override
  void write(Uint8List data) {
    if (_closed) return;
    _input.add(data);
  }

  @override
  void resize(int cols, int rows) {
    if (_closed) return;
    _cols = cols;
    _rows = rows;
    if (isTopRunning) _drawTop();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _topTimer?.cancel();
    _topTimer = null;
    unawaited(_out.close());
  }

  void _emit(String text) {
    if (!_closed) _out.add(utf8.encode(text));
  }

  String get _promptText =>
      '${csi}1;32mdemo@ghostty$reset:${csi}1;34m${_fs.display(_cwd)}$reset\$ ';

  void _prompt() {
    _line.clear();
    _cursor = 0;
    _historyIndex = _history.length;
    _emit(_promptText);
  }

  // ---------------------------------------------------------------- input

  void _onText(String text) {
    for (final rune in text.runes) {
      if (_closed) return;
      _onRune(rune);
    }
  }

  void _onRune(int rune) {
    switch (_state) {
      case _State.ground:
        if (rune == 0x1b) {
          _state = _State.escape;
        } else {
          _onChar(rune);
        }
      case _State.escape:
        _params.clear();
        _state = switch (rune) {
          0x5b => _State.csi, // [
          0x4f => _State.ss3, // O
          0x5d || 0x50 || 0x58 || 0x5e || 0x5f => _State.string, // ] P X ^ _
          _ => _State.ground, // Alt+key: ignored
        };
      case _State.csi:
        if (rune >= 0x40 && rune <= 0x7e) {
          _state = _State.ground;
          _onCsi(_params.toString(), String.fromCharCode(rune));
        } else {
          _params.writeCharCode(rune);
        }
      case _State.ss3:
        _state = _State.ground;
        _onCsi('', String.fromCharCode(rune));
      case _State.string:
        if (rune == 0x07) {
          _state = _State.ground;
        } else if (rune == 0x1b) {
          _state = _State.stringEscape;
        }
      case _State.stringEscape:
        // ESC \ ends the string; anything else is malformed: drop it too.
        _state = _State.ground;
    }
  }

  void _onCsi(String params, String finalByte) {
    if (isTopRunning) return;
    switch ((params, finalByte)) {
      case (_, 'A'):
        _recall(-1);
      case (_, 'B'):
        _recall(1);
      case (_, 'C'):
        if (_cursor < _line.length) {
          _cursor++;
          _redraw();
        }
      case (_, 'D'):
        if (_cursor > 0) {
          _cursor--;
          _redraw();
        }
      case (_, 'H') || ('1' || '7', '~'):
        _cursor = 0;
        _redraw();
      case (_, 'F') || ('4' || '8', '~'):
        _cursor = _line.length;
        _redraw();
      case ('3', '~'):
        if (_cursor < _line.length) {
          _line.removeAt(_cursor);
          _redraw();
        }
      default:
      // Replies, focus and mouse reports, paste brackets: nothing to do.
    }
  }

  void _onChar(int rune) {
    final wasCr = _lastWasCr;
    _lastWasCr = rune == 0x0d;
    if (isTopRunning) {
      if (rune == 0x71 || rune == 0x51 || rune == 0x03) _stopTop(); // q Q ^C
      return;
    }
    switch (rune) {
      case 0x0d:
        _enter();
      case 0x0a:
        // CRLF from a paste is one Enter.
        if (!wasCr) _enter();
      case 0x7f || 0x08:
        if (_cursor > 0) {
          _line.removeAt(--_cursor);
          _redraw();
        }
      case 0x03: // Ctrl+C
        _emit('^C\r\n');
        _prompt();
      case 0x04: // Ctrl+D
        if (_line.isEmpty) {
          _exitShell(0);
        } else if (_cursor < _line.length) {
          _line.removeAt(_cursor);
          _redraw();
        }
      case 0x01: // Ctrl+A
        _cursor = 0;
        _redraw();
      case 0x05: // Ctrl+E
        _cursor = _line.length;
        _redraw();
      case 0x15: // Ctrl+U
        _line.removeRange(0, _cursor);
        _cursor = 0;
        _redraw();
      case 0x0c: // Ctrl+L
        _emit('${csi}H${csi}2J');
        _redraw();
      case 0x09:
        _complete();
      default:
        if (rune < 0x20) return;
        _line.insert(_cursor++, rune);
        if (_cursor == _line.length) {
          _emit(String.fromCharCode(rune));
        } else {
          _redraw();
        }
    }
  }

  /// Rewrites the prompt and the line, then puts the cursor back.
  void _redraw() {
    final after = _columns(_line.skip(_cursor));
    _emit(
      '\r$_promptText${String.fromCharCodes(_line)}${csi}K'
      '${after > 0 ? '$csi${after}D' : ''}',
    );
  }

  void _recall(int delta) {
    final index = _historyIndex + delta;
    if (index < 0 || index > _history.length) return;
    _historyIndex = index;
    _line
      ..clear()
      ..addAll(index == _history.length ? const [] : _history[index].runes);
    _cursor = _line.length;
    _redraw();
  }

  void _complete() {
    if (_cursor != _line.length) return;
    final text = String.fromCharCodes(_line);
    final start = text.lastIndexOf(' ') + 1;
    final word = text.substring(start);
    final slash = word.lastIndexOf('/');
    final dirPart = slash < 0 ? '' : word.substring(0, slash + 1);
    final prefix = word.substring(slash + 1);
    final dir = _fs.lookup(
      _fs.resolve(dirPart.isEmpty ? '.' : dirPart, cwd: _cwd),
    );
    if (dir is! FakeDirectory) return;
    final matches = dir.children.keys.where((n) => n.startsWith(prefix));
    if (matches.length != 1) return;
    final name = matches.single;
    final suffix =
        name.substring(prefix.length) +
        (dir.children[name] is FakeDirectory ? '/' : ' ');
    _line.addAll(suffix.runes);
    _cursor = _line.length;
    _emit(suffix);
  }

  void _enter() {
    final command = String.fromCharCodes(_line).trim();
    _emit('\r\n');
    if (command.isNotEmpty && (_history.isEmpty || _history.last != command)) {
      _history.add(command);
    }
    if (command.isNotEmpty) _run(command);
    if (!_closed && !isTopRunning) _prompt();
  }

  // ------------------------------------------------------------- commands

  void _println([String text = '']) =>
      _emit('${text.replaceAll('\n', '\r\n')}\r\n');

  void _run(String command) {
    final args = _split(command);
    final name = args.removeAt(0);
    switch (name) {
      case 'help':
        _println(
          'Commands: help, echo, ls [-l] [path], cd [path], pwd, cat <file>,\n'
          'clear, colors, top, title <text>, uname, whoami, exit.\n'
          'Keys: arrows, Home/End, Ctrl+A/E/U/L/C/D, Tab completes names.',
        );
      case 'echo':
        _println(args.join(' '));
      case 'pwd':
        _println(_cwd);
      case 'cd':
        final target = _fs.resolve(args.isEmpty ? '~' : args.first, cwd: _cwd);
        if (_fs.lookup(target) is FakeDirectory) {
          _cwd = target;
        } else {
          _println('cd: no such directory: ${args.first}');
        }
      case 'ls':
        _ls(args);
      case 'cat':
        if (args.isEmpty) {
          _println('cat: missing file name');
        }
        for (final arg in args) {
          final node = _fs.lookup(_fs.resolve(arg, cwd: _cwd));
          switch (node) {
            case FakeFile(:final content):
              _emit(content.replaceAll('\n', '\r\n'));
            case FakeDirectory():
              _println('cat: $arg: is a directory');
            case null:
              _println('cat: $arg: no such file');
          }
        }
      case 'clear':
        _emit('${csi}H${csi}2J${csi}3J');
      case 'colors':
        _emit(colorsChart());
      case 'top':
        _startTop();
      case 'title':
        _emit('\x1b]0;${args.join(' ')}\x07');
      case 'uname':
        _println(
          args.contains('-a')
              ? 'FakeOS ghostty 1.0.0 dart ghostty_dart'
              : 'FakeOS',
        );
      case 'whoami':
        _println('demo');
      case 'exit':
        _exitShell(int.tryParse(args.firstOrNull ?? '') ?? 0);
      default:
        _println('fake-sh: command not found: $name');
    }
  }

  void _ls(List<String> args) {
    final long = args.remove('-l');
    final path = _fs.resolve(args.firstOrNull ?? '.', cwd: _cwd);
    final node = _fs.lookup(path);
    switch (node) {
      case null:
        _println('ls: ${args.first}: no such file or directory');
      case FakeFile():
        _println(args.first);
      case FakeDirectory(:final children):
        final names = children.keys.toList()..sort();
        String styled(String name) => switch (children[name]) {
          FakeDirectory() => '${csi}1;34m$name$reset',
          FakeFile(executable: true) => '${csi}1;32m$name$reset',
          _ => name,
        };
        if (long) {
          for (final name in names) {
            final child = children[name]!;
            final (mode, size) = switch (child) {
              FakeDirectory() => ('drwxr-xr-x', 4096),
              FakeFile(:final content, :final executable) => (
                executable ? '-rwxr-xr-x' : '-rw-r--r--',
                utf8.encode(content).length,
              ),
            };
            _println(
              '$mode demo demo ${size.toString().padLeft(5)} ${styled(name)}',
            );
          }
        } else if (names.isNotEmpty) {
          _println(names.map(styled).join('  '));
        }
    }
  }

  void _startTop() {
    _topTick = 0;
    _emit('$csi?1049h$csi?25l');
    _drawTop();
    _topTimer = _periodic(topInterval, (_) {
      _topTick++;
      _drawTop();
    });
  }

  void _drawTop() => _emit(topFrame(cols: _cols, rows: _rows, tick: _topTick));

  void _stopTop() {
    _topTimer?.cancel();
    _topTimer = null;
    _emit('$csi?25h$csi?1049l');
    _prompt();
  }

  void _exitShell(int code) {
    _emit('logout\r\n');
    dispose();
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

enum _State { ground, escape, csi, ss3, string, stringEscape }

/// Splits a command line on spaces, keeping "double quoted" words whole.
List<String> _split(String line) {
  final words = <String>[];
  final word = StringBuffer();
  var quoted = false;
  var any = false;
  for (final char in line.split('')) {
    if (char == '"') {
      quoted = !quoted;
      any = true;
    } else if (char == ' ' && !quoted) {
      if (any) words.add(word.toString());
      word.clear();
      any = false;
    } else {
      word.write(char);
      any = true;
    }
  }
  if (any) words.add(word.toString());
  return words;
}

/// The terminal columns [runes] take: 0 for combining marks and joiners,
/// 2 for East Asian wide characters and emoji, 1 otherwise. An
/// approximation that is good enough to move the cursor over a command line.
int _columns(Iterable<int> runes) {
  var columns = 0;
  for (final r in runes) {
    if ((r >= 0x300 && r <= 0x36f) ||
        r == 0x200d ||
        (r >= 0xfe00 && r <= 0xfe0f) ||
        (r >= 0x1f3fb && r <= 0x1f3ff)) {
      continue;
    }
    final wide =
        (r >= 0x1100 && r <= 0x115f) ||
        (r >= 0x2e80 && r <= 0xa4cf) ||
        (r >= 0xac00 && r <= 0xd7a3) ||
        (r >= 0xf900 && r <= 0xfaff) ||
        (r >= 0xfe30 && r <= 0xfe4f) ||
        (r >= 0xff00 && r <= 0xff60) ||
        (r >= 0xffe0 && r <= 0xffe6) ||
        (r >= 0x1f300 && r <= 0x1faff) ||
        (r >= 0x20000 && r <= 0x3fffd);
    columns += wide ? 2 : 1;
  }
  return columns;
}

/// Adapts a callback to the [Sink] a chunked UTF-8 decoder writes to.
final class _CallbackSink implements Sink<String> {
  _CallbackSink(this._onData);

  final void Function(String) _onData;

  @override
  void add(String data) {
    if (data.isNotEmpty) _onData(data);
  }

  @override
  void close() {}
}
