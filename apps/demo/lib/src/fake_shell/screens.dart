/// Full-screen outputs of the fake shell: the `colors` chart and the frames
/// of the `top`-like monitor. Pure functions, so tests can check them.
library;

import 'dart:math';

const _esc = '\x1b';

/// Control Sequence Introducer.
const csi = '$_esc[';

/// SGR reset.
const reset = '${csi}0m';

/// The `colors` command: the 16 ANSI colours, the 256-colour palette,
/// a truecolor gradient, text attributes (every underline style included)
/// and wide characters, as lines ending in CRLF.
String colorsChart() {
  final out = StringBuffer();
  void line([String text = '']) => out.write('$text$reset\r\n');

  line('${csi}1mANSI 16 colours$reset (SGR 30–37, 90–97, 40–47, 100–107)');
  for (final bright in [false, true]) {
    final row = StringBuffer();
    for (var i = 0; i < 8; i++) {
      final bg = bright ? 100 + i : 40 + i;
      // White text on black, black text on every other colour.
      final fg = i == 0 && !bright ? 97 : 30;
      row.write('$csi$fg;${bg}m ${bright ? 'br' : '  '}$i $reset ');
    }
    line(row.toString());
  }
  line();

  line('${csi}1m256 colours$reset (SGR 48;5;n)');
  for (var block = 0; block < 6; block++) {
    final row = StringBuffer();
    for (var i = 0; i < 36; i++) {
      row.write('${csi}48;5;${16 + block * 36 + i}m  ');
    }
    line(row.toString());
  }
  final grey = StringBuffer();
  for (var i = 232; i < 256; i++) {
    grey.write('${csi}48;5;${i}m   ');
  }
  line(grey.toString());
  line();

  line('${csi}1mTruecolor$reset (SGR 48;2;r;g;b)');
  final gradient = StringBuffer();
  const steps = 72;
  for (var i = 0; i < steps; i++) {
    final (r, g, b) = _hue(i / steps);
    gradient.write('${csi}48;2;$r;$g;${b}m ');
  }
  line(gradient.toString());
  line();

  line('${csi}1mAttributes$reset');
  line(
    '${csi}1mbold$reset  ${csi}2mdim$reset  ${csi}3mitalic$reset  '
    '${csi}7minverse$reset  ${csi}9mstrikethrough$reset  '
    '${csi}53moverline$reset  ${csi}5mblink$reset',
  );
  line(
    '${csi}4msingle$reset  ${csi}4:2mdouble$reset  ${csi}4:3mcurly$reset  '
    '${csi}4:4mdotted$reset  ${csi}4:5mdashed$reset  '
    '${csi}4:3;58;2;255;80;80mred curly$reset',
  );
  line();
  line(
    '${csi}1mUnicode$reset  漢字 かな 한국어  🙂 👍🏽 👨‍👩‍👧 🇪🇸  é ñ  ─│┌┐└┘ ░▒▓█',
  );
  return out.toString();
}

(int, int, int) _hue(double h) {
  final x = (1 - ((h * 6) % 2 - 1).abs());
  final (r, g, b) = switch ((h * 6).floor() % 6) {
    0 => (1.0, x, 0.0),
    1 => (x, 1.0, 0.0),
    2 => (0.0, 1.0, x),
    3 => (0.0, x, 1.0),
    4 => (x, 0.0, 1.0),
    _ => (1.0, 0.0, x),
  };
  return ((r * 255).round(), (g * 255).round(), (b * 255).round());
}

/// One line of a `top` frame: styled ASCII segments clipped to a width.
final class _Line {
  final _out = StringBuffer();
  var _visible = 0;

  void add(String text, [String sgr = '']) {
    if (sgr.isNotEmpty) _out.write('$csi${sgr}m');
    _out.write(text);
    if (sgr.isNotEmpty) _out.write(reset);
    _visible += text.length;
  }

  /// The line clipped or padded to [cols] columns, erasing the rest.
  String render(int cols, {String fill = ''}) {
    final text = _out.toString();
    if (_visible <= cols) {
      final pad = ' ' * (cols - _visible);
      return fill.isEmpty ? '$text${csi}K' : '$text$csi${fill}m$pad$reset';
    }
    // Clip by visible characters, keeping escape sequences intact.
    final clipped = StringBuffer();
    var seen = 0;
    var i = 0;
    while (i < text.length && seen < cols) {
      if (text.startsWith(csi, i)) {
        final end = text.indexOf('m', i);
        clipped.write(text.substring(i, end + 1));
        i = end + 1;
      } else {
        clipped.write(text[i]);
        seen++;
        i++;
      }
    }
    return '$clipped$reset';
  }
}

