/// Internal native plumbing for `VtTerminalEffects`: the per-terminal effect
/// state, one `NativeCallable` per callback option, and the conversions
/// between the borrowed C structs and the Dart value types. Not exported.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../input/reports.dart';
import '../parsers/osc_command.dart';
import 'effects_types.dart';
import 'paste.dart';
import 'terminal_native.dart';

typedef _Opt = GhosttyTerminalOption;
typedef _Data = GhosttyTerminalData;
typedef _Ref = WeakReference<TerminalEffects>;
typedef _Create = NativeCallable<Function> Function(_Ref effects);

final _effectsKey = Object();

/// One terminal callback option: its `GHOSTTY_TERMINAL_OPT_*` value, the Dart
/// callback type [F] and the factory of its `NativeCallable`.
final class Effect<F extends Function> {
  const Effect._(this._option, this._create);

  final int _option;
  final _Create _create;

  /// The callback installed on [terminal] (a `VtTerminal`), or `null`.
  ///
  /// Throws [StateError] if the terminal is disposed.
  F? get(Object terminal) {
    final handle = handleOf<GhosttyTerminalImpl>(terminal)..checkNotDisposed();
    return handle.attachment<TerminalEffects>(_effectsKey)?._callback(this);
  }

  /// Installs [callback] on [terminal], or restores the library default
  /// when it is `null`.
  ///
  /// Throws [StateError] if the terminal is disposed.
  void set(Object terminal, F? callback) {
    final handle = handleOf<GhosttyTerminalImpl>(terminal)..checkNotDisposed();
    final effects = handle.attachment<TerminalEffects>(_effectsKey);
    if (effects == null && callback == null) return;
    (effects ?? TerminalEffects._attach(handle))._set(this, callback);
  }
}

/// A Dart callback and the zone it was installed in (errors it throws are
/// reported to that zone).
final class _Slot {
  _Slot(this.callback) : zone = Zone.current;

  final Function callback;
  final Zone zone;
}

/// The effect state of one terminal, stored as an attachment of its
/// [NativeHandle].
///
/// The `NativeCallable` closures reach it only through a [WeakReference]:
/// an open callable is a GC root, and a strong reference would keep a
/// forgotten terminal (and its native memory) alive forever. The state is
/// reachable from the handle alone, so the user callbacks it holds do not
/// outlive the terminal either.
///
/// A callable is created the first time its option gets a callback and is
/// kept, installed or not, until the terminal is disposed. Closing one
/// earlier is unsafe: the option may be cleared from inside that very
/// callback, while the native caller still runs on it. Keeping them costs
/// at most one callable per option, because re-setting an option reuses its
/// callable.
///
/// Callables never keep the isolate alive (`keepIsolateAlive = false`):
/// they only run synchronously inside a call the isolate is making, so an
/// open one has nothing to wait for, and a forgotten terminal must not stop
/// a program from exiting. If the terminal is garbage collected without
/// `dispose()`, [_finalizer] closes them: by then the native terminal is
/// unreachable, so nothing can call them any more.
final class TerminalEffects {
  TerminalEffects._(this._handle);

  /// Creates the state of [handle] and registers its cleanup.
  factory TerminalEffects._attach(NativeHandle<GhosttyTerminalImpl> handle) {
    final effects = TerminalEffects._(handle);
    handle
      ..setAttachment(_effectsKey, effects)
      ..addCleanup(effects._close);
    _finalizer.attach(effects, effects._callables, detach: effects);
    return effects;
  }

  /// Closes the callables of a terminal that was never disposed. The token
  /// is the callable map alone, so it does not keep the state reachable.
  static final _finalizer = Finalizer<Map<int, NativeCallable<Function>>>(
    _closeAll,
  );

  static void _closeAll(Map<int, NativeCallable<Function>> callables) {
    for (final callable in callables.values) {
      callable.close();
    }
    callables.clear();
  }

  final NativeHandle<GhosttyTerminalImpl> _handle;
  late final _Ref _self = WeakReference(this);
  final _slots = <int, _Slot>{};
  final _callables = <int, NativeCallable<Function>>{};

