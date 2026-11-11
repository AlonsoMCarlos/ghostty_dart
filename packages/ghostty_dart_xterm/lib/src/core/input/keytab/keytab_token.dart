// Ported from package:xterm 4.0.0 (lib/src/core/input/keytab/keytab_token.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'dart:math' show min;

/// The kinds of token [tokenize] produces.
enum KeytabTokenType {
  /// The `key` keyword.
  keyDefine,

  /// The `keyboard` keyword.
  keyboard,

  /// A Qt key name after `key`.
  keyName,

  /// A mode name after `+` or `-`.
  mode,

  /// `+` or `-` before a mode.
  modeStatus,

  /// The `:` before the action.
  colon,

  /// A quoted string (the action text or the keyboard name), without the
  /// quotes.
  input,

  /// An unquoted action name.
  shortcut,
}

/// One token of a keytab.
class KeytabToken {
  /// Creates a token of [type] with its text [value].
  KeytabToken(this.type, this.value);

  /// The kind of token.
  final KeytabTokenType type;

  /// The token's text.
  final String value;

  @override
  String toString() {
    return '$type<$value>';
  }
}

/// A cursor over one keytab line, used by [tokenize].
class LineReader {
  /// Creates a reader at the start of [line].
  LineReader(this.line);

  /// The line being read.
  final String line;

  var _pos = 0;

  /// Whether the whole line has been read.
  bool get done => _pos > line.length - 1;

  /// Returns the next [count] characters and moves past them, or `null` at
  /// the end of the line.
  String? take([int count = 1]) {
    final result = peek(count);
    _pos += count;
    return result;
  }

  /// Returns the next [count] characters without moving, or `null` at the
  /// end of the line.
  String? peek([int count = 1]) {
    if (done) return null;
    final end = min(_pos + count, line.length);
    final result = line.substring(_pos, end);
    return result;
  }

  /// Moves past spaces and tabs.
  void skipWhitespace() {
    while (peek() == ' ' || peek() == '\t') {
      _pos += 1;
    }
  }

  /// Reads a run of word characters (letters, digits, `_`).
  String readString() {
    final buffer = StringBuffer();
    final pattern = RegExp(r'\w|_');

    while (!done && line[_pos].contains(pattern)) {
      buffer.write(line[_pos]);
      _pos++;
    }

    return buffer.toString();
  }

  /// Reads up to the first character matching [pattern], including it when
  /// [inclusive] is true.
  String readUntil(Pattern pattern, {bool inclusive = false}) {
    final buffer = StringBuffer();

    while (!done && !line[_pos].contains(pattern)) {
      buffer.write(line[_pos]);
      _pos++;
    }

    if (!done && inclusive) {
      buffer.write(line[_pos]);
      _pos++;
    }

    return buffer.toString();
  }
}

/// Thrown by [tokenize] for a malformed `key` or `keyboard` line.
class TokenizeError {}

/// Splits a keytab [source] into tokens. Comments (`#`) and lines that are
/// neither `key` nor `keyboard` lines are skipped.
///
/// Throws [TokenizeError] for a malformed line.
Iterable<KeytabToken> tokenize(String source) sync* {
  final lines = source.split('\n');

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    line = line.replaceFirst(RegExp('#.*'), '');

    if (line == '') {
      continue;
    }

    if (_isKeyboardNameDefine(line)) {
      yield* _parseKeyboardNameDefine(line);
    }

    if (_isKeyDefine(line)) {
      yield* _parseKeyDefine(line);
    }
  }
}

bool _isKeyboardNameDefine(String line) {
  return line.startsWith('keyboard ');
}

bool _isKeyDefine(String line) {
  return line.startsWith('key ');
}

Iterable<KeytabToken> _parseKeyboardNameDefine(String line) sync* {
  final reader = LineReader(line.trim());

  if (reader.readString() == 'keyboard') {
    yield KeytabToken(KeytabTokenType.keyboard, 'keyboard');
  } else {
    throw TokenizeError();
  }

  reader.skipWhitespace();

  yield _readInput(reader);
}

Iterable<KeytabToken> _parseKeyDefine(String line) sync* {
  final reader = LineReader(line.trim());

  if (reader.readString() == 'key') {
    yield KeytabToken(KeytabTokenType.keyDefine, 'key');
  } else {
    throw TokenizeError();
  }

  reader.skipWhitespace();

  final keyName = reader.readString();
  yield KeytabToken(KeytabTokenType.keyName, keyName);

  reader.skipWhitespace();

  while (reader.peek() == '+' || reader.peek() == '-') {
    final modeStatus = reader.take()!;
    yield KeytabToken(KeytabTokenType.modeStatus, modeStatus);
    final mode = reader.readString();
    yield KeytabToken(KeytabTokenType.mode, mode);
    reader.skipWhitespace();
  }

  if (reader.take() == ':') {
    yield KeytabToken(KeytabTokenType.colon, ':');
  } else {
    throw TokenizeError();
  }

  reader.skipWhitespace();

  if (reader.peek() == '"') {
    yield _readInput(reader);
  } else {
    final action = reader.readString();
    yield KeytabToken(KeytabTokenType.shortcut, action);
  }
}

KeytabToken _readInput(LineReader reader) {
  reader.skipWhitespace();

  if (reader.take() != '"') {
    throw TokenizeError();
  }

  final value = reader.readUntil('"');
  reader.take();

  return KeytabToken(KeytabTokenType.input, value);
}
