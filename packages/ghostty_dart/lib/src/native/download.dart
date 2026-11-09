/// Download of the pinned prebuilt libghostty-vt binary, for
/// `hook/build.dart`. Kept out of the hook so it can be tested against a
/// local server. Must not import `dart:ffi` and is not exported by any
/// barrel.
///
/// Security properties (AGENTS.md, "Supply chain"):
/// - only `https`, for the first URL and for every redirect hop (the
///   test-only constructor also accepts `http`);
/// - the file is written to `<name>.part`, its sha256 is checked against the
///   pinned value, and only then renamed into place: fail closed;
/// - the download never runs anything; the size is capped before hashing;
/// - error messages show URLs without user info, query or fragment, so a
///   token in a private `url_pattern` does not reach build logs.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'prebuilt.dart';

/// Fetches a prebuilt binary into a cache keyed by its pinned sha256.
///
/// Holds the network limits (timeouts, size cap) and the retry policy: one
/// retry on transient failures (connection errors, timeouts, HTTP 5xx).
/// [fetch] documents the errors.
final class PrebuiltFetcher {
  /// Creates the production fetcher, which only accepts `https` URLs.
  const PrebuiltFetcher({
    this.connectTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 60),
    this.attemptTimeout = const Duration(minutes: 10),
    this.maxBytes = defaultMaxBytes,
    this.retryDelay = const Duration(seconds: 2),
  }) : _allowInsecureHttp = false;

  /// Test-only seam: also accepts plain `http` URLs and redirects, so tests
  /// can use a local [HttpServer] without TLS. Never used by the hook (a
  /// test checks the hook's source).
  const PrebuiltFetcher.insecureForTesting({
    this.connectTimeout = const Duration(seconds: 5),
    this.idleTimeout = const Duration(seconds: 5),
    this.attemptTimeout = const Duration(seconds: 30),
    this.maxBytes = defaultMaxBytes,
    this.retryDelay = Duration.zero,
  }) : _allowInsecureHttp = true;

  /// Default [maxBytes]: 64 MiB, well above any release asset (a stripped
  /// build is a few MiB), but bounded so a hostile mirror cannot fill the
  /// disk before the hash check.
  static const defaultMaxBytes = 64 * 1024 * 1024;

  /// Most redirect hops followed, matching dart:io's default.
  static const maxRedirects = 5;

  static const _maxAttempts = 2;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final _fileNamePattern = RegExp(r'^[A-Za-z0-9._-]+$');

  /// Limit for establishing each connection.
  final Duration connectTimeout;

  /// Limit for waiting on the response headers and between body chunks.
  final Duration idleTimeout;

  /// Limit for one whole attempt, redirects and body included, so a mirror
  /// that trickles bytes just under [idleTimeout] cannot hold the build.
  final Duration attemptTimeout;

  /// Largest accepted download, in bytes.
  final int maxBytes;

  /// Pause before the single retry.
  final Duration retryDelay;

  final bool _allowInsecureHttp;

  /// Returns the cached binary `cacheDir/<pinnedSha256>/<fileName>`,
  /// downloading it from [url] first when it is missing or does not match
  /// [pinnedSha256].
  ///
  /// Errors:
  /// - [ArgumentError]: [pinnedSha256] is not 64 lowercase hex characters,
  ///   or [fileName] is not a plain file name (`[A-Za-z0-9._-]+`, no `..`).
  /// - [FormatException]: [url] is not `https`.
  /// - [HttpException]: any download failure (HTTP status, redirect to a
  ///   non-https URL or too many redirects, timeout, connection or TLS
  ///   error, size cap, local I/O). The message names the release tag
  ///   ([prebuiltReleaseTag]), the file name and the redacted URL, and lists
  ///   the `url_pattern`, `path` and `system` alternatives.
  /// - [StateError]: the downloaded file does not match [pinnedSha256]. It
  ///   is deleted and never retried: a mismatch is a loud, distinct failure.
  Future<File> fetch({
    required Uri url,
    required String fileName,
    required String pinnedSha256,
    required Uri cacheDir,
  }) async {
    if (!_sha256Pattern.hasMatch(pinnedSha256)) {
      throw ArgumentError.value(
        pinnedSha256,
        'pinnedSha256',
        'must be 64 lowercase hex characters',
      );
    }
    if (!_fileNamePattern.hasMatch(fileName) || fileName.contains('..')) {
      throw ArgumentError.value(
        fileName,
        'fileName',
        'must be a plain file name ([A-Za-z0-9._-]+, no "..")',
      );
    }
    if (!_isAllowedScheme(url)) {
      throw FormatException(
        'ghostty_dart: refusing non-https url_pattern: ${redactUrl(url)}',
      );
    }
    final cached = File.fromUri(cacheDir.resolve('$pinnedSha256/$fileName'));
    if (cached.existsSync()) {
      if (await _sha256Of(cached) == pinnedSha256) return cached;
      await cached.delete();
    }
    await cached.parent.create(recursive: true);
    final partial = File('${cached.path}.part');
    try {
      await _downloadWithRetry(url, fileName, partial);
      final actual = await _sha256Of(partial);
      if (actual != pinnedSha256) {
        throw StateError(
          'ghostty_dart: sha256 mismatch for ${redactUrl(url)}\n'
          '  expected $pinnedSha256\n  actual   $actual\n'
          'The file was discarded. If you use a mirror (url_pattern), it is '
          'serving a different file than release $prebuiltReleaseTag.',
        );
      }
      return await partial.rename(cached.path);
    } finally {
      if (partial.existsSync()) await partial.delete();
    }
  }

  bool _isAllowedScheme(Uri url) =>
      url.scheme == 'https' || (_allowInsecureHttp && url.scheme == 'http');

  Future<void> _downloadWithRetry(
    Uri url,
    String fileName,
    File partial,
  ) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await _download(url, partial);
        return;
      } on Object catch (e) {
        final failure = _classify(e);
        if (failure == null) rethrow;
        if (!failure.retryable || attempt == _maxAttempts) {
          final shown = redactUrl(url);
          throw HttpException(
            'ghostty_dart: could not download the prebuilt libghostty-vt '
            '$targetLibghosttyVtVersion for release $prebuiltReleaseTag, '
            'file $fileName, from $shown: ${failure.reason}.\n'
            '${prebuiltAlternativesHint(includeUrlPattern: true)}',
            uri: shown,
          );
        }
      }
      if (retryDelay > Duration.zero) await Future<void>.delayed(retryDelay);
    }
  }

  /// Maps an error of one attempt to a reason and whether a retry may help.
  /// Returns `null` for programming errors, which propagate unchanged.
  static _Failure? _classify(Object e) => switch (e) {
    final _Failure failure => failure,
    // Not transient. Typical behind a TLS-intercepting proxy, whose CA the
    // hook does not trust.
    TlsException(:final message) => _Failure(
      'TLS failed: $message',
      retryable: false,
    ),
    TimeoutException() => const _Failure('timed out', retryable: true),
    SocketException(:final message, :final osError) => _Failure(
      'connection failed: $message${_osError(osError)}',
      retryable: true,
    ),
    // dart:io raises this when a connection breaks mid-response. Its
    // toString would print the full URL, so only the message is kept.
    HttpException(:final message) => _Failure(
      'connection failed: $message',
      retryable: true,
    ),
    // Anything else expected from I/O or a malformed URL (for example a
    // FileSystemException writing the .part file): not retried, but still
    // reported with the guidance.
    Exception() ||
    ArgumentError() => _Failure('unexpected error: $e', retryable: false),
    _ => null,
  };

  static String _osError(OSError? error) =>
      error == null ? '' : ' (${error.message}, errno ${error.errorCode})';

  Future<void> _download(Uri url, File partial) async {
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      // Already dart:io's default (http_impl.dart, Dart 3.13.7); set
      // explicitly because the hook relies on it: HTTPS_PROXY / NO_PROXY,
      // which hooks_runner forwards to the hook.
      ..findProxy = HttpClient.findProxyFromEnvironment;
    var deadlineHit = false;
    final deadline = Timer(attemptTimeout, () {
      deadlineHit = true;
      client.close(force: true);
    });
    try {
      await _downloadWith(client, url, partial);
      // A forced close can end the body early instead of failing it.
      if (deadlineHit) throw TimeoutException('attempt deadline');
    } on Object {
      if (deadlineHit) throw TimeoutException('attempt deadline');
      rethrow;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  Future<void> _downloadWith(HttpClient client, Uri url, File partial) async {
    var current = url;
    for (var hops = 0; ; hops++) {
      final request = await client.getUrl(current).timeout(connectTimeout);
      request.followRedirects = false;
      final response = await request.close().timeout(idleTimeout);
      final status = response.statusCode;
      if (response.isRedirect) {
        // Drop the redirect body and its connection.
        await response.listen(null).cancel();
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) {
          throw _Failure('HTTP $status without a Location', retryable: false);
        }
        if (hops == maxRedirects) {
          throw const _Failure(
            'more than $maxRedirects redirects',
            retryable: false,
          );
        }
        final next = current.resolve(location);
        if (!_isAllowedScheme(next)) {
          throw _Failure(
            'redirected to a non-https URL (${next.scheme}:)',
            retryable: false,
          );
        }
        current = next;
        continue;
      }
      if (status != HttpStatus.ok) {
        // The body is not read: closing the client discards it.
        throw _Failure(
          'HTTP $status ${response.reasonPhrase}',
          retryable: status >= 500,
        );
      }
      await _writeBody(response, partial);
      return;
    }
  }

  Future<void> _writeBody(HttpClientResponse response, File partial) async {
    final declared = response.contentLength;
    if (declared > maxBytes) {
      throw _Failure(_tooLarge('declares $declared bytes'), retryable: false);
    }
    final sink = partial.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(idleTimeout)) {
        received += chunk.length;
        if (received > maxBytes) {
          throw _Failure(
            _tooLarge('sent more than $maxBytes bytes'),
            retryable: false,
          );
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (declared >= 0 && received != declared) {
      throw _Failure(
        'the response ended after $received of $declared bytes',
        retryable: true,
      );
    }
  }

  String _tooLarge(String what) =>
      'the response $what, above the $maxBytes-byte limit';
}

/// A classified download failure.
final class _Failure implements Exception {
  const _Failure(this.reason, {required this.retryable});
  final String reason;
  final bool retryable;
}

/// [url] without user info, query or fragment, for error messages: a
/// private `url_pattern` may carry a token in either.
Uri redactUrl(Uri url) {
  final host = url.host.contains(':') ? '[${url.host}]' : url.host;
  final port = url.hasPort ? ':${url.port}' : '';
  return Uri.parse('${url.scheme}://$host$port${url.path}');
}

Future<String> _sha256Of(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