  /// Backs the strings returned by the enquiry and XTVERSION callbacks: the
  /// library reads them after the callback returns, so they cannot live in
  /// a scope-bound scratch block. Valid until the next such callback.
  GrowableNativeBuffer? _replyBuffer;

  F? _callback<F extends Function>(Effect<F> effect) =>
      _slots[effect._option]?.callback as F?;

  void _set<F extends Function>(Effect<F> effect, F? callback) {
    final option = effect._option;
    final installed = _slots.containsKey(option);
    if (callback == null) {
      if (installed) {
        _install(option, nullptr);
        _slots.remove(option);
      }
      return;
    }
    if (!installed) {
      final callable = _callables[option] ??= effect._create(_self)
        ..keepIsolateAlive = false;
      _install(option, callable.nativeFunction.cast());
    }
    _slots[option] = _Slot(callback);
  }

  /// Sets callback [option] to [function] (NULL restores the default).
  /// Setting a callback runs no callback and changes no content, so the
  /// epoch is not bumped.
  void _install(int option, Pointer<Void> function) {
    final raw = _handle.use(
      (terminal) => ghostty_terminal_set(terminal, option, function),
    );
    checkResult(raw, 'ghostty_terminal_set');
  }

  /// Runs [invoke] with the callback of [effect], or returns [fallback]
  /// when there is none or the terminal is disposed.
  ///
  /// An error thrown by the callback (or by converting its result) must not
  /// unwind through the native frames: it is reported to the zone the
  /// callback was installed in, and [fallback] is returned.
  R _dispatch<F extends Function, R>(
    Effect<F> effect,
    R fallback,
    R Function(F callback) invoke,
  ) {
    final slot = _slots[effect._option];
    if (slot == null || _handle.isDisposed) return fallback;
    try {
      return invoke(slot.callback as F);
    } catch (error, stack) {
      slot.zone.handleUncaughtError(error, stack);
      return fallback;
    }
  }

  /// Copies [bytes] into the reply buffer as a `GhosttyString`.
  GhosttyString _replyString(Uint8List bytes) {
    final buffer = _replyBuffer ??= GrowableNativeBuffer(64);
    buffer.ensureCapacity(bytes.length);
    final pointer = buffer.pointer;
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    return Struct.create<GhosttyString>()
      ..ptr = pointer
      ..len = bytes.length;
  }

  void _close() {
    _finalizer.detach(this);
    _closeAll(_callables);
    _slots.clear();
    _replyBuffer?.dispose();
  }
}

/// Runs a `void` callback of [effect] through [_Ref.target].
void _notify<F extends Function>(
  _Ref ref,
  Effect<F> effect,
  void Function(F callback) invoke,
) => ref.target?._dispatch<F, void>(effect, null, invoke);

/// Runs a `bool`-returning callback (`true`: the out-param was filled).
bool _query<F extends Function>(
  _Ref ref,
  Effect<F> effect,
  bool Function(F callback) invoke,
) => ref.target?._dispatch<F, bool>(effect, false, invoke) ?? false;

/// Runs a `GhosttyString`-returning callback; `''` is the zero-length
/// string (no response / the library default).
///
/// The library silently drops answers longer than its fixed reply buffer,
/// so a longer one is reported as a [RangeError] and replaced by `''`.
GhosttyString _answer(
  _Ref ref,
  Effect<String Function()> effect,
  int maxBytes,
) {
  final effects = ref.target;
  if (effects == null) return Struct.create<GhosttyString>();
  final bytes = effects._dispatch(effect, Uint8List(0), (callback) {
    final bytes = utf8.encode(callback());
    RangeError.checkValueInInterval(bytes.length, 0, maxBytes, 'reply bytes');
    return bytes;
  });
  return effects._replyString(bytes);
}

/// The longest ENQ answerback the library sends (`reportEnquiry` copies it
/// into a 256-byte buffer with a NUL terminator).
const enquiryReplyLimit = 255;

