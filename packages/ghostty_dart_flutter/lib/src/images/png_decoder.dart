/// A small, synchronous, fail-closed PNG decoder for Kitty graphics images
/// (ADR 0014).
library;

import 'dart:io' show RawZLibFilter;
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart' show RgbaImage;

/// Decodes the PNG file in [png] into straight (non-premultiplied) 8-bit
/// RGBA, or returns `null` when it is not a valid PNG this decoder accepts.
///
/// This is a `VtPngDecoder` for `setVtPngDecoder`: libghostty-vt calls it
/// synchronously while it parses a Kitty graphics transmission in PNG format
/// (`f=100`, the default of `kitten icat`). Install it once at start-up:
///
/// ```dart
/// import 'package:ghostty_dart/ghostty_dart.dart';
/// import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
///
/// void main() {
///   setVtPngDecoder(decodeVtPng);
///   runApp(const MyApp());
/// }
/// ```
///
/// The hook is **process-wide**: it applies to every terminal in the
/// process, and only the isolate that installed it may write PNG images to
/// terminals. That is why the widget never installs it on its own: an app
/// may prefer another decoder. Without any decoder, PNG transmissions are
/// rejected while raw RGB, RGBA and grey transmissions still work.
///
/// Every colour type and bit depth is supported (16-bit samples keep their
/// high byte), with palettes, `tRNS` transparency and Adam7 interlacing.
/// There is no colour management: `gAMA`, `iCCP`, `sRGB`, `cHRM` and the
/// other ancillary chunks are ignored.
///
/// [png] is untrusted data sent by a program, so decoding fails closed: the
/// signature, the CRC of every chunk, the chunk order, the header fields,
/// the zlib framing and checksum, every filter byte and every palette index
/// are checked; images wider or taller than 16384 pixels, or larger than
/// 64 MiB as RGBA, are rejected before anything is allocated for them; and
/// the compressed data is inflated into a buffer of exactly the size the
/// header implies, aborting as soon as it would grow past it. Any failure,
/// including an unexpected internal error, returns `null`; this function
/// never throws.
RgbaImage? decodeVtPng(Uint8List png) {
  try {
    return _decode(png);
  } catch (_) {
    // Fail closed: malformed input and internal errors alike reject the
    // image instead of reaching libghostty-vt's callback as an exception.
    return null;
  }
}

/// The largest width or height accepted.
const _maxSide = 16384;

/// The largest decoded image accepted, in RGBA bytes.
const _maxRgbaBytes = 64 * 1024 * 1024;

const _signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

// Chunk types as big-endian 32-bit integers.
const _ihdr = 0x49484452;
const _plte = 0x504C5445;
const _idat = 0x49444154;
const _iend = 0x49454E44;
const _trns = 0x74524E53;

/// Thrown internally for any malformed input; [decodeVtPng] maps it to
/// `null`.
final class _Invalid implements Exception {
  const _Invalid();
}

Never _fail() => throw const _Invalid();

int _u32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

int _u16(Uint8List b, int i) => (b[i] << 8) | b[i + 1];

/// The header fields that drive decoding.
final class _Header {
  _Header(this.width, this.height, this.bitDepth, this.colorType, this.laced)
    : channels = switch (colorType) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        _ => _fail(),
      } {
    bitsPerPixel = channels * bitDepth;
    filterStride = bitsPerPixel < 8 ? 1 : bitsPerPixel >> 3;
  }

  final int width;
  final int height;
  final int bitDepth;
  final int colorType;
  final bool laced;
  final int channels;
  late final int bitsPerPixel;

  /// The byte distance to the "left" byte in filters (at least 1).
  late final int filterStride;

  /// The bytes of one filtered row of [pixels] pixels, without the filter
  /// type byte.
  int rowBytes(int pixels) => (pixels * bitsPerPixel + 7) >> 3;
}

