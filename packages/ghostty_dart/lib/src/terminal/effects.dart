/// Terminal effects: the callbacks a [VtTerminal] calls when a program asks
/// for something the terminal cannot do by itself (answer a query through
/// the pty, ring the bell, change the window title, use the clipboard, ...).
library;

import 'dart:typed_data';

import '../input/reports.dart';
import 'effects_native.dart';
import 'terminal.dart';

export 'effects_types.dart'
    show
        ClipboardContent,
        ClipboardReadReply,
        ClipboardReadRequest,
        ClipboardReadResult,
        ClipboardWriteReply,
        ClipboardWriteRequest,
        ClipboardWriteResult,
        DesktopNotification,
        DeviceAttributes,
        ProgramStatus,
        ProgramStatusKind,
        ProgramStatusState,
        ProgressReport,
        ProgressState,
        PromptKind,
        ResizeWindowRequest,
        SemanticPromptEvent,
        SemanticPromptKind,
        UnknownApcSequence,
        UnknownOscSequence,
        UnknownSequence;

/// Callbacks for what programs running in a [VtTerminal] ask of it.
///
/// Until a callback is set, the terminal ignores that request, and a program
/// that asks a question gets no answer (or the library's default answer,
/// as each member documents). Set [onWritePty] as soon as a real program
/// runs: without it, programs that query the terminal (device attributes,
/// cursor position, colours) wait for a reply that never comes.
///
/// ```dart
/// final terminal = VtTerminal(cols: 80, rows: 24)
///   ..onWritePty = pty.write
///   ..onBell = window.flash
///   ..onTitleChanged = (title) => window.title = title;
/// terminal.write(ptyOutput);
/// ```
///
/// ## When callbacks run
///
/// Callbacks run synchronously, on the calling isolate, inside the call that
/// triggered them: usually [VtTerminal.write], but also [VtTerminal.resize]
/// (in-band size reports, render holds), [VtTerminal.reset] and
/// [VtTerminal.paste] (pty writes). Inside a callback you may:
///
/// - read any terminal state (`title`, `cursorX`, modes, ...);
/// - set options and callbacks, including clearing the running one;
/// - call [VtTerminal.resize] or [VtTerminal.reset];
/// - call [VtTerminal.dispose]: the native free is deferred until the
///   outer call returns, and no further callback runs.
///
/// Calling [VtTerminal.write] (or `writeUntil`, `writeWithStops`) on the
/// same terminal throws [StateError]: the library is not reentrant. Queue
/// the bytes and write them after the outer call returns.
///
/// ## Errors
///
/// An error thrown by a callback must not unwind through native code. It is
/// caught and reported to the [Zone] that was current when the callback was
/// set (as an uncaught error), and the terminal carries on as if the
/// callback had returned its "no answer" value (`null`, `''`, nothing).
///
/// ## Lifetime
///
/// Every value passed to a callback is a Dart copy and may be kept. Each
/// getter returns the callback currently set, or `null`. Callbacks are
/// released when the terminal is disposed; dispose terminals that have
/// callbacks set, because the native trampolines are freed only then.
/// Setting a callback after [VtTerminal.dispose] throws [StateError], as
/// does reading one.
///
/// ## Names
///
/// Each callback is `on` plus its `GHOSTTY_TERMINAL_OPT_*` option name
/// (`OPT_TITLE_CHANGED` → [onTitleChanged]), so the header docs map one to
/// one. `Query` is appended where the bare name would read as a state
/// change rather than a question ([onSizeQuery], [onColorSchemeQuery],
/// [onDeviceAttributesQuery]); [onEnquiry] and [onXtversion] are already
/// named after the query sequence. Callbacks that answer a query return the
/// answer; the clipboard callbacks return a reply; the rest return nothing.
///
/// These are extension members: importing `VtTerminal` with a `show`
/// clause also needs `VtTerminalEffects`.
extension VtTerminalEffects on VtTerminal {
  /// The longest [onEnquiry] answer, in UTF-8 bytes, the library sends.
  static const maxEnquiryBytes = enquiryReplyLimit;

  /// The longest [onXtversion] name, in UTF-8 bytes, the library sends.
  static const maxXtversionBytes = xtversionReplyLimit;

