/// Pure Dart value types passed to and returned from the terminal effect
/// callbacks of `VtTerminalEffects`.
///
/// Every type here is a copy: nothing borrows native memory, so values may
/// be kept after the callback returns.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../core/enum_codec.dart';
import '../core/list_equality.dart';
import '../parsers/osc_command.dart';
import 'paste.dart';

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

/// One MIME representation of some clipboard contents
/// (`GhosttyClipboardContent`), e.g. `text/plain` or `image/png`.
///
/// [data] is binary-safe and already decoded from any protocol encoding
/// (OSC 52 base64, ...). An empty [data] is an explicit empty
/// representation, not "clear the clipboard".
final class ClipboardContent {
  /// Creates a representation of [data] with the MIME type [mimeType].
  const ClipboardContent(this.mimeType, this.data);

  /// Creates a text representation of [text], encoded as UTF-8.
  ClipboardContent.text(String text, {String mimeType = 'text/plain'})
    : this(mimeType, utf8.encode(text));

  /// The MIME type, e.g. `text/plain`.
  final String mimeType;

  /// The representation's bytes.
  final Uint8List data;

  /// [data] decoded as UTF-8 (malformed sequences become U+FFFD).
  String get text => utf8.decode(data, allowMalformed: true);

  @override
  bool operator ==(Object other) =>
      other is ClipboardContent &&
      other.mimeType == mimeType &&
      listEquals(other.data, data);

  @override
  int get hashCode => Object.hash(mimeType, Object.hashAll(data));

  @override
  String toString() => 'ClipboardContent($mimeType, ${data.length} bytes)';
}

/// A running program's request to write the clipboard
/// (`GhosttyClipboardWrite`), from OSC 52, iTerm2 OSC 1337 `Copy` or the
/// Kitty clipboard protocol (OSC 5522).
///
/// Delivered to `VtTerminalEffects.onClipboardWrite`, which answers with a
/// [ClipboardWriteReply].
final class ClipboardWriteRequest {
  /// Creates a request; the terminal creates these for the callback.
  const ClipboardWriteRequest({
    required this.location,
    required this.contents,
    this.programName = '',
    this.isGranted = false,
    this.canRemember = false,
  });

  /// The clipboard to write.
  final ClipboardLocation location;

  /// Representations of one logical value, to be committed atomically.
  /// Empty means "clear [location]" (see [isClear]).
  final List<ClipboardContent> contents;

  /// Whether the program asks to clear [location] (no [contents]).
  bool get isClear => contents.isEmpty;

  /// The writing program's name for a permission prompt, or `''` when the
  /// protocol carries none.
  final String programName;

  /// Whether the terminal already holds a session grant for this program
  /// (Kitty clipboard passwords): skip any permission prompt.
  final bool isGranted;

  /// Whether the program supplied a session password, so a reply may set
  /// [ClipboardWriteReply.remember].
  final bool canRemember;

  @override
  bool operator ==(Object other) =>
      other is ClipboardWriteRequest &&
      other.location == location &&
      listEquals(other.contents, contents) &&
      other.programName == programName &&
      other.isGranted == isGranted &&
      other.canRemember == canRemember;

  @override
  int get hashCode => Object.hash(
    location,
    Object.hashAll(contents),
    programName,
    isGranted,
    canRemember,
  );

  @override
  String toString() =>
      'ClipboardWriteRequest(${location.name}, $contents, '
      'programName: $programName, isGranted: $isGranted, '
      'canRemember: $canRemember)';
}

/// The outcome of a clipboard write (`GhosttyClipboardWriteResult`).
///
/// Protocols with a write acknowledgement (OSC 5522) report it to the
/// program; OSC 52 and OSC 1337 `Copy` discard it.
enum ClipboardWriteResult {
  /// The write completed.
  success(0),

  /// The write was denied by policy or by the user.
  denied(1),

  /// The destination or a representation is not supported.
  unsupported(2),

  /// The clipboard is temporarily unavailable.
  busy(3),

  /// A representation contains invalid data.
  invalidData(4),

