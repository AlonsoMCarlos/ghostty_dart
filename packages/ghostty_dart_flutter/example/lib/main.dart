// A minimal, self-contained ghostty_dart_flutter app: a terminal view whose
// "program" is a tiny local echo written in Dart, so it runs without a pty.
//
// In a real app, connect the controller to a pty (flutter_pty), a socket or
// an SSH channel instead: write the program's output with `writeBytes` and
// send `onOutput` to the program's input. The demo app in the repository
// (apps/demo) does that with flutter_pty.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

void main() => runApp(const EchoApp());

/// An app with one terminal that echoes each line typed into it.
class EchoApp extends StatefulWidget {
  /// Creates the app.
  const EchoApp({super.key});

  @override
  State<EchoApp> createState() => _EchoAppState();
}

class _EchoAppState extends State<EchoApp> {
  late final VtTerminalController _controller;
  final _echo = LocalEcho();

  @override
  void initState() {
    super.initState();
    // onOutput receives what the terminal sends to its program: typed text,
    // encoded keys, pastes and replies to queries. Here the "program" is
    // LocalEcho, and its answer goes straight back into the terminal.
    _controller = VtTerminalController(
      onOutput: (bytes) => _controller.write(_echo.input(bytes)),
    );
    _controller.write(
      '\x1b[1mghostty_dart_flutter\x1b[0m local echo. '
      'Type a line and press Enter.\r\n${LocalEcho.prompt}',
    );
  }

  @override
  void dispose() {
    // The view never disposes its controller: the app owns it.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ghostty_dart_flutter example',
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: VtTerminalView(
            controller: _controller,
            autofocus: true,
            padding: const EdgeInsets.all(8),
          ),
        ),
      ),
    );
  }
}

/// A line editor that stands in for a shell: it echoes printable text,
/// handles Backspace and Enter, and ignores escape sequences (arrow keys,
/// focus reports, replies to queries).
class LocalEcho {
  /// The prompt printed before every line.
  static const prompt = '\x1b[32m>\x1b[0m ';

  final _line = StringBuffer();

  // Where we are in an escape sequence: 0 none, 1 after ESC, 2 inside a
  // CSI (ESC [), 3 after SS3 (ESC O).
  var _escape = 0;

  // A chunked decoder keeps a character split across two calls whole,
  // which matters when the bytes come from a pty or a socket.
  final _decoded = StringBuffer();
  late final _decoder = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(StringConversionSink.fromStringSink(_decoded));

  /// The bytes the terminal should show in answer to [bytes] from it.
  String input(Uint8List bytes) {
    _decoder.add(bytes);
    final text = _decoded.toString();
    _decoded.clear();
    final out = StringBuffer();
    for (final rune in text.runes) {
      switch (_escape) {
        case 1:
          _escape = rune == 0x5b ? 2 : (rune == 0x4f ? 3 : 0);
          continue;
        case 2:
          // A CSI ends with a final byte in 0x40-0x7E.
          if (rune >= 0x40 && rune <= 0x7e) _escape = 0;
          continue;
        case 3:
          _escape = 0;
          continue;
      }
      switch (rune) {
        case 0x1b:
          _escape = 1;
        case 0x0d: // Enter
          final line = _line.toString();
          _line.clear();
          out.write('\r\n');
          if (line.isNotEmpty) out.write('you typed: $line\r\n');
          out.write(prompt);
        case 0x7f || 0x08: // Backspace
          if (_line.isNotEmpty) {
            final runes = _line.toString().runes.toList()..removeLast();
            _line
              ..clear()
              ..write(String.fromCharCodes(runes));
            out.write('\b \b');
          }
        default:
          if (rune >= 0x20) {
            _line.writeCharCode(rune);
            out.writeCharCode(rune);
          }
      }
    }
    return out.toString();
  }
}
