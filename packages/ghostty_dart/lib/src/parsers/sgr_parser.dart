/// The standalone SGR parser (`sgr.h`).
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import 'sgr_attribute.dart';

/// The separator that follows an SGR parameter.
///
/// Colons separate the sub-parameters of one attribute (`4:3` for a curly
/// underline, `38:2::255:0:0` for a direct colour); semicolons separate
/// attributes, and the classic `38;2;255;0;0` form also uses them.
enum SgrSeparator {
  /// `;`
  semicolon,

  /// `:`
  colon,
}

/// Turns the parameters of an SGR (Select Graphic Rendition, `CSI ... m`)
/// sequence into typed [SgrAttribute]s, exactly as the terminal reads them.
///
/// A terminal parses SGR by itself; use this for SGR sequences outside of
/// one. Semicolon and colon separators are both accepted, even mixed.
///
/// ```dart
/// final parser = SgrParser();
/// parser.parse([1, 38, 5, 196]);
/// // [SgrFlag(bold), SgrForeground(PaletteColor(196), indexed)]
/// parser.parseString('4:3;58:2::255:0:0');
/// // [SgrUnderline(curly), SgrUnderlineColor(RgbColor(255, 0, 0), direct)]
/// parser.dispose();
/// ```
///
/// ## Ownership
///
/// The parser owns a small native object. Reuse one parser for many
/// sequences and call [dispose] when done; a finalizer frees it if you
/// forget. After [dispose], [parse] and [parseString] throw [StateError].
/// The returned attributes are plain Dart values that outlive the parser.
final class SgrParser implements Finalizable {
  /// Creates a parser.
  ///
  /// Throws [GhosttyException] if the library cannot allocate it and
  /// [IncompatibleLibraryException] if the loaded libghostty-vt is not a
  /// supported 1.x version.
  SgrParser()
    : _handle = NativeHandle(
        createNative<GhosttySgrParserImpl>(
          'ghostty_sgr_new',
          (out) => ghostty_sgr_new(nullptr, out),
        ),
        typeName: 'SgrParser',
        free: (p) => ghostty_sgr_free(p),
        finalizer: _finalizer,
      ) {
    bindHandle(this, _handle);
  }

  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttySgrParser)>>(
      ghostty_sgr_free,
    ).cast(),
  );

  /// The most parameters a list may have when any of its separators is a
  /// colon. Lists with only semicolons have no limit.
  static const maxParametersWithColons = 24;

  final NativeHandle<GhosttySgrParserImpl> _handle;

  /// Whether [dispose] has been called.
  bool get isDisposed => _handle.isDisposed;

  /// Parses the SGR parameter list [params] (for `ESC[1;31m`, `[1, 31]`)
  /// into attributes, in order.
  ///
  /// [separators], if given, has one entry per parameter: the separator
  /// that *follows* that parameter. The last entry counts too: a colon
  /// there is a trailing colon (`ESC[4:m`), which makes the last attribute
  /// [SgrUnrecognized] if it expects sub-parameters. When omitted, every
  /// separator is a semicolon. An empty [params] means `ESC[m`, which is
  /// [SgrReset].
  ///
  /// Unknown or malformed attributes become [SgrUnrecognized] and parsing
  /// continues.
  ///
  /// Throws [RangeError] if a parameter is outside 0–65535, [ArgumentError]
  /// if [separators] has a different length than [params] or if a list with
  /// colons is longer than [maxParametersWithColons], and [StateError]
  /// after [dispose].
  List<SgrAttribute> parse(List<int> params, {List<SgrSeparator>? separators}) {
    _handle.checkNotDisposed();
    final count = params.length;
    for (var i = 0; i < count; i++) {
      RangeError.checkValueInInterval(params[i], 0, 0xFFFF, 'params[$i]');
    }
    final hasColons = separators != null && _checkSeparators(separators, count);
    // One block: the uint16 parameters, then (only if there are colons) one
    // separator byte per parameter.
    final paramBytes = count * sizeOf<Uint16>();
    final block = Uint8List(paramBytes + (hasColons ? count : 0));
    block.buffer.asUint16List(0, count).setAll(0, params);
    if (hasColons) {
      for (var i = 0; i < count; i++) {
        block[paramBytes + i] = separators[i] == SgrSeparator.colon
            ? _colon
            : _semicolon;
      }
    }
    return withNativeBytes(block, (data, _) {
      checkResult(
        ghostty_sgr_set_params(
          _handle.pointer,
          data.cast(),
          hasColons ? (data + paramBytes).cast() : nullptr,
          count,
        ),
        'ghostty_sgr_set_params',
      );
      return _readAttributes(List.unmodifiable(params));
    });
  }

  /// Parses SGR parameters written as text, as they appear between `ESC[`
  /// and `m`: decimal numbers separated by `;` or `:`, e.g.
  /// `'1;38:2::255:0:0'`.
  ///
  /// The text is split the way the terminal's CSI parser splits it: each
  /// separator ends one parameter and an empty parameter before a separator
  /// is 0, so `'38:2::1:2:3'` has an empty colour-space field and `';1'` is
  /// `[0, 1]`. An empty last parameter is dropped, so `'1;'` is just `[1]`
  /// (bold, not bold-then-reset), and a trailing colon (`'4:'`) stays the
  /// separator after the last parameter. An empty string means `ESC[m`
  /// ([SgrReset]).
  ///
  /// Throws [FormatException] for any other character or a parameter above
  /// 65535, plus the errors of [parse].
  List<SgrAttribute> parseString(String params) {
    if (params.isEmpty) return parse(const []);
    final values = <int>[];
    final separators = <SgrSeparator>[];
    var value = 0;
    var hasDigits = false;
    for (var i = 0; i < params.length; i++) {
      final unit = params.codeUnitAt(i);
      if (unit >= _zero && unit <= _zero + 9) {
        value = value * 10 + (unit - _zero);
        hasDigits = true;
        if (value > 0xFFFF) {
          throw FormatException('SGR parameter above 65535', params, i);
        }
      } else if (unit == _semicolon || unit == _colon) {
        values.add(value);
        separators.add(
          unit == _colon ? SgrSeparator.colon : SgrSeparator.semicolon,
        );
        value = 0;
        hasDigits = false;
      } else {
        throw FormatException('Not an SGR parameter character', params, i);
      }
    }
    // Like the terminal's CSI parser (`Parser.zig`, csi_dispatch), the final
    // parameter is only kept if it has digits; otherwise the last separator
    // stays attached to the previous parameter.
    if (hasDigits) {
      values.add(value);
      separators.add(SgrSeparator.semicolon);
    }
    return parse(values, separators: separators);
  }

  /// Frees the native parser. Safe to call more than once.
  void dispose() => _handle.dispose();

  /// Validates [separators] and returns whether any of them is a colon.
  static bool _checkSeparators(List<SgrSeparator> separators, int count) {
    if (separators.length != count) {
      throw ArgumentError.value(
        separators.length,
        'separators',
        'must have one entry per parameter ($count)',
      );
    }
    if (!separators.contains(SgrSeparator.colon)) return false;
    if (count > maxParametersWithColons) {
      throw ArgumentError.value(
        count,
        'params',
        'at most $maxParametersWithColons parameters are supported when a '
            'separator is a colon',
      );
    }
    return true;
  }

  /// Drains `ghostty_sgr_next`, copying each attribute into Dart: the
  /// unknown-parameter pointers point into the parser and are only valid
  /// until the next call.
  List<SgrAttribute> _readAttributes(List<int> params) =>
      withScratch(sizeOf<GhosttySgrAttribute>(), (memory) {
        final attribute = memory.cast<GhosttySgrAttribute>();
        final attributes = <SgrAttribute>[];
        while (ghostty_sgr_next(_handle.pointer, attribute)) {
          attributes.add(_decode(attribute.ref, params));
        }
        return attributes;
      });

  static SgrAttribute _decode(GhosttySgrAttribute attribute, List<int> params) {
    final value = attribute.value;
    return switch (attribute.tag) {
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNSET => const SgrReset(),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNKNOWN => SgrUnrecognized(
        parameters: _copyParams(
          value.unknown.partial_ptr,
          value.unknown.partial_len,
        ),
        allParameters: _copyParams(
          value.unknown.full_ptr,
          value.unknown.full_len,
        ),
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE => SgrUnderline(
        underlineStyleCodec.decode(value.underline),
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE_COLOR =>
        SgrUnderlineColor(
          rgbFromNative(value.underline_color),
          SgrColorForm.direct,
        ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE_COLOR_256 =>
        SgrUnderlineColor(
          PaletteColor(value.underline_color_256),
          SgrColorForm.indexed,
        ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_UNDERLINE_COLOR =>
        const SgrUnderlineColor(DefaultColor(), SgrColorForm.reset),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_DIRECT_COLOR_FG => SgrForeground(
        rgbFromNative(value.direct_color_fg),
        SgrColorForm.direct,
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_DIRECT_COLOR_BG => SgrBackground(
        rgbFromNative(value.direct_color_bg),
        SgrColorForm.direct,
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FG_8 => SgrForeground(
        PaletteColor(value.fg_8),
        SgrColorForm.standard,
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BG_8 => SgrBackground(
        PaletteColor(value.bg_8),
        SgrColorForm.standard,
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BRIGHT_FG_8 => SgrForeground(
        PaletteColor(value.bright_fg_8),
        SgrColorForm.bright,
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BRIGHT_BG_8 => SgrBackground(
        PaletteColor(value.bright_bg_8),
        SgrColorForm.bright,
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FG_256 => SgrForeground(
        PaletteColor(value.fg_256),
        SgrColorForm.indexed,
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BG_256 => SgrBackground(
        PaletteColor(value.bg_256),
        SgrColorForm.indexed,
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_FG => const SgrForeground(
        DefaultColor(),
        SgrColorForm.reset,
      ),
      GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_BG => const SgrBackground(
        DefaultColor(),
        SgrColorForm.reset,
      ),
      final tag => switch (_flags[tag]) {
        final flag? => SgrFlag(flag),
        // A tag from a later library release.
        null => SgrUnrecognized(parameters: const [], allParameters: params),
      },
    };
  }

  static List<int> _copyParams(Pointer<Uint16> data, int length) =>
      length == 0 ? const [] : data.asTypedList(length).toList();

  static const _zero = 0x30;
  static const _semicolon = 0x3B;
  static const _colon = 0x3A;

  static const _flags = <int, SgrFlagKind>{
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BOLD: SgrFlagKind.bold,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_BOLD: SgrFlagKind.resetBold,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_ITALIC: SgrFlagKind.italic,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_ITALIC:
        SgrFlagKind.resetItalic,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FAINT: SgrFlagKind.faint,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_OVERLINE: SgrFlagKind.overline,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_OVERLINE:
        SgrFlagKind.resetOverline,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BLINK: SgrFlagKind.blink,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_BLINK: SgrFlagKind.resetBlink,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_INVERSE: SgrFlagKind.inverse,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_INVERSE:
        SgrFlagKind.resetInverse,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_INVISIBLE: SgrFlagKind.invisible,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_INVISIBLE:
        SgrFlagKind.resetInvisible,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_STRIKETHROUGH:
        SgrFlagKind.strikethrough,
    GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_STRIKETHROUGH:
        SgrFlagKind.resetStrikethrough,
  };
}
