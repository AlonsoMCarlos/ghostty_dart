/// Decoding of packed `GhosttyCell` values without one FFI call per cell.
///
/// Internal to the render module (the grid module may reuse it). A
/// `GhosttyCell` is a `uint64_t` whose bit layout is *not* ABI-stable: the
/// library publishes it in the `ghostty_type_json()` manifest, and
/// `screen.h` / `render.h` (`GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW`)
/// support decoding raw cells only through that manifest ("hardcoding bit
/// positions is unsupported"). Hardcoded constants are therefore only used
/// after the manifest has been verified to match them. This file
/// defines one canonical layout as compile-time constants (the layout of
/// libghostty-vt 1.0.0), checks once per process that the loaded library
/// uses it, and otherwise transcodes every cell into it with
/// `ghostty_cell_get_multi`. Readers always decode the canonical layout,
/// so the fast path is a few shifts and masks on constants.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/color.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import 'render_enums.dart';

/// Canonical bit layout of a packed cell (libghostty-vt 1.0.0 manifest).
abstract final class CellBits {
  /// `content_tag` (`GhosttyCellContentTag`) at bits 0–1.
  static const tagMask = 0x3;

  /// Start of the 24-bit `content` union.
  static const contentShift = 2;

  /// The codepoint arm of `content` (21 bits).
  static const codepointMask = 0x1FFFFF;

  /// The palette-index arm of `content` (8 bits).
  static const paletteMask = 0xFF;

  /// Mask of one 8-bit channel of the RGB arm (r in bits 0–7, g in 8–15,
  /// b in 16–23), after shifting.
  static const channelMask = 0xFF;

  /// Shift of the green channel within the RGB arm (red is at 0).
  static const greenShift = 8;

  /// Shift of the blue channel within the RGB arm.
  static const blueShift = 16;

  /// `style_id` (`GhosttyStyleId`, 16 bits). 0 is the default style.
  static const styleIdShift = 26;

  /// Mask of `style_id` after shifting.
  static const styleIdMask = 0xFFFF;

  /// `wide` (`GhosttyCellWide`, 2 bits).
  static const wideShift = 42;

  /// Mask of `wide` after shifting.
  static const wideMask = 0x3;

  /// `protected` flag.
  static const protectedBit = 1 << 44;

  /// `hyperlink` flag.
  static const hyperlinkBit = 1 << 45;

  /// `semantic_content` (`GhosttyCellSemanticContent`, 2 bits).
  static const semanticShift = 46;

  /// Mask of `semantic_content` after shifting.
  static const semanticMask = 0x3;

  /// `GHOSTTY_CELL_CONTENT_CODEPOINT`.
  static const tagCodepoint = 0;

  /// `GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME`.
  static const tagGrapheme = 1;

  /// `GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE`.
  static const tagBgPalette = 2;

  /// `GHOSTTY_CELL_CONTENT_BG_COLOR_RGB`.
  static const tagBgRgb = 3;
}

/// A packed cell in the canonical [CellBits] layout, read field by field
/// with shifts and masks. A zero-cost view over the 64-bit value: the one
/// decoder shared by render rows and grid references.
///
/// Only meaningful for canonical bits: a raw native cell when
/// [nativeCellLayoutIsCanonical], else the output of [CellTranscoder].
extension type const PackedCell(int bits) {
  /// The raw `content_tag` (one of the `CellBits.tag*` values).
  int get tag => bits & CellBits.tagMask;

  /// Whether the content arm is a codepoint (single or grapheme base), not
  /// a background colour.
  bool get hasCodepoint => tag <= CellBits.tagGrapheme;

  /// Whether the cell holds a multi-codepoint grapheme cluster.
  bool get hasGrapheme => tag == CellBits.tagGrapheme;

  /// The base codepoint, or 0 for an empty or colour-only cell.
  int get codepoint => hasCodepoint ? _content & CellBits.codepointMask : 0;

  /// The style id; 0 is the default style. Only meaningful within one row.
  int get styleId => bits >> CellBits.styleIdShift & CellBits.styleIdMask;

  /// Whether the cell is narrow, wide or a spacer.
  CellWidth get width =>
      _widths[bits >> CellBits.wideShift & CellBits.wideMask];

  /// Whether the cell is part of an OSC 8 hyperlink.
  bool get hasHyperlink => bits & CellBits.hyperlinkBit != 0;

  /// Whether the cell is protected from erasing (DECSCA / SPA).
  bool get isProtected => bits & CellBits.protectedBit != 0;

  /// The shell content kind (OSC 133).
  CellSemanticContent get semanticContent =>
      _semantics[bits >> CellBits.semanticShift & CellBits.semanticMask];

