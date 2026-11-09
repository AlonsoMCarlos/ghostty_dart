/// Formatting terminal content (`formatter.h`): [TerminalFormatter].
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../selection/selection_native.dart' show checkNotInTerminalCallback;
import '../selection/vt_selection.dart'
    show VtSelection, VtTerminalSelection, selectionToNative;
import '../terminal/terminal.dart' show VtTerminal;
import 'text_format.dart';

/// Turns the content of a terminal's active screen, scrollback included,
/// into plain text, VT sequences or HTML (`GhosttyFormatter`).
///
/// ```dart
/// final formatter = TerminalFormatter(terminal, unwrap: true);
/// final everything = formatter.formatText();
/// final copied = formatter.formatText(selection: terminal.selection);
/// formatter.dispose();
/// ```
///
/// A formatter is a reusable view: each format call reads the terminal as
/// it is at that moment, with the options set at that moment. For the text
/// Ghostty copies to the clipboard, use [TextFormat.plain] with [unwrap]
/// and [trim] both on.
///
/// **Ownership:** a formatter belongs to the terminal given to its
/// constructor and keeps it reachable. Call [dispose] when done; disposing
/// the terminal disposes it first, and a forgotten formatter is freed after
/// it is garbage collected. Members throw [StateError] after [dispose],
/// after the terminal is disposed, and (the format calls) from inside a
/// callback of the terminal.
final class TerminalFormatter implements Finalizable {
  /// A formatter for [terminal] with the given options (see [format],
  /// [unwrap], [trim] and [extras]).
  ///
  /// Throws [ArgumentError] for [TextFormat.unknown], [StateError] if
  /// [terminal] is disposed, [UnsupportedError] if the library was built
  /// without the formatter, and [GhosttyException] if it runs out of
  /// memory or rejects an option.
  TerminalFormatter(
    VtTerminal terminal, {
    TextFormat format = TextFormat.plain,
    bool unwrap = false,
    bool trim = true,
    FormatterExtras extras = FormatterExtras.defaults,
  }) : _terminal = terminal,
       _handle = _create(handleOf<GhosttyTerminalImpl>(terminal)) {
    bindHandle(this, _handle);
    _terminalHandle.addDependent(_handle);
    try {
      if (format != TextFormat.plain) this.format = format;
      if (unwrap) this.unwrap = true;
      if (!trim) this.trim = false;
      if (extras != FormatterExtras.defaults) this.extras = extras;
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  static NativeHandle<GhosttyFormatterImpl> _create(
    NativeHandle<GhosttyTerminalImpl> terminal,
  ) {
    final pointer = createNative<GhosttyFormatterImpl>(
      'ghostty_formatter_terminal_new',
      (out) => ghostty_formatter_terminal_new(nullptr, out, terminal.pointer),
    );
    return NativeHandle(
      pointer,
      typeName: 'TerminalFormatter',
      free: (p) => ghostty_formatter_free(p),
      finalizer: _finalizer,
    );
  }

  /// `ghostty_formatter_free` only releases the formatter's own memory, so
  /// a native finalizer is safe.
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyFormatter)>>(
      ghostty_formatter_free,
    ).cast(),
  );

  /// Strong reference: the terminal must outlive the formatter.
  final VtTerminal _terminal;
  final NativeHandle<GhosttyFormatterImpl> _handle;

  NativeHandle<GhosttyTerminalImpl> get _terminalHandle =>
      handleOf<GhosttyTerminalImpl>(_terminal);

  /// Whether [dispose] has been called (directly or by disposing the
  /// terminal).
  bool get isDisposed => _handle.isDisposed;

  /// The output format; [TextFormat.plain] by default.
  ///
  /// Throws [ArgumentError] when set to [TextFormat.unknown].
  TextFormat get format => textFormatCodec.decode(
    _get(_Opt.emit, sizeOf<UnsignedInt>(), (o) => o.cast<UnsignedInt>().value),
  );

  set format(TextFormat value) {
    final raw = textFormatCodec.encode(value);
    _set(_Opt.emit, sizeOf<UnsignedInt>(), (o) {
      o.cast<UnsignedInt>().value = raw;
    });
  }

  /// Whether lines the terminal soft-wrapped come out as one line, the way
  /// the program wrote them; `false` (one output line per row) by default.
  bool get unwrap =>
      _get(_Opt.unwrap, sizeOf<Bool>(), (o) => o.cast<Bool>().value);

  set unwrap(bool value) => _set(_Opt.unwrap, sizeOf<Bool>(), (o) {
    o.cast<Bool>().value = value;
  });

