/// The commands the standalone OSC parser recognises (`osc.h`).
///
/// Pure Dart: no `dart:ffi`, so a future web backend can reuse it.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../core/enum_codec.dart';
import '../core/list_equality.dart';

/// The kind of an OSC (Operating System Command) sequence
/// (`GhosttyOscCommandType`).
enum OscCommandType {
  /// OSC 0 / 2: set the window title. Parsed as [OscWindowTitleCommand].
  changeWindowTitle(1),

  /// OSC 1: set the window icon name.
  changeWindowIcon(2),

  /// OSC 133 (and ConEmu OSC 9;12): semantic prompt marks (shell
  /// integration).
  semanticPrompt(3),

  /// OSC 52 (and iTerm2 OSC 1337;Copy): read or write the clipboard.
  clipboardContents(4),

  /// OSC 7 (and ConEmu OSC 9;9): report the working directory.
  reportPwd(5),

  /// OSC 22: set the mouse pointer shape.
  mouseShape(6),

  /// OSC 4, 5, 10–19, 104, 105 and 110–119: query, set or reset colours.
  colorOperation(7),

  /// OSC 21: the Kitty colour protocol.
  kittyColorProtocol(8),

  /// OSC 9 (when not a ConEmu `9;n` form) or OSC 777 `notify`: show a
  /// desktop notification.
  showDesktopNotification(9),

  /// OSC 8 with a URI: start a hyperlink.
  hyperlinkStart(10),

  /// OSC 8 without a URI: end a hyperlink.
  hyperlinkEnd(11),

  /// ConEmu OSC 9;1: sleep.
  conemuSleep(12),

  /// ConEmu OSC 9;2: show a message box.
  conemuShowMessageBox(13),

  /// ConEmu OSC 9;3: change the tab title.
  conemuChangeTabTitle(14),

  /// ConEmu OSC 9;4: progress report.
  conemuProgressReport(15),

  /// ConEmu OSC 9;5: wait for input.
  conemuWaitInput(16),

  /// ConEmu OSC 9;6: GUI macro.
  conemuGuimacro(17),

  /// ConEmu OSC 9;7: run a process.
  conemuRunProcess(18),

  /// ConEmu OSC 9;8: output an environment variable.
  conemuOutputEnvironmentVariable(19),

  /// ConEmu OSC 9;10: xterm emulation.
  conemuXtermEmulation(20),

  /// ConEmu OSC 9;11: comment.
  conemuComment(21),

  /// OSC 66: the Kitty text sizing protocol.
  kittyTextSizing(22),

  /// OSC 5522: the Kitty clipboard protocol.
  kittyClipboardProtocol(23),

  /// OSC 72: the Kitty drag-and-drop protocol.
  kittyDndProtocol(24),

  /// OSC 3008: hierarchical context signalling.
  hierarchicalContext(25),

  /// OSC 99: the Kitty desktop notification protocol.
  kittyDesktopNotification(26),

  /// A sequence whose number the parser does not implement
  /// (`GHOSTTY_OSC_COMMAND_UNKNOWN`). Only produced when the parser keeps
  /// such sequences (`OscParser.unknownMaxBytes` > 0). Parsed as
  /// [OscUnimplementedCommand].
  unimplemented(27),

  /// OSC 7501: a program status report or support query. The standalone
  /// parser only identifies it.
  programStatus(28),

  /// A command type added by a later libghostty-vt release.
  unknown(null);