  /// The colour of a colour-only cell, or `null` when the cell has text
  /// (its background then comes from its style). Palette colours are
  /// shared instances; an RGB colour allocates.
  ColorRef? get backgroundColor => switch (tag) {
    CellBits.tagBgPalette => _paletteRefs[_content & CellBits.paletteMask],
    CellBits.tagBgRgb => RgbColor(
      _content & CellBits.channelMask,
      _content >> CellBits.greenShift & CellBits.channelMask,
      _content >> CellBits.blueShift & CellBits.channelMask,
    ),
    _ => null,
  };

  int get _content => bits >> CellBits.contentShift;
}

// Lookup tables indexed by the raw 2-bit fields: cheaper than the codecs on
// the hot path. Valid because [cellLayoutMatchesManifest] pins these enums'
// raw values; the 2-bit semantic value 3 is not defined in 1.0.0 and
// decodes as unknown.
const _widths = [
  CellWidth.narrow,
  CellWidth.wide,
  CellWidth.spacerTail,
  CellWidth.spacerHead,
];
const _semantics = [
  CellSemanticContent.output,
  CellSemanticContent.input,
  CellSemanticContent.prompt,
  CellSemanticContent.unknown,
];
final _paletteRefs = List<PaletteColor>.generate(
  256,
  PaletteColor.new,
  growable: false,
);

/// Whether the loaded library packs cells in the canonical [CellBits]
/// layout, so raw cell views can be decoded in place. Computed once.
final bool nativeCellLayoutIsCanonical = () {
  try {
    final json = ghostty_type_json().cast<Utf8>().toDartString();
    return cellLayoutMatchesManifest(jsonDecode(json));
  } on Object {
    // A manifest we cannot read is treated as an unknown layout: the
    // transcoding path is always correct, only slower.
    return false;
  }
}();

/// Whether [manifest] (the decoded `ghostty_type_json()` document)
/// describes `GhosttyCell` with exactly the canonical [CellBits] positions,
/// field types and enum values.
///
/// The decoders map the raw `content_tag`, `wide` and `semantic_content`
/// bits to Dart values by their 1.0.0 numbers, so those enums' values are
/// checked too: a renumbered value would otherwise be decoded silently
/// wrong. New semantic values are allowed (they decode as `unknown`); the
/// two-bit tag and wide enums are already full.
///
/// Extra fields are ignored; a missing, moved or retyped field, a changed
/// enum value, another schema version or another size returns `false`.
bool cellLayoutMatchesManifest(Object? manifest) {
  if (manifest is! Map || manifest['schema'] != 1) return false;
  final cell = _path(manifest, ['types', 'GhosttyCell']);
  if (cell is! Map || cell['kind'] != 'packed' || cell['size'] != 8) {
    return false;
  }
  bool field(List<String> path, int lsb, int width, [String? type]) {
    final f = _path(cell, path);
    return f is Map &&
        f['lsb'] == lsb &&
        f['width'] == width &&
        (type == null || f['type'] == type);
  }

  bool enumValues(String type, Map<String, int> expected) {
    final values = _path(manifest, ['types', type, 'values']);
    if (values is! Map) return false;
    return expected.entries.every((e) => values[e.key] == e.value);
  }

  List<String> arm(String name, String bit) => [
    'bits',
    'content',
    'arms',
    name,
    'bits',
    bit,
  ];
  return field(['bits', 'content_tag'], 0, 2, 'GhosttyCellContentTag') &&
      field(['bits', 'content'], 2, 24) &&
      _path(cell, ['bits', 'content', 'tag']) == 'content_tag' &&
      field(arm('CODEPOINT', 'codepoint'), 0, 21) &&
      field(arm('CODEPOINT_GRAPHEME', 'codepoint'), 0, 21) &&
      field(arm('BG_COLOR_PALETTE', 'index'), 0, 8) &&
      field(arm('BG_COLOR_RGB', 'r'), 0, 8) &&
      field(arm('BG_COLOR_RGB', 'g'), 8, 8) &&
      field(arm('BG_COLOR_RGB', 'b'), 16, 8) &&
      field(['bits', 'style_id'], 26, 16, 'GhosttyStyleId') &&
      field(['bits', 'wide'], 42, 2, 'GhosttyCellWide') &&
      field(['bits', 'protected'], 44, 1, 'bool') &&
      field(['bits', 'hyperlink'], 45, 1, 'bool') &&
      field(
        ['bits', 'semantic_content'],
        46,
        2,
        'GhosttyCellSemanticContent',
      ) &&
      enumValues('GhosttyCellContentTag', const {
        'CODEPOINT': CellBits.tagCodepoint,
        'CODEPOINT_GRAPHEME': CellBits.tagGrapheme,
        'BG_COLOR_PALETTE': CellBits.tagBgPalette,
        'BG_COLOR_RGB': CellBits.tagBgRgb,
      }) &&
      enumValues('GhosttyCellWide', const {
        'NARROW': 0,
        'WIDE': 1,
        'SPACER_TAIL': 2,
        'SPACER_HEAD': 3,
      }) &&
      enumValues('GhosttyCellSemanticContent', const {
        'OUTPUT': 0,
        'INPUT': 1,
        'PROMPT': 2,
      });
}