/// Adam7 passes: x start, y start, x step, y step.
const _adam7 = [
  [0, 0, 8, 8],
  [4, 0, 8, 8],
  [0, 4, 4, 8],
  [2, 0, 4, 4],
  [0, 2, 2, 4],
  [1, 0, 2, 2],
  [0, 1, 1, 2],
];

/// One pass of the image (the whole image when not interlaced).
final class _Pass {
  const _Pass(this.x0, this.y0, this.dx, this.dy, this.width, this.height);

  final int x0;
  final int y0;
  final int dx;
  final int dy;
  final int width;
  final int height;
}

List<_Pass> _passes(_Header h) {
  if (!h.laced) return [_Pass(0, 0, 1, 1, h.width, h.height)];
  final passes = <_Pass>[];
  for (final p in _adam7) {
    final w = (h.width - p[0] + p[2] - 1) ~/ p[2];
    final hh = (h.height - p[1] + p[3] - 1) ~/ p[3];
    if (w > 0 && hh > 0) passes.add(_Pass(p[0], p[1], p[2], p[3], w, hh));
  }
  return passes;
}

_Header _parseHeader(Uint8List b, int at, int length) {
  if (length != 13) _fail();
  final width = _u32(b, at);
  final height = _u32(b, at + 4);
  final bitDepth = b[at + 8];
  final colorType = b[at + 9];
  if (width < 1 || width > _maxSide || height < 1 || height > _maxSide) {
    _fail();
  }
  if (width * height * 4 > _maxRgbaBytes) _fail();
  final validDepth = switch (colorType) {
    0 => const [1, 2, 4, 8, 16].contains(bitDepth),
    3 => const [1, 2, 4, 8].contains(bitDepth),
    2 || 4 || 6 => bitDepth == 8 || bitDepth == 16,
    _ => false,
  };
  if (!validDepth) _fail();
  // Compression method, filter method, interlace method.
  if (b[at + 10] != 0 || b[at + 11] != 0 || b[at + 12] > 1) _fail();
  return _Header(width, height, bitDepth, colorType, b[at + 12] == 1);
}

