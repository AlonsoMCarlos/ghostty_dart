/// Boundaries and stop reports for `VtTerminal.writeUntil`
/// (`GhosttyTerminalBoundary`, `GhosttyTerminalWriteStop`).
library;

import '../core/enum_codec.dart';

/// A set of points in the VT stream where `VtTerminal.writeUntil` can stop
/// (`GhosttyTerminalBoundary` flags). Combine with `|`:
///
/// ```dart
/// final stops = WriteBoundaries.oscStart | WriteBoundaries.oscEnd;
/// ```
///
/// Most boundaries are the first or last byte of a control string (APC,
/// DCS or OSC), in either its 7-bit (`ESC ]`) or 8-bit (0x9D) form.
/// [ground] is different: it is the state between sequences.
final class WriteBoundaries {
  const WriteBoundaries._(this._bits);

  /// No boundary. Not valid as a request; reported when nothing was
  /// reached.
  static const none = WriteBoundaries._(0);

  /// The stream is not inside any escape sequence or partial UTF-8
  /// character: a safe point to insert your own sequences.
  ///
  /// Ground is a state, not an event: if the stream is already at ground,
  /// the write stops at once and consumes nothing.
  static const ground = WriteBoundaries._(1 << 0);

  /// The byte that started an APC string (`_` after ESC, or 0x9F). SOS
  /// and PM strings report it too; [WriteStop.byte] tells them apart.
  static const apcStart = WriteBoundaries._(1 << 1);

  /// The byte that ended an APC, SOS or PM string.
  static const apcEnd = WriteBoundaries._(1 << 2);

  /// The byte that started a DCS string (`P` after ESC, or 0x90). The DCS
  /// header follows the stop.
  static const dcsStart = WriteBoundaries._(1 << 3);

  /// The byte that ended a DCS string, in its header or its payload.
  static const dcsEnd = WriteBoundaries._(1 << 4);

  /// The byte that started an OSC string (`]` after ESC, or 0x9D).
  static const oscStart = WriteBoundaries._(1 << 5);

  /// The byte that ended an OSC string, including OSCs the terminal does
  /// not understand.
  static const oscEnd = WriteBoundaries._(1 << 6);

  /// Every start boundary.
  static const anyStart = WriteBoundaries._(1 << 1 | 1 << 3 | 1 << 5);

  /// Every end boundary.
  static const anyEnd = WriteBoundaries._(1 << 2 | 1 << 4 | 1 << 6);

  /// Every boundary this package knows.
  static const all = WriteBoundaries._(0x7F);

  final int _bits;

  /// Whether no boundary is set.
  bool get isEmpty => _bits == 0;

  /// Whether every boundary in [other] is also set here.
  bool containsAll(WriteBoundaries other) => _bits & other._bits == other._bits;

  /// Whether at least one boundary in [other] is also set here.
  bool containsAny(WriteBoundaries other) => _bits & other._bits != 0;

  /// The union of both sets.
  WriteBoundaries operator |(WriteBoundaries other) =>
      WriteBoundaries._(_bits | other._bits);

  /// The boundaries set in both.
  WriteBoundaries operator &(WriteBoundaries other) =>
      WriteBoundaries._(_bits & other._bits);

  /// The boundaries set here but not in [other].
  WriteBoundaries operator -(WriteBoundaries other) =>
      WriteBoundaries._(_bits & ~other._bits);

  @override
  bool operator ==(Object other) =>
      other is WriteBoundaries && other._bits == _bits;

  @override
  int get hashCode => Object.hash(WriteBoundaries, _bits);

  @override
  String toString() {
    const names = [
      'ground',
      'apcStart',
      'apcEnd',
      'dcsStart',
      'dcsEnd',
      'oscStart',
      'oscEnd',
    ];
    final set = [
      for (var i = 0; i < names.length; i++)
        if (_bits & (1 << i) != 0) names[i],
      if (_bits & ~all._bits != 0)
        '0x${(_bits & ~all._bits).toRadixString(16)}',
    ];
    return 'WriteBoundaries(${set.join(' | ')})';
  }
}

/// The raw `GhosttyTerminalBoundary` bits of [boundaries].
int writeBoundariesToRaw(WriteBoundaries boundaries) => boundaries._bits;

/// Decodes raw `GhosttyTerminalBoundary` bits, keeping unknown ones.
WriteBoundaries writeBoundariesFromRaw(int raw) =>
    WriteBoundaries._(raw & 0xFFFFFFFF);

/// The kind of control string that started or ended
/// (`GhosttyTerminalStringKind`).
enum ControlStringKind {
  /// An APC, SOS or PM string. [WriteStop.byte] at the start tells which:
  /// `_`/0x9F is APC, `X`/0x98 is SOS, `^`/0x9E is PM.
  apc(0),

  /// A DCS string (`P` after ESC, or 0x90).
  dcs(1),

  /// An OSC string (`]` after ESC, or 0x9D).
  osc(2),

  /// A kind added by a later libghostty-vt release.
  unknown(null);