  // -------------------------------------------------------------------------
  // Replies
  // -------------------------------------------------------------------------

  /// Receives the bytes the terminal writes back to the pty: replies to
  /// device status and attributes queries, mode reports, size reports,
  /// [VtTerminal.paste] output, ... (`GHOSTTY_TERMINAL_OPT_WRITE_PTY`).
  ///
  /// Forward them to the program's input in order. `null` (the default)
  /// discards them.
  ///
  /// ```dart
  /// terminal.onWritePty = (bytes) => pty.write(bytes);
  /// terminal.write(utf8.encode('\x1b[6n')); // pty receives ESC [ 1 ; 1 R
  /// ```
  void Function(Uint8List data)? get onWritePty => writePtyEffect.get(this);
  set onWritePty(void Function(Uint8List data)? callback) =>
      writePtyEffect.set(this, callback);

  /// Answers ENQ (0x05) with its result, UTF-8 encoded, as the answerback
  /// message (`GHOSTTY_TERMINAL_OPT_ENQUIRY`).
  ///
  /// `''` sends nothing, as does `null` (the default). An answer longer
  /// than [maxEnquiryBytes] is reported as a [RangeError] and nothing is
  /// sent (the library has a fixed-size reply buffer).
  String Function()? get onEnquiry => enquiryEffect.get(this);
  set onEnquiry(String Function()? callback) =>
      enquiryEffect.set(this, callback);

  /// Answers an XTVERSION query (`CSI > q`) with its result, e.g.
  /// `'myterm 1.0'` (`GHOSTTY_TERMINAL_OPT_XTVERSION`).
  ///
  /// `''` reports the default `libghostty`, as does `null` (the default).
  /// A name longer than [maxXtversionBytes] is reported as a [RangeError]
  /// and the default is reported instead. The reply goes through
  /// [onWritePty].
  String Function()? get onXtversion => xtversionEffect.get(this);
  set onXtversion(String Function()? callback) =>
      xtversionEffect.set(this, callback);

  /// Answers size queries: XTWINOPS `CSI 14/16/18/19 t` and the in-band
  /// size reports of mode 2048 (`GHOSTTY_TERMINAL_OPT_SIZE`).
  ///
  /// Return the current geometry, or `null` to suppress the report. A
  /// value out of range (rows/columns 0–65535, cell sizes 0–0xFFFFFFFF) is
  /// reported as an error and suppresses the report. `null` (the default)
  /// ignores size queries. Replies go through [onWritePty].
  SizeReportSize? Function()? get onSizeQuery => sizeQueryEffect.get(this);
  set onSizeQuery(SizeReportSize? Function()? callback) =>
      sizeQueryEffect.set(this, callback);

  /// Answers a colour scheme query (`CSI ? 996 n`) with
  /// `CSI ? 997 ; 1 n` (dark) or `CSI ? 997 ; 2 n` (light)
  /// (`GHOSTTY_TERMINAL_OPT_COLOR_SCHEME`).
  ///
  /// Return `null` to ignore the query; [VtColorScheme.unknown] is reported
  /// as an error and ignored too. `null` (the default) ignores colour scheme
  /// queries. To tell programs about a later change (mode 2031), send
  /// `encodeColorSchemeReport` yourself.
  VtColorScheme? Function()? get onColorSchemeQuery =>
      colorSchemeQueryEffect.get(this);
  set onColorSchemeQuery(VtColorScheme? Function()? callback) =>
      colorSchemeQueryEffect.set(this, callback);

  /// Answers device attributes queries: DA1 `CSI c`, DA2 `CSI > c` and DA3
  /// `CSI = c` (`GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES`).
  ///
  /// Return the attributes to report, or `null` for the library defaults
  /// (a VT220 with ANSI colour, see [DeviceAttributes]). Invalid values are
  /// reported as an error and the defaults are sent. With `null` (the
  /// default) the library answers with its defaults. Replies go through
  /// [onWritePty].
  DeviceAttributes? Function()? get onDeviceAttributesQuery =>
      deviceAttributesQueryEffect.get(this);
  set onDeviceAttributesQuery(DeviceAttributes? Function()? callback) =>
      deviceAttributesQueryEffect.set(this, callback);