  const OscCommandType(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyOscCommandType` values to [OscCommandType] and back.
/// `GHOSTTY_OSC_COMMAND_INVALID` (0) is not a command: it decodes to
/// [OscCommandType.unknown], and the parser returns `null` for it instead.
final oscCommandTypeCodec = RawEnumCodec<OscCommandType>(
  OscCommandType.values,
  raw: (type) => type._raw,
  unknown: OscCommandType.unknown,
);

/// How an OSC sequence was ended (`GhosttyOscTerminator`). A reply to the
/// sequence should end the same way: some programs only accept matching
/// replies.
enum OscTerminator {
  /// The string terminator ST, `ESC \` (0x1B 0x5C).
  st(0),

  /// The bell character BEL (0x07).
  bel(1),

  /// A terminator added by a later libghostty-vt release.
  unknown(null);

  const OscTerminator(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyOscTerminator` values to [OscTerminator] and back.
final oscTerminatorCodec = RawEnumCodec<OscTerminator>(
  OscTerminator.values,
  raw: (terminator) => terminator._raw,
  unknown: OscTerminator.unknown,
);

/// A parsed OSC command, as returned by `OscParser.end`.
///
/// libghostty-vt 1.0 exposes the data of the window title and of
/// unimplemented sequences; every other recognised command is an
/// [OscOtherCommand] that carries only its [type].
///
/// ```dart
/// switch (parser.parse(utf8.encode('2;hello'))) {
///   case OscWindowTitleCommand(:final title):
///     window.title = title;
///   case OscUnimplementedCommand(:final content):
///     handleCustom(content);
///   case OscOtherCommand() || null:
///     break;
/// }
/// ```
sealed class OscCommand {
  /// Base constructor for the subclasses.
  const OscCommand();

  /// The kind of command.
  OscCommandType get type;
}

/// OSC 0 or 2: set the window title.
final class OscWindowTitleCommand extends OscCommand {
  /// A command that sets the window title to [title].
  const OscWindowTitleCommand(this.title);

  /// The new title, decoded as UTF-8 (malformed bytes become U+FFFD).
  final String title;

  @override
  OscCommandType get type => OscCommandType.changeWindowTitle;

  @override
  bool operator ==(Object other) =>
      other is OscWindowTitleCommand && other.title == title;

  @override
  int get hashCode => Object.hash(OscWindowTitleCommand, title);

  @override
  String toString() => 'OscWindowTitleCommand($title)';
}

/// An OSC sequence whose number the parser does not implement, kept so the
/// application can implement it itself (see `OscParser.unknownMaxBytes`).
final class OscUnimplementedCommand extends OscCommand {
  /// An unimplemented sequence with raw [content].
  OscUnimplementedCommand({
    required Uint8List content,
    required this.isTruncated,
    required this.terminator,
  }) : content = Uint8List.fromList(content);

  /// Every byte fed to the parser, including the leading number: for
  /// `ESC ] 7400;status=busy BEL` it is `7400;status=busy`. A copy owned
  /// by this object.
  final Uint8List content;

  /// Whether the sequence was longer than `OscParser.unknownMaxBytes` (or
  /// memory ran out), so [content] holds only its beginning.
  final bool isTruncated;

  /// How the sequence was ended. End a reply the same way.
  final OscTerminator terminator;

  /// [content] decoded as UTF-8 (malformed bytes become U+FFFD).
  String get text => utf8.decode(content, allowMalformed: true);

  @override
  OscCommandType get type => OscCommandType.unimplemented;

  @override
  bool operator ==(Object other) =>
      other is OscUnimplementedCommand &&
      other.isTruncated == isTruncated &&
      other.terminator == terminator &&
      listEquals(other.content, content);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(content), isTruncated, terminator);

  @override
  String toString() =>
      'OscUnimplementedCommand($text, truncated: $isTruncated, '
      'terminator: ${terminator.name})';
}

/// A recognised OSC command whose data libghostty-vt 1.0 does not expose to
/// standalone parsers. A terminal handles these itself.
final class OscOtherCommand extends OscCommand {
  /// A command of [type].
  const OscOtherCommand(this.type);

  @override
  final OscCommandType type;

  @override
  bool operator ==(Object other) =>
      other is OscOtherCommand && other.type == type;

  @override
  int get hashCode => Object.hash(OscOtherCommand, type);

  @override
  String toString() => 'OscOtherCommand(${type.name})';
}