  /// The write failed with an I/O error.
  ioError(5),

  /// A result added by a later libghostty-vt release.
  unknown(null);

  const ClipboardWriteResult(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyClipboardWriteResult` values to
/// [ClipboardWriteResult] and back.
final clipboardWriteResultCodec = RawEnumCodec<ClipboardWriteResult>(
  ClipboardWriteResult.values,
  raw: (result) => result._raw,
  unknown: ClipboardWriteResult.unknown,
);

/// The answer to a [ClipboardWriteRequest] (`GhosttyClipboardWriteReply`).
final class ClipboardWriteReply {
  /// Creates a reply with [result]. [remember] records a session grant for
  /// the program; it is honoured only on [ClipboardWriteResult.success]
  /// when [ClipboardWriteRequest.canRemember] is set.
  const ClipboardWriteReply(this.result, {this.remember = false});

  /// The write completed.
  static const success = ClipboardWriteReply(ClipboardWriteResult.success);

  /// The write was denied. Returning `null` from the callback has the same
  /// effect.
  static const denied = ClipboardWriteReply(ClipboardWriteResult.denied);

  /// The outcome reported to the program. Must not be
  /// [ClipboardWriteResult.unknown].
  final ClipboardWriteResult result;

  /// Whether to remember the decision for later requests of the program.
  final bool remember;

  @override
  bool operator ==(Object other) =>
      other is ClipboardWriteReply &&
      other.result == result &&
      other.remember == remember;

  @override
  int get hashCode => Object.hash(result, remember);

  @override
  String toString() =>
      'ClipboardWriteReply(${result.name}, remember: $remember)';
}

/// A running program's request to read the clipboard
/// (`GhosttyClipboardRead`), from OSC 52 `?` or a Kitty clipboard (OSC 5522)
/// read.
///
/// Delivered to `VtTerminalEffects.onClipboardRead`, which answers with a
/// [ClipboardReadReply]. Answering lets the program read the user's
/// clipboard, so mediate consent.
final class ClipboardReadRequest {
  /// Creates a request; the terminal creates these for the callback.
  const ClipboardReadRequest({
    required this.location,
    required this.mimeTypes,
    this.wantsAvailableTypes = false,
    this.programName = '',
    this.isGranted = false,
    this.canRemember = false,
  });

  /// The clipboard to read.
  final ClipboardLocation location;

  /// The MIME types the program wants, in order of preference. Text-only
  /// protocols (OSC 52) ask for `text/plain`. May be empty when the program
  /// only wants [wantsAvailableTypes].
  final List<String> mimeTypes;

  /// Whether the program also wants the list of MIME types on the
  /// clipboard ([ClipboardReadReply.availableTypes]).
  ///
  /// Kitty serves a request for only this list (no [mimeTypes]) without a
  /// prompt; embedders are expected to do the same.
  final bool wantsAvailableTypes;

  /// The requesting program's name for a permission prompt, or `''` when
  /// the protocol carries none.
  final String programName;

  /// Whether the terminal already holds a session grant for this program
  /// (Kitty clipboard passwords, or a read that follows a user paste): skip
  /// any permission prompt. Always `false` when [mimeTypes] is empty.
  final bool isGranted;

  /// Whether the program supplied a session password, so a reply may set
  /// [ClipboardReadReply.remember].
  final bool canRemember;

  @override
  bool operator ==(Object other) =>
      other is ClipboardReadRequest &&
      other.location == location &&
      listEquals(other.mimeTypes, mimeTypes) &&
      other.wantsAvailableTypes == wantsAvailableTypes &&
      other.programName == programName &&
      other.isGranted == isGranted &&
      other.canRemember == canRemember;

  @override
  int get hashCode => Object.hash(
    location,
    Object.hashAll(mimeTypes),
    wantsAvailableTypes,
    programName,
    isGranted,
    canRemember,
  );

  @override
  String toString() =>
      'ClipboardReadRequest(${location.name}, $mimeTypes, '
      'wantsAvailableTypes: $wantsAvailableTypes, programName: $programName, '
      'isGranted: $isGranted, canRemember: $canRemember)';
}

/// The outcome of a clipboard read (`GhosttyClipboardReadResult`).
enum ClipboardReadResult {
  /// The clipboard was read; the reply carries its contents.
  success(0),

  /// The read was denied by policy or by the user.
  denied(1),

  /// This clipboard cannot be read.
  unsupported(2),

  /// The clipboard is temporarily unavailable.
  busy(3),

  /// Reading failed with an I/O error.
  ioError(4),

  /// A result added by a later libghostty-vt release.
  unknown(null);

  const ClipboardReadResult(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyClipboardReadResult` values to
/// [ClipboardReadResult] and back.
final clipboardReadResultCodec = RawEnumCodec<ClipboardReadResult>(
  ClipboardReadResult.values,
  raw: (result) => result._raw,
  unknown: ClipboardReadResult.unknown,
);

/// The answer to a [ClipboardReadRequest] (`GhosttyClipboardReadReply`).
///
/// On [ClipboardReadResult.success], [contents] should hold one
/// representation per requested MIME type that the clipboard has;
/// unrequested ones are ignored, and OSC 52 uses the first text entry. Any
/// other result answers the program with an empty clipboard (OSC 52) or the
/// matching error status (OSC 5522), and the other fields are ignored.
final class ClipboardReadReply {
  /// Creates a reply.
  ///
  /// [availableTypes] answers [ClipboardReadRequest.wantsAvailableTypes].
  /// [remember] records a session grant for the program; it is honoured
  /// only on success when [ClipboardReadRequest.canRemember] is set.
  const ClipboardReadReply({
    this.result = ClipboardReadResult.success,
    this.contents = const [],
    this.availableTypes = const [],
    this.remember = false,
  });

  /// A successful reply with one text representation of [text].
  ClipboardReadReply.text(
    String text, {
    String mimeType = 'text/plain',
    bool remember = false,
  }) : this(
         contents: [ClipboardContent.text(text, mimeType: mimeType)],
         remember: remember,
       );

  /// The read was denied. Returning `null` from the callback has the same
  /// effect.
  static const denied = ClipboardReadReply(result: ClipboardReadResult.denied);

  /// The outcome reported to the program. Must not be
  /// [ClipboardReadResult.unknown].
  final ClipboardReadResult result;

  /// The clipboard contents, one entry per MIME representation.
  final List<ClipboardContent> contents;

  /// Every MIME type on the clipboard, for
  /// [ClipboardReadRequest.wantsAvailableTypes].
  final List<String> availableTypes;

  /// Whether to remember the decision for later requests of the program.
  final bool remember;

  @override
  bool operator ==(Object other) =>
      other is ClipboardReadReply &&
      other.result == result &&
      listEquals(other.contents, contents) &&
      listEquals(other.availableTypes, availableTypes) &&
      other.remember == remember;

  @override
  int get hashCode => Object.hash(
    result,
    Object.hashAll(contents),
    Object.hashAll(availableTypes),
    remember,
  );

  @override
  String toString() =>
      'ClipboardReadReply(${result.name}, $contents, '
      'availableTypes: $availableTypes, remember: $remember)';
}

// ---------------------------------------------------------------------------
// Notifications, progress and program status
// ---------------------------------------------------------------------------

/// A request to show a desktop notification (OSC 9 or OSC 777,
/// `GhosttyTerminalDesktopNotification`).
///
/// Both strings are untrusted program output.
final class DesktopNotification {
  /// Creates a notification.
  const DesktopNotification({this.title = '', required this.body});

  /// The title, or `''` when the protocol carries none (OSC 9).
  final String title;

  /// The body text.
  final String body;

  @override
  bool operator ==(Object other) =>
      other is DesktopNotification &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  @override
  String toString() => 'DesktopNotification(title: $title, body: $body)';
}

/// The state of a progress report (`GhosttyTerminalProgressState`).
enum ProgressState {
  /// Remove any visible progress indication.
  remove(0),

  /// Show determinate progress ([ProgressReport.progress]).
  set(1),

  /// Show a failed progress state.
  error(2),

  /// Show indeterminate progress.
  indeterminate(3),

  /// Show paused progress.
  pause(4),

  /// A state added by a later libghostty-vt release.
  unknown(null);

  const ProgressState(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyTerminalProgressState` values to [ProgressState]
/// and back.
final progressStateCodec = RawEnumCodec<ProgressState>(
  ProgressState.values,
  raw: (state) => state._raw,
  unknown: ProgressState.unknown,
);

/// A progress report from the running program (OSC 9;4,
/// `GhosttyTerminalProgressReport`), e.g. for a taskbar progress bar.
final class ProgressReport {
  /// Creates a report.
  const ProgressReport(this.state, {this.progress});

  /// What to show.
  final ProgressState state;

  /// The percentage, 0–100, or `null` when the program omitted it.
  final int? progress;

  @override
  bool operator ==(Object other) =>
      other is ProgressReport &&
      other.state == state &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(state, progress);

  @override
  String toString() => 'ProgressReport(${state.name}, progress: $progress)';
}

/// What a program says it is doing in a program status report (OSC 7501,
/// `GhosttyProgramStatusState`).
enum ProgramStatusState {
  /// At rest, waiting for the user's next instruction.
  idle(0),

  /// Running on its own; may carry a [ProgramStatus.progress].
  working(1),

  /// Finished a piece of work whose result is ready for the user.
  done(2),

  /// Cannot continue until the user acts; [ProgramStatus.kind] says what it
  /// needs and [ProgramStatus.message] says why.
  blocked(3),

  /// Failed and stopped.
  error(4),

  /// Not a real state: remove the record with [ProgramStatus.id] and every
  /// record beneath it, or every record when the id is empty.
  clear(5),

  /// A state added by a later libghostty-vt release.
  unknown(null);

  const ProgramStatusState(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyProgramStatusState` values to [ProgramStatusState]
/// and back.
final programStatusStateCodec = RawEnumCodec<ProgramStatusState>(
  ProgramStatusState.values,
  raw: (state) => state._raw,
  unknown: ProgramStatusState.unknown,
);

/// What a blocked program needs from the user (`GhosttyProgramStatusKind`).
enum ProgramStatusKind {
  /// Not said, or the state is not [ProgramStatusState.blocked].
  none(0),

  /// Approval to do something, such as "Apply these changes?".
  permission(1),

  /// An answer the user has to type.
  question(2),

  /// A login, password, token or other credential.
  auth(3),

  /// A kind added by a later libghostty-vt release.
  unknown(null);

  const ProgramStatusKind(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyProgramStatusKind` values to [ProgramStatusKind]
/// and back.
final programStatusKindCodec = RawEnumCodec<ProgramStatusKind>(
  ProgramStatusKind.values,
  raw: (kind) => kind._raw,
  unknown: ProgramStatusKind.unknown,
);

/// A program status report (OSC 7501, `GhosttyTerminalProgramStatus`): a
/// program telling the terminal what it is doing, for builds, deploys and
/// coding agents.
///
/// The terminal keeps no records; the application does. Keep one record
/// per [id] (empty is the root record); a report replaces its record
/// completely. See https://www.superlogical.com/rex/docs/build/program-status
/// for the full rules. [title] and [message] are untrusted text: do not
/// treat them as markup.
final class ProgramStatus {
  /// Creates a report.
  const ProgramStatus({
    required this.state,
    this.kind = ProgramStatusKind.none,
    this.progress,
    this.id = '',
    this.app = '',
    this.title = '',
    this.message = '',
  });

  /// What the program is doing.
  final ProgramStatusState state;

  /// What the program needs; only set for [ProgramStatusState.blocked].
  final ProgramStatusKind kind;

  /// The percentage, 0–100, for [ProgramStatusState.working] and
  /// [ProgramStatusState.blocked]; `null` when indeterminate or for other
  /// states.
  final int? progress;

  /// The record this report is about; `''` for the root record. A `/`
  /// makes one record the child of another (`build/test`).
  final String id;

  /// A stable machine-readable program name (`cargo`, `terraform`), or
  /// `''` (inherit it from the nearest ancestor record).
  final String app;

  /// A short human label for the record, or `''`.
  final String title;

  /// One line of human text about the record, or `''`.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is ProgramStatus &&
      other.state == state &&
      other.kind == kind &&
      other.progress == progress &&
      other.id == id &&
      other.app == app &&
      other.title == title &&
      other.message == message;

  @override
  int get hashCode =>
      Object.hash(state, kind, progress, id, app, title, message);

  @override
  String toString() =>
      'ProgramStatus(${state.name}, kind: ${kind.name}, progress: $progress, '
      'id: $id, app: $app, title: $title, message: $message)';
}

// ---------------------------------------------------------------------------
// Semantic prompts (shell integration)
// ---------------------------------------------------------------------------

/// The step of a command reported by shell integration
/// (`GhosttySemanticPromptKind`, OSC 133 and friends).
enum SemanticPromptKind {
  /// The shell started drawing a prompt ([SemanticPromptEvent.promptKind]).
  promptStart(1),

  /// The prompt is drawn and the user can type a command.
  inputStart(2),

  /// The command started running; what follows is its output.
  outputStart(3),

  /// The command finished.
  commandEnd(4),

  /// A kind added by a later libghostty-vt release.
  unknown(null);

  const SemanticPromptKind(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttySemanticPromptKind` values to [SemanticPromptKind]
/// and back. The never-reported `GHOSTTY_SEMANTIC_PROMPT_INVALID` (0)
/// decodes to [SemanticPromptKind.unknown].
final semanticPromptKindCodec = RawEnumCodec<SemanticPromptKind>(
  SemanticPromptKind.values,
  raw: (kind) => kind._raw,
  unknown: SemanticPromptKind.unknown,
);

/// Which prompt a [SemanticPromptKind.promptStart] starts
/// (`GhosttySemanticPromptPromptKind`).
enum PromptKind {
  /// The main prompt before each command (also used when the shell does
  /// not say).
  primary(0),

  /// A prompt at the right edge of the line (zsh `RPROMPT`).
  right(1),

  /// A prompt starting an extra line of a multi-line command.
  continuation(2),

  /// Another prompt for an extra line of input (bash `PS2`). Most
  /// applications treat it like [continuation].
  secondary(3),

  /// A kind added by a later libghostty-vt release.
  unknown(null);

  const PromptKind(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttySemanticPromptPromptKind` values to [PromptKind]
/// and back.
final promptKindCodec = RawEnumCodec<PromptKind>(
  PromptKind.values,
  raw: (kind) => kind._raw,
  unknown: PromptKind.unknown,
);

/// A shell integration event (`GhosttyTerminalSemanticPrompt`).
///
/// Shells differ in what they report and may skip steps or repeat a
/// prompt start (e.g. redrawing after a resize), so handle each event on
/// its own. The screen is already updated when it is delivered.
final class SemanticPromptEvent {
  /// Creates an event.
  const SemanticPromptEvent(
    this.kind, {
    this.promptKind = PromptKind.primary,
    this.exitCode,
    this.command = '',
    this.error = '',
  });

  /// Which step of the command this is.
  final SemanticPromptKind kind;

  /// Which prompt starts, for [SemanticPromptKind.promptStart];
  /// [PromptKind.primary] otherwise.
  final PromptKind promptKind;

  /// The command's exit code (may be negative), for
  /// [SemanticPromptKind.commandEnd] when the shell reported one; `null`
  /// otherwise.
  final int? exitCode;

  /// The decoded command line, for [SemanticPromptKind.outputStart]; `''`
  /// when the shell sent none.
  final String command;

  /// What went wrong, for [SemanticPromptKind.commandEnd] when the shell
  /// sent it (few do); `''` otherwise.
  final String error;

  @override
  bool operator ==(Object other) =>
      other is SemanticPromptEvent &&
      other.kind == kind &&
      other.promptKind == promptKind &&
      other.exitCode == exitCode &&
      other.command == command &&
      other.error == error;

  @override
  int get hashCode => Object.hash(kind, promptKind, exitCode, command, error);

  @override
  String toString() =>
      'SemanticPromptEvent(${kind.name}, promptKind: ${promptKind.name}, '
      'exitCode: $exitCode, command: $command, error: $error)';
}

// ---------------------------------------------------------------------------
// Window requests and unknown sequences
// ---------------------------------------------------------------------------

/// A program's request to resize the window's text area to a size in cells
/// (`CSI 8 ; rows ; columns t`, `GhosttyTerminalResizeWindowGrid`).
///
/// The terminal is not resized: decide whether to allow it, then resize
/// your window and call `VtTerminal.resize`.
final class ResizeWindowRequest {
  /// Creates a request.
  const ResizeWindowRequest({this.rows, this.columns});

  /// The requested height in rows, or `null` to keep the current height.
  final int? rows;

  /// The requested width in columns, or `null` to keep the current width.
  final int? columns;

  @override
  bool operator ==(Object other) =>
      other is ResizeWindowRequest &&
      other.rows == rows &&
      other.columns == columns;

  @override
  int get hashCode => Object.hash(rows, columns);

  @override
  String toString() => 'ResizeWindowRequest(rows: $rows, columns: $columns)';
}

/// A complete escape sequence that libghostty-vt does not implement
/// (`GhosttyTerminalUnknownSequence`), for custom protocols.
///
/// ```dart
/// switch (sequence) {
///   case UnknownOscSequence(:final text, :final terminator):
///     handleOsc(text, terminator);
///   case UnknownApcSequence(:final content):
///     handleApc(content);
/// }
/// ```
sealed class UnknownSequence {
  /// Creates a sequence with the raw [content] (not copied: pass a list
  /// you no longer modify) and whether it [isTruncated]. Only the
  /// subclasses call it.
  const UnknownSequence(this.content, {this.isTruncated = false});

  /// The bytes between the introducer and the terminator (for OSC, the
  /// number at the start included). May be arbitrary binary data.
  final Uint8List content;

  /// [content] decoded as UTF-8 (malformed sequences become U+FFFD).
  String get text => utf8.decode(content, allowMalformed: true);

  /// Whether [content] holds only the beginning of the sequence: it was
  /// longer than the configured limit, or memory ran out.
  final bool isTruncated;
}

/// An Application Program Command (`ESC _ ... ST`) libghostty-vt does not
/// implement.
final class UnknownApcSequence extends UnknownSequence {
  /// Creates an APC sequence.
  const UnknownApcSequence(super.content, {super.isTruncated});

  @override
  bool operator ==(Object other) =>
      other is UnknownApcSequence &&
      other.isTruncated == isTruncated &&
      listEquals(other.content, content);

  @override
  int get hashCode => Object.hash(isTruncated, Object.hashAll(content));

  @override
  String toString() => 'UnknownApcSequence($text, isTruncated: $isTruncated)';
}

/// An OSC (`ESC ] number ; data ST`) whose number libghostty-vt does not
/// implement. For `ESC ] 7400;status=busy BEL`, [content] is
/// `7400;status=busy` and [terminator] is [OscTerminator.bel].
final class UnknownOscSequence extends UnknownSequence {
  /// Creates an OSC sequence.
  const UnknownOscSequence(
    super.content, {
    super.isTruncated,
    this.terminator = OscTerminator.st,
  });

  /// How the program ended the sequence; end a reply the same way.
  final OscTerminator terminator;

  @override
  bool operator ==(Object other) =>
      other is UnknownOscSequence &&
      other.isTruncated == isTruncated &&
      other.terminator == terminator &&
      listEquals(other.content, content);

  @override
  int get hashCode =>
      Object.hash(isTruncated, terminator, Object.hashAll(content));

  @override
  String toString() =>
      'UnknownOscSequence($text, isTruncated: $isTruncated, '
      'terminator: ${terminator.name})';
}

// ---------------------------------------------------------------------------
// Device attributes
// ---------------------------------------------------------------------------

/// The answers to device attributes queries (`GhosttyDeviceAttributes`):
/// DA1 (`CSI c`), DA2 (`CSI > c`) and DA3 (`CSI = c`).
///
/// The defaults are the library's own answers: a VT220 with ANSI colour,
/// `CSI ? 62 ; 22 c`, `CSI > 1 ; 0 ; 0 c` and `DCS ! | 00000000 ST`.
///
/// ```dart
/// terminal.onDeviceAttributesQuery = () => const DeviceAttributes(
///   features: [DeviceAttributes.featureAnsiColor, DeviceAttributes.featureClipboard],
/// );
/// ```
final class DeviceAttributes {
  /// Creates device attributes. Values are validated when the terminal
  /// answers a query: integers are 0–65535 ([unitId] 0–0xFFFFFFFF) and
  /// [features] has at most [maxFeatures] entries; an invalid value is
  /// reported as an error and the library's defaults are sent instead.
  const DeviceAttributes({
    this.conformanceLevel = conformanceVt220,
    this.features = const [featureAnsiColor],
    this.deviceType = deviceTypeVt220,
    this.firmwareVersion = 0,
    this.romCartridge = 0,
    this.unitId = 0,
  });

  /// The most DA1 feature codes a reply can carry.
  static const maxFeatures = 64;

  /// DA1 conformance level of a VT220 (also VT240, level 2).
  static const conformanceVt220 = 62;

  /// DA1 conformance level of a VT320 (also VT340, level 3).
  static const conformanceVt320 = 63;

  /// DA1 conformance level of a VT420 (level 4).
  static const conformanceVt420 = 64;

  /// DA1 conformance level of a VT510/VT520/VT525 (level 5).
  static const conformanceVt520 = 65;

  /// DA1 feature: 132 columns.
  static const featureColumns132 = 1;

  /// DA1 feature: selective erase.
  static const featureSelectiveErase = 6;

  /// DA1 feature: windowing capability.
  static const featureWindowing = 18;

  /// DA1 feature: horizontal scrolling.
  static const featureHorizontalScrolling = 21;

  /// DA1 feature: ANSI colour.
  static const featureAnsiColor = 22;

  /// DA1 feature: rectangular editing.
  static const featureRectangularEditing = 28;

  /// DA1 feature: clipboard access (OSC 52).
  static const featureClipboard = 52;

  /// DA2 device type of a VT100.
  static const deviceTypeVt100 = 0;

  /// DA2 device type of a VT220.
  static const deviceTypeVt220 = 1;

  /// DA2 device type of a VT420.
  static const deviceTypeVt420 = 41;

  /// DA2 device type of a VT520.
  static const deviceTypeVt520 = 64;

  /// DA1 conformance level (the `Pp` parameter).
  final int conformanceLevel;

  /// DA1 feature codes (the `Ps` parameters), in order.
  final List<int> features;

  /// DA2 terminal type (`Pp`).
  final int deviceType;

  /// DA2 firmware version (`Pv`).
  final int firmwareVersion;

  /// DA2 ROM cartridge registration number (`Pc`), 0 for emulators.
  final int romCartridge;

  /// DA3 unit ID, sent as 8 uppercase hex digits.
  final int unitId;

  @override
  bool operator ==(Object other) =>
      other is DeviceAttributes &&
      other.conformanceLevel == conformanceLevel &&
      listEquals(other.features, features) &&
      other.deviceType == deviceType &&
      other.firmwareVersion == firmwareVersion &&
      other.romCartridge == romCartridge &&
      other.unitId == unitId;

  @override
  int get hashCode => Object.hash(
    conformanceLevel,
    Object.hashAll(features),
    deviceType,
    firmwareVersion,
    romCartridge,
    unitId,
  );

  @override
  String toString() =>
      'DeviceAttributes(conformanceLevel: $conformanceLevel, '
      'features: $features, deviceType: $deviceType, '
      'firmwareVersion: $firmwareVersion, romCartridge: $romCartridge, '
      'unitId: $unitId)';
}