  /// Whether trailing spaces are removed from lines with other text; `true`
  /// by default.
  ///
  /// Blank lines at the end are always removed, except in [TextFormat.vt]
  /// output with [trim] off, which keeps them so the output fills the same
  /// rows as the screen.
  bool get trim => _get(_Opt.trim, sizeOf<Bool>(), (o) => o.cast<Bool>().value);

  set trim(bool value) => _set(_Opt.trim, sizeOf<Bool>(), (o) {
    o.cast<Bool>().value = value;
  });

  /// The terminal state [TextFormat.vt] output also restores;
  /// [FormatterExtras.defaults] by default. Other formats ignore it.
  ///
  /// Throws [GhosttyException] when set to bits the library does not know.
  FormatterExtras get extras => FormatterExtras.fromValue(
    _get(_Opt.extras, sizeOf<Uint32>(), (o) => o.cast<Uint32>().value),
  );

  set extras(FormatterExtras value) => _set(_Opt.extras, sizeOf<Uint32>(), (o) {
    o.cast<Uint32>().value = value.value;
  });

  /// Formats the whole active screen, or only [selection], as a string.
  ///
  /// Malformed UTF-8 (possible in [TextFormat.vt] output of untrusted
  /// content) becomes U+FFFD; use [formatBytes] for the exact bytes.
  ///
  /// Throws like [formatBytes].
  String formatText({VtSelection? selection}) =>
      utf8.decode(formatBytes(selection: selection), allowMalformed: true);

  /// Formats the whole active screen, or only [selection], as UTF-8 bytes.
  ///
  /// [selection] is typically [VtTerminalSelection.selection] or a search
  /// match; it must be a current selection of this formatter's terminal.
  /// Empty content gives an empty list.
  ///
  /// Throws [ArgumentError] for a selection of another terminal,
  /// [StateError] for a stale selection, after [dispose] or from inside a
  /// callback of the terminal, and [GhosttyException] if the library runs
  /// out of memory.
  Uint8List formatBytes({VtSelection? selection}) {
    final formatter = _handle.pointer;
    final terminal = _terminalHandle;
    checkNotInTerminalCallback(terminal, 'TerminalFormatter.formatBytes');
    _setSelection(formatter, terminal, selection);
    return callAllocating(
      'ghostty_formatter_format_alloc',
      (outPtr, outLength) =>
          ghostty_formatter_format_alloc(formatter, nullptr, outPtr, outLength),
    );
  }

  /// Frees the native formatter. Safe to call more than once.
  void dispose() => _handle.dispose();

  /// Sets (or clears) the formatter's selection right before a format
  /// call. The library keeps an untracked copy that goes stale with the
  /// next terminal change, so it is never left for a later call to use.
  void _setSelection(
    Pointer<GhosttyFormatterImpl> formatter,
    NativeHandle<GhosttyTerminalImpl> terminal,
    VtSelection? selection,
  ) => withScratch(sizeOf<GhosttySelection>(), (block) {
    final native = block.cast<GhosttySelection>();
    if (selection != null) {
      selectionToNative(selection, terminal, native, 'selection');
    }
    checkResult(
      ghostty_formatter_set(
        formatter,
        _Opt.selection,
        selection == null ? nullptr : native.cast(),
      ),
      'ghostty_formatter_set',
    );
  });

  R _get<R>(int option, int size, R Function(Pointer<Uint8> out) decode) {
    final formatter = _handle.pointer;
    return withScratch(size, (out) {
      checkResult(
        ghostty_formatter_get(formatter, option, out.cast()),
        'ghostty_formatter_get',
      );
      return decode(out);
    });
  }

  void _set(int option, int size, void Function(Pointer<Uint8> value) write) {
    final formatter = _handle.pointer;
    withScratch(size, (value) {
      write(value);
      checkResult(
        ghostty_formatter_set(formatter, option, value.cast()),
        'ghostty_formatter_set',
      );
    });
  }
}

/// The `GhosttyFormatterOption` values.
abstract final class _Opt {
  static const emit = GhosttyFormatterOption.GHOSTTY_FORMATTER_OPT_EMIT;
  static const unwrap = GhosttyFormatterOption.GHOSTTY_FORMATTER_OPT_UNWRAP;
  static const trim = GhosttyFormatterOption.GHOSTTY_FORMATTER_OPT_TRIM;
  static const selection =
      GhosttyFormatterOption.GHOSTTY_FORMATTER_OPT_SELECTION;
  static const extras = GhosttyFormatterOption.GHOSTTY_FORMATTER_OPT_EXTRAS;
}