/// The longest XTVERSION name the library sends (`reportXtversion` formats
/// `DCS > | name ST` and a NUL into a 288-byte buffer).
const xtversionReplyLimit = 281;

// ---------------------------------------------------------------------------
// Effects (one per callback option)
// ---------------------------------------------------------------------------

/// `GHOSTTY_TERMINAL_OPT_WRITE_PTY`.
const writePtyEffect = Effect<void Function(Uint8List data)>._(
  _Opt.GHOSTTY_TERMINAL_OPT_WRITE_PTY,
  _writePty,
);

/// `GHOSTTY_TERMINAL_OPT_BELL`.
const bellEffect = Effect<void Function()>._(
  _Opt.GHOSTTY_TERMINAL_OPT_BELL,
  _bell,
);

/// `GHOSTTY_TERMINAL_OPT_ENQUIRY`.
const enquiryEffect = Effect<String Function()>._(
  _Opt.GHOSTTY_TERMINAL_OPT_ENQUIRY,
  _enquiry,
);

/// `GHOSTTY_TERMINAL_OPT_XTVERSION`.
const xtversionEffect = Effect<String Function()>._(
  _Opt.GHOSTTY_TERMINAL_OPT_XTVERSION,
  _xtversion,
);

/// `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED`.
const titleChangedEffect = Effect<void Function(String title)>._(
  _Opt.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
  _titleChanged,
);

/// `GHOSTTY_TERMINAL_OPT_PWD_CHANGED`.
const pwdChangedEffect = Effect<void Function(String pwd)>._(
  _Opt.GHOSTTY_TERMINAL_OPT_PWD_CHANGED,
  _pwdChanged,
);

/// `GHOSTTY_TERMINAL_OPT_SIZE`.
const sizeQueryEffect = Effect<SizeReportSize? Function()>._(
  _Opt.GHOSTTY_TERMINAL_OPT_SIZE,
  _size,
);

/// `GHOSTTY_TERMINAL_OPT_COLOR_SCHEME`.
const colorSchemeQueryEffect = Effect<VtColorScheme? Function()>._(
  _Opt.GHOSTTY_TERMINAL_OPT_COLOR_SCHEME,
  _colorScheme,
);

/// `GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES`.
const deviceAttributesQueryEffect = Effect<DeviceAttributes? Function()>._(
  _Opt.GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
  _deviceAttributes,
);

/// `GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE`.
const clipboardWriteEffect =
    Effect<ClipboardWriteReply? Function(ClipboardWriteRequest request)>._(
      _Opt.GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
      _clipboardWrite,
    );

/// `GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ`.
const clipboardReadEffect =
    Effect<ClipboardReadReply? Function(ClipboardReadRequest request)>._(
      _Opt.GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ,
      _clipboardRead,
    );

/// `GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION`.
const desktopNotificationEffect =
    Effect<void Function(DesktopNotification notification)>._(
      _Opt.GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION,
      _desktopNotification,
    );

/// `GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT`.
const progressReportEffect = Effect<void Function(ProgressReport report)>._(
  _Opt.GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT,
  _progressReport,
);

/// `GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS`.
const programStatusEffect = Effect<void Function(ProgramStatus status)>._(
  _Opt.GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,
  _programStatus,
);

/// `GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT`.
const semanticPromptEffect = Effect<void Function(SemanticPromptEvent event)>._(
  _Opt.GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
  _semanticPrompt,
);

/// `GHOSTTY_TERMINAL_OPT_RESET`.
const resetEffect = Effect<void Function()>._(
  _Opt.GHOSTTY_TERMINAL_OPT_RESET,
  _reset,
);

/// `GHOSTTY_TERMINAL_OPT_RESIZE_WINDOW`.
const resizeWindowEffect = Effect<void Function(ResizeWindowRequest request)>._(
  _Opt.GHOSTTY_TERMINAL_OPT_RESIZE_WINDOW,
  _resizeWindow,
);

