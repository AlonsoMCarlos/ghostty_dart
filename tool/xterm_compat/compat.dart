// Generates packages/ghostty_dart_xterm/COMPATIBILITY.md (ADR 0013,
// "Evidence"): xterm 4.0.0's public API against the adapter's.
//
//   dart tool/xterm_compat/compat.dart snapshot   # mise run compat:snapshot
//   dart tool/xterm_compat/compat.dart write      # mise run compat
//   dart tool/xterm_compat/compat.dart check      # mise run compat:check
//
// `snapshot` reads xterm 4.0.0 from the workspace's locked copy, after the
// fail-closed pins of src/pin.dart, and writes xterm-4.0.0.api.json (commit
// it after review, like `native:pin`). `write` and `check` never read xterm:
// they read that snapshot, the adapter's sources (analyzer, no compilation)
// and status.json, and need no network. `check` fails if COMPATIBILITY.md is
// not what `write` would produce, or if status.json is inconsistent.
// Run `mise run deps` first: the analyzer resolves through the workspace's
// .dart_tool/package_config.json.
// Tests: tool/test/xterm_compat_test.dart (`mise run test:tool`).

import 'dart:convert';
import 'dart:io';

import 'src/compare.dart';
import 'src/extract.dart';
import 'src/model.dart';
import 'src/pin.dart';
import 'src/report.dart';

/// Paths relative to the repository root.
const snapshotPath = 'tool/xterm_compat/xterm-4.0.0.api.json';
const statusPath = 'tool/xterm_compat/status.json';
const reportPath = 'packages/ghostty_dart_xterm/COMPATIBILITY.md';

Future<void> main(List<String> args) async {
  final root = Platform.script
      .resolve('../..')
      .toFilePath()
      .replaceFirst(RegExp(r'[/\\]$'), '');
  final command = args.length == 1 ? args.single : '';
  try {
    switch (command) {
      case 'snapshot':
        await _snapshot(root);
      case 'write':
        final report = await buildReport(root);
        File('$root/$reportPath').writeAsStringSync(report);
        stdout.writeln('compat: wrote $reportPath');
      case 'check':
        final report = await buildReport(root);
        final file = File('$root/$reportPath');
        if (!isCurrent(file, report)) {
          stderr.writeln(
            'compat: $reportPath is stale; run `mise run compat` and commit '
            'the result',
          );
          exitCode = 1;
          return;
        }
        stdout.writeln('compat: $reportPath is up to date');
      default:
        stderr.writeln('usage: compat.dart snapshot|write|check');
        exitCode = 64;
    }
  } on PinError catch (e) {
    stderr.writeln('compat: pin check failed: $e');
    exitCode = 1;
  } on StatusError catch (e) {
    stderr.writeln('compat: $statusPath is inconsistent:');
    for (final p in e.problems) {
      stderr.writeln('  $p');
    }
    exitCode = 1;
  } on ExtractError catch (e) {
    stderr.writeln('compat: $e');
    exitCode = 1;
  } on FormatException catch (e) {
    stderr.writeln('compat: $e');
    exitCode = 1;
  }
}

Map<String, String> _uris(String package) => {
  for (final lib in libraryOrder) lib: 'package:$package/$lib',
};

Future<void> _snapshot(String root) async {
  final dir = verifyXterm(root);
  final model = await extractApi(
    analysisRoot: '$root/tool/xterm_compat',
    libraries: _uris('xterm'),
    ownUriPrefix: 'package:xterm/',
    requireAll: true,
  );
  // The sources must not have changed while the analyzer read them.
  if (libTreeSha256(Directory('${dir.path}/lib')) != xtermLibSha256) {
    throw PinError('${dir.path}/lib changed during the snapshot');
  }
  final text = encodeSnapshot(model);
  if (text.contains('InvalidType')) {
    throw ExtractError(
      'the snapshot has unresolved types (InvalidType); is the workspace '
      'resolved (`mise run deps`)?',
    );
  }
  File('$root/$snapshotPath').writeAsStringSync(text);
  stdout.writeln(
    'compat: wrote $snapshotPath (${model.symbols.length} symbols, '
    '${model.size - model.symbols.length} members)',
  );
}

/// The snapshot file: the pins it was taken under, then the API.
String encodeSnapshot(ApiModel model) =>
    '${const JsonEncoder.withIndent('  ').convert({'xterm': xtermVersion, 'archiveSha256': xtermArchiveSha256, 'libSha256': xtermLibSha256, 'symbols': model.toJson()})}\n';

/// Reads a snapshot written by [encodeSnapshot]. Throws [PinError] when it
/// was taken under other pins than the ones in source.
ApiModel decodeSnapshot(String text) {
  final json = jsonDecode(text) as Map<String, Object?>;
  if (json['xterm'] != xtermVersion ||
      json['archiveSha256'] != xtermArchiveSha256 ||
      json['libSha256'] != xtermLibSha256) {
    throw PinError(
      '$snapshotPath was not taken from the pinned xterm $xtermVersion; '
      'run `mise run compat:snapshot`',
    );
  }
  return ApiModel.fromJson(json['symbols']! as Map<String, Object?>);
}

/// COMPATIBILITY.md as `write` produces it, for the workspace at [root].
Future<String> buildReport(String root) => renderFor(
  xterm: decodeSnapshot(File('$root/$snapshotPath').readAsStringSync()),
  analysisRoot: '$root/tool/xterm_compat',
  ourLibraries: _uris('ghostty_dart_xterm'),
  ourUriPrefix: 'package:ghostty_dart_xterm/',
  statusText: File('$root/$statusPath').readAsStringSync(),
);

/// Reads our API from [ourLibraries], merges [statusText] and renders the
/// report. Throws [StatusError] when the status file is inconsistent.
Future<String> renderFor({
  required ApiModel xterm,
  required String analysisRoot,
  required Map<String, String> ourLibraries,
  required String ourUriPrefix,
  required String statusText,
}) async {
  final status = parseStatus(statusText);
  final ours = await extractApi(
    analysisRoot: analysisRoot,
    libraries: ourLibraries,
    ownUriPrefix: ourUriPrefix,
    keepForeign: true,
  );
  return renderReport(compare(xterm, ours, status));
}

/// Whether [file] holds exactly [report].
bool isCurrent(File file, String report) =>
    file.existsSync() && file.readAsStringSync() == report;
