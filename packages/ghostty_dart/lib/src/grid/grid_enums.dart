/// Enums of grid rows (`screen.h`).
///
/// Pure Dart (no `dart:ffi`), so a future web backend can reuse them. The
/// codec is a public top-level hidden from the module barrel.
library;

import '../core/enum_codec.dart';

/// Whether a row holds a shell prompt, as reported by semantic prompt
/// sequences (OSC 133) (`GhosttyRowSemanticPrompt`).
///
/// Read it from `GridRow.semanticPrompt`. Shell integrations use it to jump
/// between prompts or to tell a prompt line from command output.
enum RowSemanticPrompt {
  /// No cell of the row is part of a prompt.
  none(0),

  /// The row holds prompt cells and is the first line of a prompt.
  prompt(1),

  /// The row holds prompt cells and continues a multi-line prompt.
  promptContinuation(2),

  /// A value added by a later libghostty-vt release.
  unknown(null);

  const RowSemanticPrompt(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyRowSemanticPrompt` values to [RowSemanticPrompt] and
/// back.
final rowSemanticPromptCodec = RawEnumCodec<RowSemanticPrompt>(
  RowSemanticPrompt.values,
  raw: (prompt) => prompt._raw,
  unknown: RowSemanticPrompt.unknown,
);