/// `GHOSTTY_TERMINAL_OPT_RENDER_HOLD`.
const renderHoldEffect = Effect<void Function(bool held)>._(
  _Opt.GHOSTTY_TERMINAL_OPT_RENDER_HOLD,
  _renderHold,
);

/// `GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE`.
const unknownSequenceEffect = Effect<void Function(UnknownSequence sequence)>._(
  _Opt.GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE,
  _unknownSequence,
);

// ---------------------------------------------------------------------------
// NativeCallable factories
// ---------------------------------------------------------------------------

// One factory per option: `NativeCallable.isolateLocal` needs the C function
// type as a compile-time constant type argument, so these cannot share a
// generic helper. Each only adapts the C arguments; dispatch, error
// reporting and the disposed check live in `_notify`, `_query` and
// `_answer`.

NativeCallable<Function> _writePty(_Ref ref) =>
    NativeCallable<GhosttyTerminalWritePtyFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      Pointer<Uint8> data,
      int length,
    ) {
      _notify(ref, writePtyEffect, (callback) {
        callback(copyBytes(data, length));
      });
    });

NativeCallable<Function> _bell(_Ref ref) =>
    NativeCallable<GhosttyTerminalBellFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
    ) {
      _notify(ref, bellEffect, (callback) => callback());
    });

NativeCallable<Function> _enquiry(_Ref ref) =>
    NativeCallable<GhosttyTerminalEnquiryFnFunction>.isolateLocal(
      (GhosttyTerminal _, Pointer<Void> _) =>
          _answer(ref, enquiryEffect, enquiryReplyLimit),
    );

NativeCallable<Function> _xtversion(_Ref ref) =>
    NativeCallable<GhosttyTerminalXtversionFnFunction>.isolateLocal(
      (GhosttyTerminal _, Pointer<Void> _) =>
          _answer(ref, xtversionEffect, xtversionReplyLimit),
    );

NativeCallable<Function> _titleChanged(_Ref ref) =>
    NativeCallable<GhosttyTerminalTitleChangedFnFunction>.isolateLocal((
      GhosttyTerminal terminal,
      Pointer<Void> _,
    ) {
      _notify(ref, titleChangedEffect, (callback) {
        callback(readString(terminal, _Data.GHOSTTY_TERMINAL_DATA_TITLE));
      });
    });

NativeCallable<Function> _pwdChanged(_Ref ref) =>
    NativeCallable<GhosttyTerminalPwdChangedFnFunction>.isolateLocal((
      GhosttyTerminal terminal,
      Pointer<Void> _,
    ) {
      _notify(ref, pwdChangedEffect, (callback) {
        callback(readString(terminal, _Data.GHOSTTY_TERMINAL_DATA_PWD));
      });
    });

NativeCallable<Function> _size(_Ref ref) =>
    NativeCallable<GhosttyTerminalSizeFnFunction>.isolateLocal(
      (
        GhosttyTerminal _,
        Pointer<Void> _,
        Pointer<GhosttySizeReportSize> out,
      ) => _query(ref, sizeQueryEffect, (callback) {
        final size = callback();
        if (size == null) return false;
        _fillSize(size, out.ref);
        return true;
      }),
      exceptionalReturn: false,
    );

NativeCallable<Function> _colorScheme(_Ref ref) =>
    NativeCallable<GhosttyTerminalColorSchemeFnFunction>.isolateLocal(
      (GhosttyTerminal _, Pointer<Void> _, Pointer<UnsignedInt> out) =>
          _query(ref, colorSchemeQueryEffect, (callback) {
            final scheme = callback();
            if (scheme == null) return false;
            out.value = vtColorSchemeCodec.encode(scheme);
            return true;
          }),
      exceptionalReturn: false,
    );

NativeCallable<Function> _deviceAttributes(_Ref ref) =>
    NativeCallable<GhosttyTerminalDeviceAttributesFnFunction>.isolateLocal(
      (
        GhosttyTerminal _,
        Pointer<Void> _,
        Pointer<GhosttyDeviceAttributes> out,
      ) => _query(ref, deviceAttributesQueryEffect, (callback) {
        final attributes = callback();
        if (attributes == null) return false;
        _fillDeviceAttributes(attributes, out.ref);
        return true;
      }),
      exceptionalReturn: false,
    );

