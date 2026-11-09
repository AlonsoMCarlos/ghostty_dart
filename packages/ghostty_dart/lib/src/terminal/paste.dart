/// Types for pasting into a terminal (`paste.h`) and naming clipboards
/// (`GhosttyClipboardLocation`).
library;

import '../core/enum_codec.dart';

/// Which clipboard some content belongs to (`GhosttyClipboardLocation`).
///
/// Protocol-specific clipboard names (OSC 52 `c`/`s`/`p`, Kitty clipboard)
/// are normalized to these values.
enum ClipboardLocation {
  /// The standard system clipboard.
  standard(0),

  /// The selection clipboard.
  selection(1),

  /// The primary selection clipboard (X11 middle click).
  primary(2),

  /// A location added by a later libghostty-vt release.
  unknown(null);

  const ClipboardLocation(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyClipboardLocation` values to [ClipboardLocation]
/// and back.
final clipboardLocationCodec = RawEnumCodec<ClipboardLocation>(
  ClipboardLocation.values,
  raw: (location) => location._raw,
  unknown: ClipboardLocation.unknown,
);

/// Why a paste happened (`GhosttyPasteSource`).
enum PasteSource {
  /// The user pasted from a clipboard: a key binding, a menu, a middle
  /// click. May become a Kitty clipboard paste event (mode 5522).
  clipboard(0),

  /// Text inserted some other way: an IME commit, drag and drop, scripted
  /// input. Always written as text, never as a paste event.
  text(1);

  const PasteSource(this._raw);

  final int _raw;
}

/// The raw `GhosttyPasteSource` value of [source].
int pasteSourceToRaw(PasteSource source) => source._raw;

/// The outcome of `VtTerminal.paste` and `VtTerminal.pasteText`.
enum PasteResult {
  /// The paste was written to the pty (as framed text or as a paste event).
  pasted,

  /// Nothing was written: there was no non-empty text representation.
  nothingToPaste,

  /// Nothing was written because the text could inject commands (e.g. a
  /// newline outside bracketed paste mode). Confirm with the user and paste
  /// again with `allowUnsafe: true`.
  rejected,
}