  // -------------------------------------------------------------------------
  // Terminal state
  // -------------------------------------------------------------------------

  /// Called on BEL (0x07) (`GHOSTTY_TERMINAL_OPT_BELL`). `null` (the
  /// default) ignores the bell.
  void Function()? get onBell => bellEffect.get(this);
  set onBell(void Function()? callback) => bellEffect.set(this, callback);

  /// Called with the new title when a program changes it (OSC 0 or OSC 2)
  /// (`GHOSTTY_TERMINAL_OPT_TITLE_CHANGED`).
  ///
  /// Not called when the title is set through [VtTerminal.title] or cleared
  /// by a full reset (see [onReset]). The title is untrusted program output.
  void Function(String title)? get onTitleChanged =>
      titleChangedEffect.get(this);
  set onTitleChanged(void Function(String title)? callback) =>
      titleChangedEffect.set(this, callback);

  /// Called with the new working directory when a program reports it
  /// (OSC 7, OSC 9 `CurrentDir`, OSC 1337 `CurrentDir`)
  /// (`GHOSTTY_TERMINAL_OPT_PWD_CHANGED`).
  ///
  /// The value is stored unparsed: for OSC 7 it is usually a `file://` URI,
  /// for the others a bare path. `''` means the shell cleared it. Not called
  /// for [VtTerminal.pwd] or a full reset (see [onReset]).
  void Function(String pwd)? get onPwdChanged => pwdChangedEffect.get(this);
  set onPwdChanged(void Function(String pwd)? callback) =>
      pwdChangedEffect.set(this, callback);

  /// Called after a program performs a full reset (RIS, `ESC c`)
  /// (`GHOSTTY_TERMINAL_OPT_RESET`).
  ///
  /// The terminal has already reset itself, including the title and working
  /// directory, without calling [onTitleChanged] or [onPwdChanged]: update
  /// what you show for them here. [onProgressReport] and [onProgramStatus]
  /// are called first to clear their state. A soft reset (DECSTR) and
  /// [VtTerminal.reset] do not call this.
  void Function()? get onReset => resetEffect.get(this);
  set onReset(void Function()? callback) => resetEffect.set(this, callback);

  /// Called with `true` when a program asks the terminal to stop updating
  /// the screen (synchronized output, mode 2026) and with `false` when it
  /// may update again (`GHOSTTY_TERMINAL_OPT_RENDER_HOLD`).
  ///
  /// A hold also ends on a full reset or [VtTerminal.resize]. Calls always
  /// come in pairs; changing the mode with [VtTerminal.setMode] calls
  /// nothing. A renderer should skip frames while held, with a timeout.
  void Function(bool held)? get onRenderHold => renderHoldEffect.get(this);
  set onRenderHold(void Function(bool held)? callback) =>
      renderHoldEffect.set(this, callback);

  /// Called when a program asks to resize the window's text area
  /// (`CSI 8 ; rows ; columns t`) (`GHOSTTY_TERMINAL_OPT_RESIZE_WINDOW`).
  ///
  /// The terminal is not resized: decide whether to allow it (consider
  /// making it opt-in), then resize your window and call
  /// [VtTerminal.resize]. Request kinds added by later releases are not
  /// delivered.
  void Function(ResizeWindowRequest request)? get onResizeWindow =>
      resizeWindowEffect.get(this);
  set onResizeWindow(void Function(ResizeWindowRequest request)? callback) =>
      resizeWindowEffect.set(this, callback);

  // -------------------------------------------------------------------------
  // Clipboard
  // -------------------------------------------------------------------------

  /// Handles a program's clipboard write: OSC 52, iTerm2 OSC 1337 `Copy` and
  /// Kitty clipboard (OSC 5522) writes, normalized to
  /// [ClipboardWriteRequest] (`GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE`).
  ///
  /// The VT stream waits while it runs, so a permission prompt must block
  /// until answered. Return a [ClipboardWriteReply]; `null` denies the
  /// write. [ClipboardWriteResult.unknown] is reported as an error and
  /// denies it. `null` (the default) ignores writes (Kitty writes are
  /// refused with ENOSYS).
  ClipboardWriteReply? Function(ClipboardWriteRequest request)?
  get onClipboardWrite => clipboardWriteEffect.get(this);
  set onClipboardWrite(
    ClipboardWriteReply? Function(ClipboardWriteRequest request)? callback,
  ) => clipboardWriteEffect.set(this, callback);

