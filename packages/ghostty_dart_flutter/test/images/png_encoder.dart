// A tiny PNG encoder for decoder tests: it builds every colour type, bit
// depth, filter type and interlacing from plain sample values, and exposes
// the pieces (chunks, scanlines, zlib) so tests can break them one by one.

import 'dart:io';
import 'dart:typed_data';

/// The PNG file signature.
const pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Adam7 passes: x start, y start, x step, y step.
const adam7 = [
  [0, 0, 8, 8],
  [4, 0, 8, 8],
  [0, 4, 4, 8],
  [2, 0, 4, 4],
  [0, 2, 2, 4],
  [1, 0, 2, 2],
  [0, 1, 1, 2],
];

/// Channels per pixel of each colour type.
int channelsOf(int colorType) =>
    const {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colorType]!;

/// The CRC-32 of [bytes] (bit by bit: slow, obviously right).
int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final byte in bytes) {
    c ^= byte;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

/// Big-endian bytes of a 32-bit [value].
List<int> u32(int value) => [
  value >> 24 & 0xFF,
  value >> 16 & 0xFF,
  value >> 8 & 0xFF,
  value & 0xFF,
];

/// One chunk: length, [type], [data], CRC (or [crc] when given).
List<int> chunk(String type, List<int> data, {int? crc}) {
  final typed = [...type.codeUnits, ...data];
  return [...u32(data.length), ...typed, ...u32(crc ?? crc32(typed))];
}

/// The IHDR chunk's data.
List<int> ihdrData(
  int width,
  int height,
  int bitDepth,
  int colorType, {
  bool interlace = false,
  int compression = 0,
  int filter = 0,
}) => [
  ...u32(width),
  ...u32(height),
  bitDepth,
  colorType,
  compression,
  filter,
  if (interlace) 1 else 0,
];

/// zlib-compresses [data].
List<int> zlib(List<int> data) => ZLibEncoder().convert(data);

/// gzip-compresses [data] (a stream zlib's inflate can also accept).
List<int> gzip(List<int> data) => GZipCodec().encode(data);

/// Packs one row of samples ([samples], channel values in pixel order) at
/// [bitDepth]: MSB-first for depths below 8, big-endian for 16.
List<int> packRow(List<int> samples, int bitDepth) {
  if (bitDepth == 8) return samples;
  if (bitDepth == 16) {
    return [
      for (final s in samples) ...[s >> 8, s & 0xFF],
    ];
  }
  final out = Uint8List((samples.length * bitDepth + 7) >> 3);
  for (var i = 0; i < samples.length; i++) {
    final bit = i * bitDepth;
    out[bit >> 3] |= samples[i] << (8 - bitDepth - (bit & 7));
  }
  return out;
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// Filters [rows] (packed, unfiltered) with the filter type [filterOf]
/// returns for each row, prefixing each with its type byte.
List<int> filterRows(
  List<List<int>> rows,
  int bpp,
  int Function(int row) filterOf,
) {
  final out = <int>[];
  List<int>? prev;
  for (var y = 0; y < rows.length; y++) {
    final row = rows[y];
    final type = filterOf(y);
    out.add(type);
    for (var i = 0; i < row.length; i++) {
      final a = i >= bpp ? row[i - bpp] : 0;
      final b = prev != null ? prev[i] : 0;
      final c = i >= bpp && prev != null ? prev[i - bpp] : 0;
      final predictor = switch (type) {
        0 => 0,
        1 => a,
        2 => b,
        3 => (a + b) >> 1,
        4 => _paeth(a, b, c),
        _ => 0, // Invalid types are written unfiltered.
      };
      out.add((row[i] - predictor) & 0xFF);
    }
    prev = row;
  }
  return out;
}

/// A test image: sample values per pixel, plus what it should decode to.
final class TestImage {
  /// Creates an image of [width] × [height] with [pixels] (one list of
  /// channel values per pixel, row-major).
  TestImage({
    required this.width,
    required this.height,
    required this.colorType,
    required this.bitDepth,
    required this.pixels,
    this.palette,
    this.trns,
  });

  final int width;
  final int height;
  final int colorType;
  final int bitDepth;
  final List<List<int>> pixels;

  /// RGB triplets, flattened (colour type 3).
  final List<int>? palette;

  /// The tRNS chunk's data.
  final List<int>? trns;

  int get _bpp => (channelsOf(colorType) * bitDepth + 7) >> 3;

  /// The filtered scanlines, interlaced or not, before compression.
  List<int> scanlines({
    bool interlace = false,
    int Function(int row)? filterOf,
  }) {
    final filter = filterOf ?? (row) => row % 5;
    if (!interlace) {
      return filterRows(
        [
          for (var y = 0; y < height; y++)
            packRow([
              for (var x = 0; x < width; x++) ...pixels[y * width + x],
            ], bitDepth),
        ],
        _bpp,
        filter,
      );
    }
    final out = <int>[];
    for (final p in adam7) {
      final rows = <List<int>>[];
      for (var y = p[1]; y < height; y += p[3]) {
        final samples = <int>[];
        for (var x = p[0]; x < width; x += p[2]) {
          samples.addAll(pixels[y * width + x]);
        }
        if (samples.isNotEmpty) rows.add(packRow(samples, bitDepth));
      }
      out.addAll(filterRows(rows, _bpp, filter));
    }
    return out;
  }

  /// A complete PNG file.
  Uint8List encode({
    bool interlace = false,
    int Function(int row)? filterOf,
    int idatPieces = 1,
    List<List<int>> beforeIdat = const [],
  }) {
    final compressed = zlib(
      scanlines(interlace: interlace, filterOf: filterOf),
    );
    final idats = <int>[];
    final size = (compressed.length + idatPieces - 1) ~/ idatPieces;
    for (var i = 0; i < compressed.length; i += size) {
      final end = i + size < compressed.length ? i + size : compressed.length;
      idats.addAll(chunk('IDAT', compressed.sublist(i, end)));
    }
    return Uint8List.fromList([
      ...pngSignature,
      ...chunk(
        'IHDR',
        ihdrData(width, height, bitDepth, colorType, interlace: interlace),
      ),
      if (palette != null) ...chunk('PLTE', palette!),
      if (trns != null) ...chunk('tRNS', trns!),
      for (final c in beforeIdat) ...c,
      ...idats,
      ...chunk('IEND', const []),
    ]);
  }

  /// The RGBA8 pixels a correct decoder returns, computed independently of
  /// the decoder's code.
  Uint8List expectedRgba() {
    final out = Uint8List(width * height * 4);
    final max = (1 << bitDepth) - 1;
    int to8(int v) => bitDepth == 16 ? v >> 8 : (v * 255 / max).round();
    for (var i = 0; i < pixels.length; i++) {
      final px = pixels[i];
      final List<int> rgba;
      switch (colorType) {
        case 0:
          final keyed = trns != null && (trns![0] << 8 | trns![1]) == px[0];
          rgba = [to8(px[0]), to8(px[0]), to8(px[0]), keyed ? 0 : 255];
        case 2:
          final t = trns;
          final keyed =
              t != null &&
              (t[0] << 8 | t[1]) == px[0] &&
              (t[2] << 8 | t[3]) == px[1] &&
              (t[4] << 8 | t[5]) == px[2];
          rgba = [to8(px[0]), to8(px[1]), to8(px[2]), keyed ? 0 : 255];
        case 3:
          final idx = px[0];
          final alpha = trns != null && idx < trns!.length ? trns![idx] : 255;
          rgba = [...palette!.sublist(idx * 3, idx * 3 + 3), alpha];
        case 4:
          rgba = [to8(px[0]), to8(px[0]), to8(px[0]), to8(px[1])];
        default:
          rgba = [for (final v in px) to8(v)];
      }
      out.setRange(i * 4, i * 4 + 4, rgba);
    }
    return out;
  }
}