NativeCallable<Function> _clipboardWrite(_Ref ref) =>
    NativeCallable<GhosttyTerminalClipboardWriteFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      Pointer<GhosttyClipboardWrite> write,
    ) {
      _notify(ref, clipboardWriteEffect, (callback) {
        final reply = callback(_clipboardWriteFromNative(write.ref));
        if (reply != null) _replyToWrite(write, reply);
      });
    });

NativeCallable<Function> _clipboardRead(_Ref ref) =>
    NativeCallable<GhosttyTerminalClipboardReadFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      Pointer<GhosttyClipboardRead> read,
    ) {
      _notify(ref, clipboardReadEffect, (callback) {
        final reply = callback(_clipboardReadFromNative(read.ref));
        if (reply != null) _replyToRead(read, reply);
      });
    });

NativeCallable<Function> _desktopNotification(_Ref ref) =>
    NativeCallable<GhosttyTerminalDesktopNotificationFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      Pointer<GhosttyTerminalDesktopNotification> notification,
    ) {
      _notify(ref, desktopNotificationEffect, (callback) {
        final n = notification.ref;
        callback(
          DesktopNotification(
            title: readGhosttyString(n.title),
            body: readGhosttyString(n.body),
          ),
        );
      });
    });

NativeCallable<Function> _progressReport(_Ref ref) =>
    NativeCallable<GhosttyTerminalProgressReportFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      Pointer<GhosttyTerminalProgressReport> report,
    ) {
      _notify(ref, progressReportEffect, (callback) {
        final r = report.ref;
        callback(
          ProgressReport(
            progressStateCodec.decode(r.state),
            progress: _percent(r.progress),
          ),
        );
      });
    });

NativeCallable<Function> _programStatus(_Ref ref) =>
    NativeCallable<GhosttyTerminalProgramStatusFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      Pointer<GhosttyTerminalProgramStatus> report,
    ) {
      _notify(ref, programStatusEffect, (callback) {
        final r = report.ref;
        callback(
          ProgramStatus(
            state: programStatusStateCodec.decode(r.state),
            kind: programStatusKindCodec.decode(r.kind),
            progress: _percent(r.progress),
            id: readGhosttyString(r.id),
            app: readGhosttyString(r.app),
            title: readGhosttyString(r.title),
            message: readGhosttyString(r.message),
          ),
        );
      });
    });

NativeCallable<Function> _semanticPrompt(_Ref ref) =>
    NativeCallable<GhosttyTerminalSemanticPromptFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      Pointer<GhosttyTerminalSemanticPrompt> event,
    ) {
      _notify(ref, semanticPromptEffect, (callback) {
        final e = event.ref;
        callback(
          SemanticPromptEvent(
            semanticPromptKindCodec.decode(e.kind),
            promptKind: promptKindCodec.decode(e.prompt_kind),
            exitCode: e.has_exit_code ? e.exit_code : null,
            command: readGhosttyString(e.command),
            error: readGhosttyString(e.error),
          ),
        );
      });
    });

NativeCallable<Function> _reset(_Ref ref) =>
    NativeCallable<GhosttyTerminalResetFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
    ) {
      _notify(ref, resetEffect, (callback) => callback());
    });

NativeCallable<Function> _resizeWindow(_Ref ref) =>
    NativeCallable<GhosttyTerminalResizeWindowFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      Pointer<GhosttyTerminalResizeWindow> request,
    ) {
      final r = request.ref;
      // Later releases may add request kinds this version cannot describe.
      if (r.tag !=
          GhosttyTerminalResizeWindowTag.GHOSTTY_TERMINAL_RESIZE_WINDOW_GRID) {
        return;
      }
      _notify(ref, resizeWindowEffect, (callback) {
        final grid = r.value.grid;
        callback(
          ResizeWindowRequest(
            rows: grid.rows == 0 ? null : grid.rows,
            columns: grid.columns == 0 ? null : grid.columns,
          ),
        );
      });
    });