RgbaImage? _decode(Uint8List png) {
  if (png.length < 8) return null;
  for (var i = 0; i < 8; i++) {
    if (png[i] != _signature[i]) return null;
  }

  _Header? header;
  Uint8List? palette; // RGBA, 4 bytes per entry, tRNS alpha applied.
  var paletteSize = 0;
  int? keyR, keyG, keyB; // tRNS key colour (grey uses keyR), raw samples.
  var seenTrns = false;
  _Inflater? inflater;
  var idatEnded = false;
  var sawIend = false;

  var pos = 8;
  var first = true;
  while (!sawIend) {
    if (pos + 12 > png.length) _fail(); // Truncated: no IEND.
    final length = _u32(png, pos);
    if (length > 0x7FFFFFFF || length > png.length - pos - 12) _fail();
    final type = _u32(png, pos + 4);
    final data = pos + 8;
    final end = data + length;
    if (_crc32(png, pos + 4, end) != _u32(png, end)) _fail();
    for (var i = pos + 4; i < pos + 8; i++) {
      final c = png[i] | 0x20; // Lower-case ASCII letters only, after this.
      if (c < 0x61 || c > 0x7A) _fail();
    }
    pos = end + 4;

    if (first) {
      if (type != _ihdr) _fail();
      header = _parseHeader(png, data, length);
      first = false;
      continue;
    }
    final h = header!;
    if (inflater != null && type != _idat) idatEnded = true;

    switch (type) {
      case _ihdr:
        _fail();
      case _plte:
        if (palette != null || inflater != null || seenTrns) _fail();
        if (h.colorType == 0 || h.colorType == 4) _fail();
        if (length == 0 || length % 3 != 0 || length > 256 * 3) _fail();
        final entries = length ~/ 3;
        // Entries beyond the bit depth can never be indexed; libpng drops
        // them too instead of rejecting the file.
        final limit = h.colorType == 3 ? 1 << h.bitDepth : 256;
        paletteSize = entries < limit ? entries : limit;
        final p = palette = Uint8List(256 * 4);
        for (var i = 0; i < paletteSize; i++) {
          p[i * 4] = png[data + i * 3];
          p[i * 4 + 1] = png[data + i * 3 + 1];
          p[i * 4 + 2] = png[data + i * 3 + 2];
          p[i * 4 + 3] = 255;
        }
      case _trns:
        if (seenTrns || inflater != null) _fail();
        seenTrns = true;
        switch (h.colorType) {
          case 0:
            if (length != 2) _fail();
            keyR = _u16(png, data);
          case 2:
            if (length != 6) _fail();
            keyR = _u16(png, data);
            keyG = _u16(png, data + 2);
            keyB = _u16(png, data + 4);
          case 3:
            final p = palette;
            if (p == null || length > paletteSize) _fail();
            for (var i = 0; i < length; i++) {
              p[i * 4 + 3] = png[data + i];
            }
          default:
            _fail(); // Types 4 and 6 carry their own alpha.
        }
      case _idat:
        if (idatEnded) _fail(); // IDAT chunks must be consecutive.
        if (inflater == null) {
          if (h.colorType == 3 && palette == null) _fail();
          var size = 0;
          for (final p in _passes(h)) {
            size += p.height * (1 + h.rowBytes(p.width));
          }
          inflater = _Inflater(size);
        }
        inflater.add(png, data, end);
      case _iend:
        if (length != 0 || inflater == null) _fail();
        sawIend = true;
      default:
        // Bit 5 of the first byte clear: critical; an unknown one means the
        // image cannot be decoded correctly.
        if (png[data - 4] & 0x20 == 0) _fail();
    }
  }

  final h = header!;
  final raw = inflater!.finish();
  final out = Uint8List(h.width * h.height * 4);
  final expander = _Expander(
    h,
    raw,
    out,
    palette,
    paletteSize,
    keyR,
    keyG,
    keyB,
  );
  var offset = 0;
  for (final p in _passes(h)) {
    final rowBytes = h.rowBytes(p.width);
    _unfilter(raw, offset, rowBytes, p.height, h.filterStride);
    for (var y = 0; y < p.height; y++) {
      final src = offset + y * (rowBytes + 1) + 1;
      final dst = ((p.y0 + y * p.dy) * h.width + p.x0) * 4;
      expander.row(src, p.width, dst, p.dx * 4);
    }
    offset += p.height * (rowBytes + 1);
  }
  return RgbaImage(width: h.width, height: h.height, pixels: out);
}

/// Inflates the concatenated IDAT data into a buffer of exactly [size]
/// bytes, failing as soon as the output would exceed it.
final class _Inflater {
  _Inflater(int size) : _out = Uint8List(size);

  final Uint8List _out;
  final RawZLibFilter _filter = RawZLibFilter.inflateFilter();
  var _written = 0;

  /// The first two bytes of the stream (the zlib header), once seen.
  final _head = Uint8List(2);
  var _headLength = 0;

  /// The last four compressed bytes seen (the Adler-32 trailer at the end).
  final _tail = Uint8List(4);
  var _tailLength = 0;

  void add(Uint8List b, int start, int end) {
    for (var i = start; i < end && _headLength < 2; i++) {
      _head[_headLength++] = b[i];
    }
    if (_headLength == 2) _checkHeader();
    for (var i = end - 4 < start ? start : end - 4; i < end; i++) {
      if (_tailLength == 4) {
        _tail.setRange(0, 3, _tail, 1);
        _tail[3] = b[i];
      } else {
        _tail[_tailLength++] = b[i];
      }
    }
    if (start == end) return;
    _filter.process(b, start, end);
    _drain(false);
  }