  const ControlStringKind(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyTerminalStringKind` values to [ControlStringKind].
final controlStringKindCodec = RawEnumCodec<ControlStringKind>(
  ControlStringKind.values,
  raw: (kind) => kind._raw,
  unknown: ControlStringKind.unknown,
);

/// How a control string started (`GhosttyTerminalStringIntroducer`).
enum ControlStringIntroducer {
  /// ESC followed by `_`, `X`, `^`, `P` or `]`. The stop's
  /// [WriteStop.consumed] includes only the final byte, because the ESC may
  /// have arrived in an earlier write.
  esc(0),

  /// A single 8-bit byte: 0x9F, 0x98, 0x9E, 0x90 or 0x9D. These only start
  /// a string inside another escape sequence; at ground they are UTF-8.
  c1(1),

  /// An introducer added by a later libghostty-vt release.
  unknown(null);

  const ControlStringIntroducer(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyTerminalStringIntroducer` values to
/// [ControlStringIntroducer].
final controlStringIntroducerCodec = RawEnumCodec<ControlStringIntroducer>(
  ControlStringIntroducer.values,
  raw: (introducer) => introducer._raw,
  unknown: ControlStringIntroducer.unknown,
);

/// How a control string ended (`GhosttyTerminalStringEnd`).
enum ControlStringEnd {
  /// ESC, the first byte of the terminator `ESC \`. The ESC is consumed but
  /// the `\` is not: it is the first byte of your next write. Forward the
  /// ESC along with the string if you relay the stream.
  stEsc(0),

  /// 0x9C, the 8-bit terminator. Only reported for an APC or a DCS still in
  /// its header; the stream is now at ground.
  stC1(1),

  /// CAN (0x18) or SUB (0x1A) cancelled the string; it is discarded and the
  /// stream is at ground.
  cancelled(2),

  /// Another 8-bit control byte cut the string short (only for an APC or a
  /// DCS still in its header). If that byte starts a new string, the same
  /// stop also has a start flag.
  aborted(3),

  /// BEL (0x07) ended the string. Only an OSC ends this way.
  bel(4),

  /// An ending added by a later libghostty-vt release.
  unknown(null);

  const ControlStringEnd(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyTerminalStringEnd` values to [ControlStringEnd].
final controlStringEndCodec = RawEnumCodec<ControlStringEnd>(
  ControlStringEnd.values,
  raw: (end) => end._raw,
  unknown: ControlStringEnd.unknown,
);

/// Where a `VtTerminal.writeUntil` call stopped, and why
/// (`GhosttyTerminalWriteStop`).
///
/// Fields that do not apply to the stop are `null`, so there is no need to
/// check [reached] before reading them.
final class WriteStop {
  /// Creates a stop report.
  const WriteStop({
    required this.consumed,
    required this.reached,
    this.kind,
    this.introducer,
    this.end,
    this.byte,
  });

  /// The number of input bytes consumed by the call, including the byte
  /// that reached the boundary. 0 when the stream was already at ground and
  /// [WriteBoundaries.ground] was requested.
  final int consumed;

  /// The requested boundaries the stopping byte reached; empty when all
  /// input was consumed without reaching one.
  ///
  /// Usually one flag. Two when one byte both ends a string and returns to
  /// ground (e.g. BEL with `oscEnd | ground`), or ends one string and
  /// starts another (an end flag, a start flag, [end] is
  /// [ControlStringEnd.aborted] and [introducer] is
  /// [ControlStringIntroducer.c1]).
  final WriteBoundaries reached;

  /// The kind of string that started or ended; when one byte does both,
  /// the kind that ended (the start flag in [reached] names the other).
  /// `null` unless [reached] has a start or end flag.
  final ControlStringKind? kind;

  /// How the string started. `null` unless [reached] has a start flag.
  final ControlStringIntroducer? introducer;

  /// How the string ended. `null` unless [reached] has an end flag.
  final ControlStringEnd? end;

  /// The byte that started or ended the string, such as `]` (0x5D), 0x90,
  /// ESC or BEL. `null` unless [reached] has a start or end flag.
  final int? byte;

  /// Whether a boundary was reached (otherwise all input was consumed).
  bool get reachedBoundary => !reached.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is WriteStop &&
      other.consumed == consumed &&
      other.reached == reached &&
      other.kind == kind &&
      other.introducer == introducer &&
      other.end == end &&
      other.byte == byte;

  @override
  int get hashCode =>
      Object.hash(consumed, reached, kind, introducer, end, byte);

  @override
  String toString() =>
      'WriteStop(consumed: $consumed, reached: $reached'
      '${kind == null ? '' : ', kind: ${kind!.name}'}'
      '${introducer == null ? '' : ', introducer: ${introducer!.name}'}'
      '${end == null ? '' : ', end: ${end!.name}'}'
      '${byte == null ? '' : ', byte: 0x${byte!.toRadixString(16)}'})';
}

/// Builds a [WriteStop] from the raw fields of `GhosttyTerminalWriteStop`,
/// nulling the fields that [reached] says do not apply.
WriteStop writeStopFromRaw({
  required int consumed,
  required int reached,
  required int kind,
  required int introducer,
  required int end,
  required int byte,
}) {
  final flags = writeBoundariesFromRaw(reached);
  final started = flags.containsAny(WriteBoundaries.anyStart);
  final ended = flags.containsAny(WriteBoundaries.anyEnd);
  final hasString = started || ended;
  return WriteStop(
    consumed: consumed,
    reached: flags,
    kind: hasString ? controlStringKindCodec.decode(kind) : null,
    introducer: started
        ? controlStringIntroducerCodec.decode(introducer)
        : null,
    end: ended ? controlStringEndCodec.decode(end) : null,
    byte: hasString ? byte : null,
  );
}