NativeCallable<Function> _renderHold(_Ref ref) =>
    NativeCallable<GhosttyTerminalRenderHoldFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      bool held,
    ) {
      _notify(ref, renderHoldEffect, (callback) => callback(held));
    });

NativeCallable<Function> _unknownSequence(_Ref ref) =>
    NativeCallable<GhosttyTerminalUnknownSequenceFnFunction>.isolateLocal((
      GhosttyTerminal _,
      Pointer<Void> _,
      Pointer<GhosttyTerminalUnknownSequence> sequence,
    ) {
      final decoded = _unknownSequenceFromNative(sequence.ref);
      if (decoded == null) return;
      _notify(ref, unknownSequenceEffect, (callback) => callback(decoded));
    });

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

/// A C percentage (`int8_t`, -1 when omitted) as `int?`.
int? _percent(int raw) => raw < 0 ? null : raw;

void _fillSize(SizeReportSize size, GhosttySizeReportSize out) {
  RangeError.checkValueInInterval(size.rows, 0, 0xFFFF, 'rows');
  RangeError.checkValueInInterval(size.columns, 0, 0xFFFF, 'columns');
  RangeError.checkValueInInterval(size.cellWidth, 0, 0xFFFFFFFF, 'cellWidth');
  RangeError.checkValueInInterval(size.cellHeight, 0, 0xFFFFFFFF, 'cellHeight');
  out
    ..rows = size.rows
    ..columns = size.columns
    ..cell_width = size.cellWidth
    ..cell_height = size.cellHeight;
}

/// Validates every value before writing any, so a bad value leaves the
/// zeroed struct untouched (the callback then reports the defaults).
void _fillDeviceAttributes(
  DeviceAttributes attributes,
  GhosttyDeviceAttributes out,
) {
  void checkUint16(int value, String name) =>
      RangeError.checkValueInInterval(value, 0, 0xFFFF, name);
  final features = attributes.features;
  RangeError.checkValueInInterval(
    features.length,
    0,
    DeviceAttributes.maxFeatures,
    'features.length',
  );
  checkUint16(attributes.conformanceLevel, 'conformanceLevel');
  for (final feature in features) {
    checkUint16(feature, 'features');
  }
  checkUint16(attributes.deviceType, 'deviceType');
  checkUint16(attributes.firmwareVersion, 'firmwareVersion');
  checkUint16(attributes.romCartridge, 'romCartridge');
  RangeError.checkValueInInterval(attributes.unitId, 0, 0xFFFFFFFF, 'unitId');

  final primary = out.primary
    ..conformance_level = attributes.conformanceLevel
    ..num_features = features.length;
  for (var i = 0; i < features.length; i++) {
    primary.features[i] = features[i];
  }
  out.secondary
    ..device_type = attributes.deviceType
    ..firmware_version = attributes.firmwareVersion
    ..rom_cartridge = attributes.romCartridge;
  out.tertiary.unit_id = attributes.unitId;
}

List<ClipboardContent> _contentsFromNative(
  Pointer<GhosttyClipboardContent> contents,
  int length,
) => List.unmodifiable([
  for (var i = 0; i < length; i++)
    ClipboardContent(
      readGhosttyString(contents[i].mime),
      copyBytes(contents[i].data.ptr, contents[i].data.len),
    ),
]);

ClipboardWriteRequest _clipboardWriteFromNative(GhosttyClipboardWrite write) =>
    ClipboardWriteRequest(
      location: clipboardLocationCodec.decode(write.location),
      contents: _contentsFromNative(write.contents, write.contents_len),
      programName: readGhosttyString(write.name),
      isGranted: write.granted,
      canRemember: write.can_remember,
    );