Object? _path(Object? node, List<String> keys) {
  for (final key in keys) {
    if (node is! Map) return null;
    node = node[key];
  }
  return node;
}

/// Converts native cells of an unknown layout into the canonical layout
/// with `ghostty_cell_get_multi`, one call per cell (plus one for the
/// background of colour-only cells).
///
/// Only used when [nativeCellLayoutIsCanonical] is `false`. Owns a small
/// native block for the key and value arrays, freed by [dispose] or by the
/// buffer's finalizer.
final class CellTranscoder {
  /// Allocates the native key/value arrays.
  CellTranscoder() : _memory = GrowableNativeBuffer(_bytes) {
    final base = _memory.pointer;
    _keys = base.cast<UnsignedInt>();
    _values = (base + _valuesOffset).cast<Pointer<Void>>();
    _slots = base + _slotsOffset;
    const keys = [
      GhosttyCellData.GHOSTTY_CELL_DATA_CODEPOINT,
      GhosttyCellData.GHOSTTY_CELL_DATA_CONTENT_TAG,
      GhosttyCellData.GHOSTTY_CELL_DATA_STYLE_ID,
      GhosttyCellData.GHOSTTY_CELL_DATA_WIDE,
      GhosttyCellData.GHOSTTY_CELL_DATA_PROTECTED,
      GhosttyCellData.GHOSTTY_CELL_DATA_HAS_HYPERLINK,
      GhosttyCellData.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT,
    ];
    for (var i = 0; i < _count; i++) {
      _keys[i] = keys[i];
      _values[i] = (_slots + i * _slotSize).cast();
    }
  }

  // Slot of each key in the constructor's key list.
  static const _codepointSlot = 0;
  static const _tagSlot = 1;
  static const _styleIdSlot = 2;
  static const _wideSlot = 3;
  static const _protectedSlot = 4;
  static const _hyperlinkSlot = 5;
  static const _semanticSlot = 6;

  static const _count = 7;
  static const _slotSize = 8;
  static const _valuesOffset = 64;
  static const _slotsOffset = _valuesOffset + _count * 8;
  static const _colorSlot = _count;
  static const _bytes = _slotsOffset + (_count + 1) * _slotSize;

  final GrowableNativeBuffer _memory;
  late final Pointer<UnsignedInt> _keys;
  late final Pointer<Pointer<Void>> _values;
  late final Pointer<Uint8> _slots;

  /// Transcodes [length] native cells at [source] into [target]
  /// (canonical layout). [target] must hold at least [length] values.
  void transcode(Pointer<Uint64> source, int length, Uint64List target) {
    for (var x = 0; x < length; x++) {
      target[x] = _transcodeOne(source[x]);
    }
  }

  int _transcodeOne(int cell) {
    _slots.asTypedList(_count * _slotSize).fillRange(0, _count * _slotSize, 0);
    checkResult(
      ghostty_cell_get_multi(cell, _count, _keys, _values, nullptr),
      'ghostty_cell_get_multi',
    );
    final tag = _u32(_tagSlot) & CellBits.tagMask;
    final content = switch (tag) {
      CellBits.tagBgPalette => _background(
        cell,
        GhosttyCellData.GHOSTTY_CELL_DATA_COLOR_PALETTE,
        (p) => p.value,
      ),
      CellBits.tagBgRgb => _background(
        cell,
        GhosttyCellData.GHOSTTY_CELL_DATA_COLOR_RGB,
        (p) => p[0] | p[1] << CellBits.greenShift | p[2] << CellBits.blueShift,
      ),
      _ => _u32(_codepointSlot) & CellBits.codepointMask,
    };
    final styleId = (_slots + _styleIdSlot * _slotSize).cast<Uint16>().value;
    return tag |
        content << CellBits.contentShift |
        styleId << CellBits.styleIdShift |
        (_u32(_wideSlot) & CellBits.wideMask) << CellBits.wideShift |
        (_flag(_protectedSlot) ? CellBits.protectedBit : 0) |
        (_flag(_hyperlinkSlot) ? CellBits.hyperlinkBit : 0) |
        (_u32(_semanticSlot) & CellBits.semanticMask) << CellBits.semanticShift;
  }

  // Each slot holds its key's documented type: a uint32_t codepoint, 4-byte
  // enums, a uint16_t style id and 1-byte bools.
  int _u32(int slot) => (_slots + slot * _slotSize).cast<Uint32>().value;

  bool _flag(int slot) => _slots[slot * _slotSize] != 0;

  int _background(int cell, int key, int Function(Pointer<Uint8> p) read) {
    final out = _slots + _colorSlot * _slotSize;
    out.cast<Uint64>().value = 0;
    checkResult(ghostty_cell_get(cell, key, out.cast()), 'ghostty_cell_get');
    return read(out);
  }

  /// Frees the native arrays. Safe to call more than once.
  void dispose() => _memory.dispose();
}
