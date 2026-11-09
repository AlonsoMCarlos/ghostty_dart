// Pure parts of tool/native/pin_prebuilt.dart: SHA256SUMS parsing, tag and
// asset-set validation, and the generated block of prebuilt.dart. They throw
// FormatException on bad input; tested by tool/native/test/tool_test.dart.

import 'dart:convert';

/// First line of the generated block in prebuilt.dart.
const beginMarker = '// BEGIN GENERATED prebuiltSha256 (mise run native:pin)';

/// Last line of the generated block in prebuilt.dart.
const endMarker = '// END GENERATED prebuiltSha256';

/// Fails unless [tag] is `native-v<version>-r<n>` with n >= 1 (ADR 0008).
void validateTag(String tag, String version) {
  final pattern = RegExp('^native-v${RegExp.escape(version)}-r[1-9][0-9]*\$');
  if (!pattern.hasMatch(tag)) {
    throw FormatException('tag $tag is not native-v$version-r<n> (ADR 0008)');
  }
}

/// Parses sha256sum output (`<hex>  <file>`, or `<hex> *<file>` in binary
/// mode). Rejects malformed lines and duplicate names.
Map<String, String> parseSums(String text) {
  final sums = <String, String>{};
  final line = RegExp(r'^([0-9a-f]{64}) [ *](\S+)$');
  for (final raw in const LineSplitter().convert(text)) {
    final l = raw.trimRight();
    if (l.isEmpty) continue;
    final m = line.firstMatch(l);
    if (m == null) throw FormatException('malformed SHA256SUMS line: $l');
    if (sums.containsKey(m[2])) {
      throw FormatException('duplicate SHA256SUMS entry: ${m[2]}');
    }
    sums[m[2]!] = m[1]!;
  }
  return sums;
}

/// Fails unless [sums] names exactly [assets].
void requireAssetSet(Map<String, String> sums, Set<String> assets) {
  final missing = assets.difference(sums.keys.toSet()).toList()..sort();
  final unknown = sums.keys.toSet().difference(assets).toList()..sort();
  if (missing.isNotEmpty || unknown.isNotEmpty) {
    throw FormatException(
      'SHA256SUMS does not match native/prebuilt_assets.json'
      '${missing.isEmpty ? '' : '; missing: ${missing.join(', ')}'}'
      '${unknown.isEmpty ? '' : '; unknown: ${unknown.join(', ')}'}',
    );
  }
}

/// The generated block, `dart format`-stable: an entry that fits in 80
/// columns stays on one line, a longer one (every real asset name) is split
/// after the key, exactly as the formatter does.
String renderBlock(String tag, Map<String, String> sums) {
  final names = sums.keys.toList()..sort();
  String entry(String n) {
    final line = "  '$n': '${sums[n]}',";
    return line.length <= 80 ? line : "  '$n':\n      '${sums[n]}',";
  }

  final map = names.isEmpty
      ? 'const prebuiltSha256 = <String, String>{};'
      : [
          'const prebuiltSha256 = <String, String>{',
          for (final n in names) entry(n),
          '};',
        ].join('\n');
  return [
    beginMarker,
    '/// Release tag of the pinned prebuilt binaries (`native-v<version>-r<n>`).',
    "const prebuiltReleaseTag = '$tag';",
    '',
    '/// sha256 of each prebuilt binary, keyed by [PrebuiltTarget.fileName].',
    map,
    endMarker,
  ].join('\n');
}

/// Replaces the lines from [beginMarker] to [endMarker] (inclusive) in
/// [source] with [block], keeping the file's line endings.
String replaceBlock(String source, String block) {
  final newline = source.contains('\r\n') ? '\r\n' : '\n';
  final lines = source.split(newline);
  bool isBegin(String l) => l.trimRight() == beginMarker;
  bool isEnd(String l) => l.trimRight() == endMarker;
  if (lines.where(isBegin).length != 1 || lines.where(isEnd).length != 1) {
    throw const FormatException(
      'expected exactly one BEGIN and one END GENERATED prebuiltSha256 marker',
    );
  }
  final begin = lines.indexWhere(isBegin), end = lines.indexWhere(isEnd);
  if (end < begin) throw const FormatException('END marker before BEGIN');
  return [
    ...lines.sublist(0, begin),
    ...block.split('\n'),
    ...lines.sublist(end + 1),
  ].join(newline);
}

/// The `<owner>/<repo>` of the default download URL in prebuilt.dart's
/// `defaultUrlPattern`, so the pin script verifies against the same
/// repository the hook downloads from.
String repoFromPrebuilt(String prebuiltSource) {
  final m = RegExp(
    r'https://github\.com/([\w.-]+/[\w.-]+)/releases/download/',
  ).firstMatch(prebuiltSource);
  if (m == null) {
    throw const FormatException(
      'no github.com release URL (defaultUrlPattern) in prebuilt.dart',
    );
  }
  return m[1]!;
}
