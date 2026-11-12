// Stand-ins for the parts of flutter_pty 0.4.2 and dartssh2 4.1.0 that
// xterm 4.0.0's examples use, with the same names and signatures (read from
// their sources in the pub cache, 2026-11-11). They let the ported examples
// compile and run unchanged in a widget test, without a pty, a network or a
// new dependency. Each records what the example did with it, and the test
// drives the "program" side.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// --- flutter_pty 0.4.2 (lib/flutter_pty.dart) -------------------------------

/// flutter_pty's `Pty`: a process in a pseudo terminal.
class Pty {
  /// As flutter_pty's `Pty.start`; records itself in [last].
  Pty.start(
    this.executable, {
    this.arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
    this.rows = 25,
    this.columns = 80,
    bool ackRead = false,
  }) {
    last = this;
  }

  /// The most recently started pty.
  static Pty? last;

  /// The program started.
  final String executable;

  /// Its arguments.
  final List<String> arguments;

  /// The pty's current number of rows.
  int rows;

  /// The pty's current number of columns.
  int columns;

  final _output = StreamController<Uint8List>();
  final _exitCode = Completer<int>();
  final _written = BytesBuilder();

  /// What the program prints.
  Stream<Uint8List> get output => _output.stream;

  /// Completes when the program exits.
  Future<int> get exitCode => _exitCode.future;

  /// Sends [data] to the program's input.
  void write(Uint8List data) => _written.add(data);

  /// Resizes the pty (rows first, as flutter_pty does).
  void resize(int rows, int cols) {
    this.rows = rows;
    columns = cols;
  }

  // Test side.

  /// Everything written to the program so far, decoded as UTF-8.
  String get written => utf8.decode(_written.toBytes());

  /// Makes the program print [text].
  void emit(String text) => _output.add(utf8.encode(text));

  /// Makes the program exit with [code].
  void exit(int code) => _exitCode.complete(code);
}

// --- dartssh2 4.1.0 (lib/src/ssh_client.dart, ssh_session.dart, socket/) ----

/// dartssh2's `SSHSocket`.
class SSHSocket {
  SSHSocket._();

  /// As dartssh2's `SSHSocket.connect`; never touches the network.
  static Future<SSHSocket> connect(
    String host,
    int port, {
    Duration? timeout,
  }) async => SSHSocket._();
}

/// dartssh2's `SSHPtyConfig`.
class SSHPtyConfig {
  /// As dartssh2's constructor.
  const SSHPtyConfig({
    this.type = 'xterm-256color',
    this.width = 80,
    this.height = 24,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
  });

  /// The terminal type.
  final String type;

  /// Columns.
  final int width;

  /// Rows.
  final int height;

  /// Width in pixels.
  final int pixelWidth;

  /// Height in pixels.
  final int pixelHeight;
}

/// dartssh2's `SSHClient`.
class SSHClient {
  /// As dartssh2's constructor (the options the example passes).
  SSHClient(
    SSHSocket socket, {
    required this.username,
    FutureOr<String?> Function()? onPasswordRequest,
  }) {
    last = this;
  }

  /// The most recently created client.
  static SSHClient? last;

  /// The user name.
  final String username;

  /// The session opened by [shell].
  SSHSession? session;

  /// As dartssh2's `shell`: opens an interactive session.
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    Map<String, String>? environment,
  }) async => session = SSHSession._(pty);
}

/// dartssh2's `SSHSession`.
class SSHSession {
  SSHSession._(this.pty);

  /// The pty requested by [SSHClient.shell].
  final SSHPtyConfig? pty;

  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _written = BytesBuilder();

  /// The remote program's output.
  Stream<Uint8List> get stdout => _stdout.stream;

  /// The remote program's error output.
  Stream<Uint8List> get stderr => _stderr.stream;

  /// The last size sent by [resizeTerminal]: (width, height, pixelWidth,
  /// pixelHeight).
  (int, int, int, int)? lastResize;

  /// Sends [data] to the remote program.
  void write(Uint8List data) => _written.add(data);

  /// As dartssh2's `resizeTerminal`.
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) => lastResize = (width, height, pixelWidth, pixelHeight);

  // Test side.

  /// Everything written to the remote program so far, decoded as UTF-8.
  String get written => utf8.decode(_written.toBytes());

  /// Makes the remote program print [text] on stdout.
  void emit(String text) => _stdout.add(utf8.encode(text));
}
