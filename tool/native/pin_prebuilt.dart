// Pins a published native release in the hook: rewrites the generated block
// of packages/ghostty_dart/lib/src/native/prebuilt.dart with the release tag
// and the sha256 of every asset (ADR 0008, "Pinning"). The result reaches
// users only through a normal, reviewed PR; this script never commits.
//
// Usage (`mise run native:pin <tag>`):
//   dart tool/native/pin_prebuilt.dart <tag> [--file <prebuilt.dart>] [--repo <owner/repo>]
//   dart tool/native/pin_prebuilt.dart <tag> --no-verify [--sums <path>] [--file ...]
//
// By default (the only mode for real pins) it verifies, with `gh`, failing
// closed on any step:
//   1. the tag's commit, and that it is reachable from main;
//   2. every asset downloaded from the release hashes to its SHA256SUMS line,
//      and SHA256SUMS names exactly native/prebuilt_assets.json;
//   3. the SLSA provenance of every asset and of SHA256SUMS: signed by this
//      repo's reusable native-build.yml, for refs/tags/<tag> at that commit,
//      on a GitHub-hosted runner;
//   4. the release's own immutable-release attestation (`gh release verify`).
// `--no-verify` skips all of that and is for tests only; `--sums` (a local
// SHA256SUMS) requires it. The repository defaults to the one in
// prebuilt.dart's defaultUrlPattern.

import 'dart:convert';
import 'dart:io';

import 'src/pin.dart';

const _defaultFile = 'packages/ghostty_dart/lib/src/native/prebuilt.dart';

Future<void> main(List<String> args) async {
  try {
    await _main(args);
  } on FormatException catch (e) {
    _fail(e.message);
  }
}

Future<void> _main(List<String> args) async {
  final root = File.fromUri(Platform.script).parent.parent.parent.path;
  final options = _Options.parse(args, root);

  final version = _readJson('$root/native/upstream.json')['version']! as String;
  validateTag(options.tag, version);
  final assets =
      (_readJson('$root/native/prebuilt_assets.json')['assets']!
              as Map<String, Object?>)
          .keys
          .toSet();

  final file = File(options.file);
  final source = file.readAsStringSync();
  final repo = options.repo ?? repoFromPrebuilt(source);

  final Map<String, String> sums;
  if (!options.verify) {
    stderr.writeln('warning: --no-verify: nothing is verified (tests only)');
    final String text;
    if (options.sums != null) {
      text = File(options.sums!).readAsStringSync();
    } else {
      text = await _fetch(
        Uri.https(
          'github.com',
          '/$repo/releases/download/${options.tag}/SHA256SUMS',
        ),
      );
    }
    sums = parseSums(text);
    requireAssetSet(sums, assets);
  } else {
    sums = _verifyRelease(repo, options.tag, assets);
  }

  file.writeAsStringSync(replaceBlock(source, renderBlock(options.tag, sums)));
  stdout.writeln(
    'pinned ${options.tag} (${sums.length} assets) in ${options.file}',
  );
}

/// Steps 1-4 of the header; returns the verified sums.
Map<String, String> _verifyRelease(
  String repo,
  String tag,
  Set<String> assets,
) {
  final commit = _run('gh', [
    'api',
    'repos/$repo/commits/$tag',
    '--jq',
    '.sha',
  ]).trim();
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
    throw FormatException('could not resolve the commit of $tag: $commit');
  }
  // compare/<commit>...main is "ahead" or "identical" exactly when the
  // commit is an ancestor of main.
  final status = _run('gh', [
    'api',
    'repos/$repo/compare/$commit...main',
    '--jq',
    '.status',
  ]).trim();
  if (status != 'ahead' && status != 'identical') {
    throw FormatException(
      '$tag ($commit) is not reachable from main (compare: $status)',
    );
  }
  stdout.writeln('tag $tag -> $commit, reachable from main');

  final download = Directory.systemTemp.createTempSync('ghostty-pin-');
  try {
    _run('gh', [
      'release',
      'download',
      tag,
      '--repo',
      repo,
      '--dir',
      download.path,
    ]);
    final sums = parseSums(
      File('${download.path}/SHA256SUMS').readAsStringSync(),
    );
    requireAssetSet(sums, assets);
    final verifyArgs = [
      '--repo',
      repo,
      '--signer-workflow',
      '$repo/.github/workflows/native-build.yml',
      '--source-ref',
      'refs/tags/$tag',
      '--source-digest',
      commit,
      '--deny-self-hosted-runners',
    ];
    for (final name in [...sums.keys, 'SHA256SUMS']) {
      final path = '${download.path}/$name';
      if (name != 'SHA256SUMS' && _sha256(path) != sums[name]) {
        throw FormatException('$name: sha256 differs from SHA256SUMS');
      }
      _run('gh', ['attestation', 'verify', path, ...verifyArgs]);
      stdout.writeln('verified provenance of $name');
    }
    _run('gh', ['release', 'verify', tag, '--repo', repo]);
    stdout.writeln('verified the immutable-release attestation of $tag');
    return sums;
  } finally {
    download.deleteSync(recursive: true);
  }
}

final class _Options {
  _Options(this.tag, this.sums, this.verify, this.file, this.repo);

  factory _Options.parse(List<String> args, String root) {
    String? tag, sums, repo;
    var verify = true;
    var file = '$root/$_defaultFile';
    for (var i = 0; i < args.length; i++) {
      String value() => i + 1 < args.length
          ? args[++i]
          : throw FormatException('${args[i]} needs a value');
      switch (args[i]) {
        case '--sums':
          sums = value();
        case '--no-verify':
          verify = false;
        case '--file':
          file = value();
        case '--repo':
          repo = value();
        case final a when a.startsWith('-'):
          throw FormatException('unknown option $a');
        case final a:
          if (tag != null) throw FormatException('unexpected argument $a');
          tag = a;
      }
    }
    if (tag == null) {
      throw const FormatException(
        'usage: pin_prebuilt.dart <tag> [--no-verify [--sums <path>]] '
        '[--file <prebuilt.dart>] [--repo <owner/repo>]',
      );
    }
    if (sums != null && verify) {
      throw const FormatException(
        '--sums pins unverified hashes; it needs an explicit --no-verify '
        '(tests only)',
      );
    }
    return _Options(tag, sums, verify, file, repo);
  }

  final String tag;
  final String? sums;
  final bool verify;
  final String file;
  final String? repo;
}

Map<String, Object?> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

Future<String> _fetch(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final response = await (await client.getUrl(
      url,
    )).close().timeout(const Duration(minutes: 1));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw FormatException('GET $url: HTTP ${response.statusCode}');
    }
    return body;
  } finally {
    client.close();
  }
}

/// sha256 through the system tool, as tool/native/lib.sh does: this script
/// takes no package dependencies.
String _sha256(String path) {
  ProcessResult result;
  try {
    result = Process.runSync('sha256sum', [path]);
  } on ProcessException {
    result = Process.runSync('shasum', ['-a', '256', path]); // macOS
  }
  if (result.exitCode != 0) {
    throw FormatException('sha256 of $path failed: ${result.stderr}');
  }
  return (result.stdout as String).split(RegExp(r'\s')).first.toLowerCase();
}

String _run(String executable, List<String> args) {
  final result = Process.runSync(executable, args);
  if (result.exitCode != 0) {
    throw FormatException(
      '$executable ${args.join(' ')} failed:\n${result.stdout}${result.stderr}',
    );
  }
  return result.stdout as String;
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}