ClipboardReadRequest _clipboardReadFromNative(GhosttyClipboardRead read) =>
    ClipboardReadRequest(
      location: clipboardLocationCodec.decode(read.location),
      mimeTypes: List.unmodifiable([
        for (var i = 0; i < read.mimes_len; i++)
          readGhosttyString(read.mimes[i]),
      ]),
      wantsAvailableTypes: read.list,
      programName: readGhosttyString(read.name),
      isGranted: read.granted,
      canRemember: read.can_remember,
    );

/// Calls `write->reply` with [reply]. Throws [ArgumentError] (before
/// replying) for [ClipboardWriteResult.unknown].
void _replyToWrite(
  Pointer<GhosttyClipboardWrite> write,
  ClipboardWriteReply reply,
) {
  final result = clipboardWriteResultCodec.encode(reply.result);
  final function = write.ref.reply;
  if (function == nullptr) return;
  withScratch(sizeOf<GhosttyClipboardWriteReply>(), (memory) {
    final native = memory.cast<GhosttyClipboardWriteReply>()
      ..initSized(sizeOf<GhosttyClipboardWriteReply>());
    native.ref
      ..result = result
      ..remember = reply.remember;
    function.asFunction<DartGhosttyClipboardWriteReplyFnFunction>()(
      write,
      native,
    );
  });
}

/// Calls `read->reply` with [reply]. The arrays and strings it points to
/// only need to live for the reply call. Throws [ArgumentError] (before
/// replying) for [ClipboardReadResult.unknown].
void _replyToRead(
  Pointer<GhosttyClipboardRead> read,
  ClipboardReadReply reply,
) {
  final result = clipboardReadResultCodec.encode(reply.result);
  final function = read.ref.reply;
  if (function == nullptr) return;
  using((arena) {
    final contents = reply.contents;
    final types = reply.availableTypes;
    final nativeContents = arena<GhosttyClipboardContent>(
      math.max(contents.length, 1),
    );
    for (var i = 0; i < contents.length; i++) {
      final content = nativeContents[i];
      _stringToNative(arena, utf8.encode(contents[i].mimeType), content.mime);
      _stringToNative(arena, contents[i].data, content.data);
    }
    final nativeTypes = arena<GhosttyString>(math.max(types.length, 1));
    for (var i = 0; i < types.length; i++) {
      _stringToNative(arena, utf8.encode(types[i]), nativeTypes[i]);
    }
    final native = arena<GhosttyClipboardReadReply>()
      ..initSized(sizeOf<GhosttyClipboardReadReply>());
    native.ref
      ..result = result
      ..contents = nativeContents
      ..contents_len = contents.length
      ..available = nativeTypes
      ..available_len = types.length
      ..remember = reply.remember;
    function.asFunction<DartGhosttyClipboardReadReplyFnFunction>()(
      read,
      native,
    );
  });
}

/// Copies [bytes] into [arena] memory referenced by [out]. The pointer is
/// never NULL, even for empty strings.
void _stringToNative(Arena arena, Uint8List bytes, GhosttyString out) {
  final data = arena<Uint8>(math.max(bytes.length, 1));
  data.asTypedList(bytes.length).setAll(0, bytes);
  out
    ..ptr = data
    ..len = bytes.length;
}

/// Decodes a borrowed unknown sequence, or `null` for a tag added by a
/// later release (the header asks callbacks to ignore those).
UnknownSequence? _unknownSequenceFromNative(
  GhosttyTerminalUnknownSequence sequence,
) {
  switch (sequence.tag) {
    case GhosttyTerminalUnknownSequenceTag
        .GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_APC:
      final apc = sequence.value.apc;
      return UnknownApcSequence(
        copyBytes(apc.content.ptr, apc.content.len),
        isTruncated: apc.truncated,
      );
    case GhosttyTerminalUnknownSequenceTag
        .GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC:
      final osc = sequence.value.osc;
      return UnknownOscSequence(
        copyBytes(osc.content.ptr, osc.content.len),
        isTruncated: osc.truncated,
        terminator: oscTerminatorCodec.decode(osc.terminator),
      );
  }
  return null;
}