  /// Handles a program's clipboard read: OSC 52 `?` or a Kitty clipboard
  /// (OSC 5522) read (`GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ`).
  ///
  /// Answering lets the program read the user's clipboard, so mediate
  /// consent; the VT stream waits while it runs. Return a
  /// [ClipboardReadReply]; `null` answers with an empty clipboard (OSC 52)
  /// or EPERM (OSC 5522). [ClipboardReadResult.unknown] is reported as an
  /// error and treated like `null`. `null` (the default) ignores OSC 52
  /// reads and refuses OSC 5522 reads.
  ///
  /// Setting it also enables Kitty paste events (mode 5522):
  /// [VtTerminal.paste] then sends a supporting program an event instead of
  /// the text, and the program's follow-up read arrives here with
  /// [ClipboardReadRequest.isGranted] set.
  ClipboardReadReply? Function(ClipboardReadRequest request)?
  get onClipboardRead => clipboardReadEffect.get(this);
  set onClipboardRead(
    ClipboardReadReply? Function(ClipboardReadRequest request)? callback,
  ) => clipboardReadEffect.set(this, callback);

  // -------------------------------------------------------------------------
  // Notifications, progress and shell integration
  // -------------------------------------------------------------------------

  /// Called when a program asks for a desktop notification (OSC 9 or
  /// OSC 777) (`GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION`). `null` (the
  /// default) ignores them.
  void Function(DesktopNotification notification)? get onDesktopNotification =>
      desktopNotificationEffect.get(this);
  set onDesktopNotification(
    void Function(DesktopNotification notification)? callback,
  ) => desktopNotificationEffect.set(this, callback);

  /// Called when a program reports progress (OSC 9;4)
  /// (`GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT`). `null` (the default) ignores
  /// the reports.
  void Function(ProgressReport report)? get onProgressReport =>
      progressReportEffect.get(this);
  set onProgressReport(void Function(ProgressReport report)? callback) =>
      progressReportEffect.set(this, callback);

  /// Called for each valid program status report (OSC 7501)
  /// (`GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS`); see [ProgramStatus] for how
  /// to keep the records.
  ///
  /// While it is set, the terminal also answers the support query
  /// `OSC 7501 ; ?` through [onWritePty]; set that too. A full reset sends
  /// a [ProgramStatusState.clear] report with an empty id, then calls
  /// [onReset]. `null` (the default) drops the reports and leaves the query
  /// unanswered.
  void Function(ProgramStatus status)? get onProgramStatus =>
      programStatusEffect.get(this);
  set onProgramStatus(void Function(ProgramStatus status)? callback) =>
      programStatusEffect.set(this, callback);

  /// Called when the shell reports a step of a command through shell
  /// integration (OSC 133): prompt start, input start, output start, command
  /// end (`GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT`).
  ///
  /// The screen is already updated when it runs; malformed sequences are
  /// not reported. `null` (the default) ignores the events.
  void Function(SemanticPromptEvent event)? get onSemanticPrompt =>
      semanticPromptEffect.get(this);
  set onSemanticPrompt(void Function(SemanticPromptEvent event)? callback) =>
      semanticPromptEffect.set(this, callback);

  /// Called once for each complete OSC or APC sequence libghostty-vt does
  /// not implement, for custom protocols
  /// (`GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE`).
  ///
  /// Nothing is reported until [VtTerminal.setUnknownSequenceMaxBytes] sets
  /// a nonzero limit; longer sequences arrive truncated
  /// ([UnknownSequence.isTruncated]). Cancelled sequences, malformed
  /// sequences of implemented protocols and protocols you turned off are not
  /// reported, nor are sequence kinds added by later releases. A reply you
  /// write to the pty from the callback stays in order with the terminal's
  /// own replies. `null` (the default) stops the reports.
  void Function(UnknownSequence sequence)? get onUnknownSequence =>
      unknownSequenceEffect.get(this);
  set onUnknownSequence(void Function(UnknownSequence sequence)? callback) =>
      unknownSequenceEffect.set(this, callback);
}