  /// Rejects anything but a zlib header for deflate without a preset
  /// dictionary (the native filter would also accept gzip).
  void _checkHeader() {
    final cmf = _head[0];
    final flg = _head[1];
    if (cmf & 0x0F != 8 || cmf >> 4 > 7) _fail();
    if ((cmf << 8 | flg) % 31 != 0 || flg & 0x20 != 0) _fail();
  }

  void _drain(bool last) {
    while (true) {
      final chunk = last
          ? _filter.processed(end: true)
          : _filter.processed(flush: false);
      if (chunk == null) break;
      if (chunk.length > _out.length - _written) _fail();
      _out.setRange(_written, _written + chunk.length, chunk);
      _written += chunk.length;
    }
  }

  Uint8List finish() {
    if (_headLength < 2 || _tailLength < 4) _fail();
    _drain(true);
    if (_written != _out.length) _fail();
    // The trailer must be the last four bytes of the IDAT data: this
    // rejects truncated streams and data after the end of the stream
    // (dart:io's inflater stops at the end and ignores what follows, so
    // only appended bytes that end with this same checksum get through,
    // and they cannot change the already complete output).
    if (_adler32(_out) != _u32(_tail, 0)) _fail();
    return _out;
  }
}

int _adler32(Uint8List data) {
  var a = 1;
  var b = 0;
  const block = 1 << 16; // b stays far below 2^63 within a block.
  for (var start = 0; start < data.length; start += block) {
    final end = start + block < data.length ? start + block : data.length;
    for (var i = start; i < end; i++) {
      a += data[i];
      b += a;
    }
    a %= 65521;
    b %= 65521;
  }
  return (b << 16) | a;
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(Uint8List b, int start, int end) {
  final table = _crcTable;
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = table[(c ^ b[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// Reverses the row filters of one pass in place. [offset] is the filter
/// type byte of the first row; each row is [rowBytes] long after it.
void _unfilter(Uint8List b, int offset, int rowBytes, int rows, int bpp) {
  var prev = -1; // Start of the previous row's data, -1 for none.
  for (var y = 0; y < rows; y++) {
    final type = b[offset];
    final row = offset + 1;
    final end = row + rowBytes;
    switch (type) {
      case 0:
        break;
      case 1:
        for (var i = row + bpp; i < end; i++) {
          b[i] = b[i] + b[i - bpp];
        }
      case 2:
        if (prev >= 0) {
          for (var i = 0; i < rowBytes; i++) {
            b[row + i] = b[row + i] + b[prev + i];
          }
        }
      case 3:
        for (var i = 0; i < rowBytes; i++) {
          final left = i >= bpp ? b[row + i - bpp] : 0;
          final up = prev >= 0 ? b[prev + i] : 0;
          b[row + i] = b[row + i] + ((left + up) >> 1);
        }
      case 4:
        for (var i = 0; i < rowBytes; i++) {
          final a = i >= bpp ? b[row + i - bpp] : 0;
          final up = prev >= 0 ? b[prev + i] : 0;
          final c = i >= bpp && prev >= 0 ? b[prev + i - bpp] : 0;
          final p = a + up - c;
          final pa = (p - a).abs();
          final pb = (p - up).abs();
          final pc = (p - c).abs();
          final predictor = pa <= pb && pa <= pc
              ? a
              : pb <= pc
              ? up
              : c;
          b[row + i] = b[row + i] + predictor;
        }
      default:
        _fail();
    }
    prev = row;
    offset = end;
  }
}

/// Converts unfiltered rows to RGBA8 pixels.
final class _Expander {
  _Expander(
    this.h,
    this.raw,
    this.out,
    this.palette,
    this.paletteSize,
    this.keyR,
    this.keyG,
    this.keyB,
  );

  final _Header h;
  final Uint8List raw;
  final Uint8List out;
  final Uint8List? palette;
  final int paletteSize;
  final int? keyR;
  final int? keyG;
  final int? keyB;

  /// Writes [count] pixels from the row data at [src] to [out] starting at
  /// byte [dst], [step] bytes apart.
  void row(int src, int count, int dst, int step) {
    final raw = this.raw;
    final out = this.out;
    switch ((h.colorType, h.bitDepth)) {
      case (6, 8):
        if (step == 4) {
          out.setRange(dst, dst + count * 4, raw, src);
        } else {
          for (var i = 0; i < count; i++, src += 4, dst += step) {
            out[dst] = raw[src];
            out[dst + 1] = raw[src + 1];
            out[dst + 2] = raw[src + 2];
            out[dst + 3] = raw[src + 3];
          }
        }
      case (6, _):
        for (var i = 0; i < count; i++, src += 8, dst += step) {
          out[dst] = raw[src];
          out[dst + 1] = raw[src + 2];
          out[dst + 2] = raw[src + 4];
          out[dst + 3] = raw[src + 6];
        }
      case (4, 8):
        for (var i = 0; i < count; i++, src += 2, dst += step) {
          final g = raw[src];
          out[dst] = g;
          out[dst + 1] = g;
          out[dst + 2] = g;
          out[dst + 3] = raw[src + 1];
        }
      case (4, _):
        for (var i = 0; i < count; i++, src += 4, dst += step) {
          final g = raw[src];
          out[dst] = g;
          out[dst + 1] = g;
          out[dst + 2] = g;
          out[dst + 3] = raw[src + 2];
        }
      case (2, 8):
        final kr = keyR ?? -1, kg = keyG ?? -1, kb = keyB ?? -1;
        for (var i = 0; i < count; i++, src += 3, dst += step) {
          final r = raw[src], g = raw[src + 1], b = raw[src + 2];
          out[dst] = r;
          out[dst + 1] = g;
          out[dst + 2] = b;
          out[dst + 3] = r == kr && g == kg && b == kb ? 0 : 255;
        }
      case (2, _):
        final kr = keyR ?? -1, kg = keyG ?? -1, kb = keyB ?? -1;
        for (var i = 0; i < count; i++, src += 6, dst += step) {
          out[dst] = raw[src];
          out[dst + 1] = raw[src + 2];
          out[dst + 2] = raw[src + 4];
          final key =
              _u16(raw, src) == kr &&
              _u16(raw, src + 2) == kg &&
              _u16(raw, src + 4) == kb;
          out[dst + 3] = key ? 0 : 255;
        }
      case (0, 16):
        final k = keyR ?? -1;
        for (var i = 0; i < count; i++, src += 2, dst += step) {
          final g = raw[src];
          out[dst] = g;
          out[dst + 1] = g;
          out[dst + 2] = g;
          out[dst + 3] = _u16(raw, src) == k ? 0 : 255;
        }
      case (0, final depth):
        final k = keyR ?? -1;
        final mask = (1 << depth) - 1;
        final scale = 255 ~/ mask; // 255, 85, 17 or 1.
        for (var i = 0; i < count; i++, dst += step) {
          final bit = i * depth;
          final v = raw[src + (bit >> 3)] >> (8 - depth - (bit & 7)) & mask;
          final g = v * scale;
          out[dst] = g;
          out[dst + 1] = g;
          out[dst + 2] = g;
          out[dst + 3] = v == k ? 0 : 255;
        }
      case (3, final depth):
        final p = palette!;
        final size = paletteSize;
        final mask = (1 << depth) - 1;
        for (var i = 0; i < count; i++, dst += step) {
          final bit = i * depth;
          final v = raw[src + (bit >> 3)] >> (8 - depth - (bit & 7)) & mask;
          if (v >= size) _fail();
          final e = v * 4;
          out[dst] = p[e];
          out[dst + 1] = p[e + 1];
          out[dst + 2] = p[e + 2];
          out[dst + 3] = p[e + 3];
        }
      default:
        _fail();
    }
  }
}