/// Fake processes of the `top` screen.
const _commands = [
  'flutter',
  'dart',
  'ghostty',
  'zsh',
  'nvim',
  'cargo',
  'node',
  'python3',
  'htop',
  'sshd',
  'systemd',
  'Xorg',
  'pipewire',
  'chrome',
  'code',
  'kworker/0:1',
];

/// One frame of the `top` screen for a [cols] × [rows] terminal at
/// [tick] (the number of refreshes so far). The same arguments always give
/// the same bytes.
///
/// The frame is wrapped in synchronized output (DEC mode 2026), so the
/// terminal shows it whole, homes the cursor, and redraws every row (EL /
/// ED clear what is left of the previous frame).
String topFrame({required int cols, required int rows, required int tick}) {
  final random = Random(tick);
  final lines = <String>[];
  void add(_Line line, {String fill = ''}) =>
      lines.add(line.render(cols, fill: fill));

  final load = [for (var i = 0; i < 3; i++) random.nextDouble() * 4];
  add(
    _Line()
      ..add('top', '1')
      ..add(
        ' - fake  up ${tick ~/ 2}s,  load average: '
        '${load.map((l) => l.toStringAsFixed(2)).join(', ')}',
      ),
  );
  add(
    _Line()..add(
      'Tasks: ${_commands.length} total, ${1 + random.nextInt(3)} running',
    ),
  );

  final cpus = cols >= 100 ? 8 : 4;
  final meterWidth = max(10, min(60, cols - 20));
  for (var cpu = 0; cpu < cpus; cpu++) {
    final usage = random.nextDouble();
    final filled = (usage * meterWidth).round();
    add(
      _Line()
        ..add('cpu${cpu.toString().padRight(2)}[')
        ..add('|' * filled, usage > 0.8 ? '31' : (usage > 0.5 ? '33' : '32'))
        ..add(' ' * (meterWidth - filled))
        ..add('] ${(usage * 100).toStringAsFixed(1).padLeft(5)}%'),
    );
  }
  final mem = 0.3 + random.nextDouble() * 0.4;
  final memFilled = (mem * meterWidth).round();
  add(
    _Line()
      ..add('Mem  [')
      ..add('|' * memFilled, '36')
      ..add(' ' * (meterWidth - memFilled))
      ..add('] ${(mem * 16).toStringAsFixed(1)}G/16.0G'),
  );
  add(_Line());
  add(_Line()..add('  PID USER      %CPU %MEM  COMMAND', '30;42'), fill: '42');

  final processes = [
    for (var i = 0; i < _commands.length; i++)
      (
        pid: 100 + i * 37,
        cpu: random.nextDouble() * 100 / (i + 1),
        mem: random.nextDouble() * 5,
        command: _commands[i],
      ),
  ]..sort((a, b) => b.cpu.compareTo(a.cpu));

  final tableRows = max(0, rows - lines.length - 1);
  for (var i = 0; i < tableRows; i++) {
    if (i >= processes.length) {
      add(_Line());
      continue;
    }
    final p = processes[i];
    add(
      _Line()
        ..add(p.pid.toString().padLeft(5))
        ..add(' demo     ')
        ..add(p.cpu.toStringAsFixed(1).padLeft(5), p.cpu > 50 ? '1;31' : '')
        ..add(p.mem.toStringAsFixed(1).padLeft(5))
        ..add('  ${p.command}', p.command == 'ghostty' ? '1;35' : ''),
    );
  }
  final footer =
      (_Line()
            ..add(' q: quit ', '30;46')
            ..add(' refreshes every 0.5 s'))
          .render(cols);

  final frame = StringBuffer('$csi?2026h${csi}H');
  // The footer stays on the last row; tiny terminals lose the rest.
  frame.write([...lines.take(rows - 1), footer].join('\r\n'));
  frame.write('${csi}J$csi?2026l');
  return frame.toString();
}
