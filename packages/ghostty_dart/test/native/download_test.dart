// The build hook's prebuilt downloader, against a local plain-http server
// through the test-only `PrebuiltFetcher.insecureForTesting` seam. No
// network access.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ghostty_dart/src/native/download.dart';
import 'package:ghostty_dart/src/native/prebuilt.dart';
import 'package:test/test.dart';

const fileName = 'libghostty-vt-linux-x64.so';

/// A local server whose behaviour per request is [handler].
final class TestServer {
  TestServer._(this._server, this.handler) {
    _server.listen((request) async {
      requests++;
      try {
        await handler(request, requests);
      } on IOException {
        // The client hung up (timeout or size cap tests): expected.
      }
    });
  }

  static Future<TestServer> start(
    Future<void> Function(HttpRequest request, int attempt) handler,
  ) async => TestServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    handler,
  );

  final HttpServer _server;

  /// Called for each request with its 1-based count.
  final Future<void> Function(HttpRequest request, int attempt) handler;

  /// Number of requests received.
  int requests = 0;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/$fileName');

  Future<void> close() => _server.close(force: true);
}

Future<void> serve(HttpRequest request, List<int> body) async {
  request.response.add(body);
  await request.response.close();
}

Future<void> redirect(HttpRequest request, String location) async {
  request.response
    ..statusCode = HttpStatus.found
    ..headers.set(HttpHeaders.locationHeader, location);
  await request.response.close();
}

/// Matches an [HttpException] whose message matches [matcher].
Matcher httpFailure(Object matcher) =>
    throwsA(isA<HttpException>().having((e) => e.message, 'message', matcher));

void main() {
  final body = Uint8List.fromList(List.generate(4096, (i) => i % 251));
  final bodySha = sha256.convert(body).toString();
  late Directory cache;
  TestServer? server;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('ghostty_dart_download');
  });
  tearDown(() async {
    await server?.close();
    server = null;
    await cache.delete(recursive: true);
  });

  // Generous limits for the ordinary tests, so slow CI runners do not flake.
  const fetcher = PrebuiltFetcher.insecureForTesting();
  // Short limits, only for the tests that exercise them.
  const impatient = PrebuiltFetcher.insecureForTesting(
    idleTimeout: Duration(milliseconds: 300),
  );

  Future<File> fetch(
    Uri url, {
    PrebuiltFetcher using = fetcher,
    String? pinned,
    String name = fileName,
  }) => using.fetch(
    url: url,
    fileName: name,
    pinnedSha256: pinned ?? bodySha,
    cacheDir: cache.uri,
  );

  /// Files left in the cache, relative to it.
  List<String> cacheContents() => [
    for (final e in cache.listSync(recursive: true))
      if (e is File) e.path.substring(cache.path.length + 1),
  ];

  test('downloads, verifies and caches by hash', () async {
    final s = server = await TestServer.start((r, _) => serve(r, body));
    final file = await fetch(s.url);
    expect(await file.readAsBytes(), body);
    expect(file.path, endsWith('$bodySha${Platform.pathSeparator}$fileName'));
    expect(cacheContents(), hasLength(1));

    final again = await fetch(s.url);
    expect(again.path, file.path);
    expect(s.requests, 1, reason: 'a valid cached file is reused');
  });

  test('replaces a corrupted cached file', () async {
    final s = server = await TestServer.start((r, _) => serve(r, body));
    final first = await fetch(s.url);
    await first.writeAsString('tampered');
    final second = await fetch(s.url);
    expect(await second.readAsBytes(), body);
    expect(s.requests, 2);
  });

  test('production fetcher refuses plain http', () async {
    final s = server = await TestServer.start((r, _) => serve(r, body));
    await expectLater(
      fetch(s.url, using: const PrebuiltFetcher()),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('non-https'),
        ),
      ),
    );
    expect(s.requests, 0);
  });

  group('argument validation', () {
    final url = Uri.parse('https://mirror.example/$fileName');

    test('rejects a hash that is not 64 lowercase hex characters', () async {
      for (final bad in ['', 'abc', bodySha.toUpperCase(), '${bodySha}0']) {
        await expectLater(fetch(url, pinned: bad), throwsArgumentError);
      }
    });

    test('rejects file names that are not plain', () async {
      for (final bad in ['../evil.so', 'a/b.so', r'a\b.so', '..', '', 'a b']) {
        await expectLater(fetch(url, name: bad), throwsArgumentError);
      }
      expect(cacheContents(), isEmpty);
    });
  });

  test('fails closed on a sha256 mismatch and leaves nothing', () async {
    final s = server = await TestServer.start((r, _) => serve(r, body));
    await expectLater(
      fetch(s.url, pinned: '0' * 64),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('sha256 mismatch'), contains(bodySha)),
        ),
      ),
    );
    expect(cacheContents(), isEmpty);
    expect(s.requests, 1, reason: 'a mismatch is never retried');
  });

  test('a 404 names the tag and file and suggests the alternatives', () async {
    final s = server = await TestServer.start((r, _) async {
      r.response.statusCode = HttpStatus.notFound;
      await r.response.close();
    });
    await expectLater(
      fetch(s.url),
      httpFailure(
        allOf([
          contains('HTTP 404'),
          contains(prebuiltReleaseTag),
          contains(fileName),
          contains('url_pattern'),
          contains('source: path'),
          contains('source: system'),
        ]),
      ),
    );
    expect(s.requests, 1, reason: '4xx is not retried');
    expect(cacheContents(), isEmpty);
  });

  test('messages redact user info and query', () async {
    final s = server = await TestServer.start((r, _) async {
      r.response.statusCode = HttpStatus.forbidden;
      await r.response.close();
    });
    final secret = s.url.replace(
      userInfo: 'user:hunter2',
      query: 'token=hunter2',
    );
    await expectLater(
      fetch(secret),
      throwsA(
        isA<HttpException>()
            .having((e) => e.message, 'message', isNot(contains('hunter2')))
            .having((e) => '${e.uri}', 'uri', isNot(contains('hunter2')))
            .having((e) => e.message, 'message', contains(s.url.path)),
      ),
    );
    expect(redactUrl(secret), s.url);
  });

  test('retries once on 503', () async {
    final s = server = await TestServer.start((r, attempt) async {
      if (attempt == 1) {
        r.response.statusCode = HttpStatus.serviceUnavailable;
        await r.response.close();
      } else {
        await serve(r, body);
      }
    });
    final file = await fetch(s.url);
    expect(await file.readAsBytes(), body);
    expect(s.requests, 2);
  });

  test('gives up after the retry on repeated 5xx', () async {
    final s = server = await TestServer.start((r, _) async {
      r.response.statusCode = HttpStatus.badGateway;
      await r.response.close();
    });
    await expectLater(
      fetch(s.url),
      httpFailure(allOf(contains('HTTP 502'), contains('url_pattern'))),
    );
    expect(s.requests, 2);
  });

  test('retries a body shorter than its Content-Length', () async {
    final s = server = await TestServer.start((r, attempt) async {
      if (attempt == 1) {
        r.response
          ..contentLength = body.length
          ..add(body.sublist(0, 100));
        // Closing short of Content-Length drops the connection.
        await r.response.close();
      } else {
        await serve(r, body);
      }
    });
    final file = await fetch(s.url);
    expect(await file.readAsBytes(), body);
    expect(s.requests, 2);
  });

  group('redirects', () {
    test('are followed', () async {
      final s = server = await TestServer.start((r, _) async {
        if (r.uri.path == '/$fileName') return redirect(r, '/real/$fileName');
        await serve(r, body);
      });
      final file = await fetch(s.url);
      expect(await file.readAsBytes(), body);
      expect(s.requests, 2);
    });

    test('to a disallowed scheme are refused', () async {
      final s = server = await TestServer.start(
        (r, _) => redirect(r, 'ftp://mirror.example/$fileName'),
      );
      await expectLater(
        fetch(s.url),
        httpFailure(contains('redirected to a non-https URL')),
      );
      expect(s.requests, 1, reason: 'not retried');
    });

    test('stop after ${PrebuiltFetcher.maxRedirects} hops', () async {
      final s = server = await TestServer.start(
        (r, n) => redirect(r, '/hop$n/$fileName'),
      );
      await expectLater(
        fetch(s.url),
        httpFailure(contains('more than ${PrebuiltFetcher.maxRedirects}')),
      );
      expect(s.requests, PrebuiltFetcher.maxRedirects + 1);
    });
  });

  group('timeouts', () {
    test('a stalled body times out, is retried, then fails', () async {
      // Kept so the stalled responses are not closed until tearDown.
      final stalled = <HttpResponse>[];
      final s = server = await TestServer.start((r, _) async {
        r.response
          ..contentLength = body.length
          ..add(body.sublist(0, 100));
        await r.response.flush();
        stalled.add(r.response);
      });
      await expectLater(
        fetch(s.url, using: impatient),
        httpFailure(allOf(contains('timed out'), contains(fileName))),
      );
      expect(s.requests, 2);
      expect(cacheContents(), isEmpty);
    });

    test('headers that never arrive time out', () async {
      final s = server = await TestServer.start((r, _) async {});
      await expectLater(
        fetch(s.url, using: impatient),
        httpFailure(contains('timed out')),
      );
      expect(s.requests, 2);
    });

    test('a trickling body hits the per-attempt deadline', () async {
      const deadline = PrebuiltFetcher.insecureForTesting(
        idleTimeout: Duration(seconds: 5),
        attemptTimeout: Duration(milliseconds: 600),
      );
      final s = server = await TestServer.start((r, _) async {
        r.response
          ..bufferOutput = false
          ..contentLength = body.length;
        for (var i = 0; i < body.length; i += 16) {
          r.response.add(body.sublist(i, i + 16));
          await r.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await r.response.close();
      });
      await expectLater(
        fetch(s.url, using: deadline),
        httpFailure(contains('timed out')),
      );
      expect(s.requests, 2);
      expect(cacheContents(), isEmpty);
    });
  });

  test('a refused connection suggests the alternatives', () async {
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = Uri.parse('http://127.0.0.1:${closed.port}/$fileName');
    await closed.close(force: true);
    await expectLater(
      fetch(url),
      httpFailure(
        allOf([
          contains('connection failed'),
          contains(prebuiltReleaseTag),
          contains('source: path'),
        ]),
      ),
    );
  });

  test('an unexpected local error keeps the guidance', () async {
    final s = server = await TestServer.start((r, _) => serve(r, body));
    // A directory where the .part file goes makes openWrite fail.
    await Directory(
      '${cache.path}/$bodySha/$fileName.part',
    ).create(recursive: true);
    await expectLater(
      fetch(s.url),
      httpFailure(allOf(contains('unexpected error'), contains('url_pattern'))),
    );
  });

  group('size cap', () {
    const small = PrebuiltFetcher.insecureForTesting(maxBytes: 1024);

    test('rejects a declared Content-Length above the cap', () async {
      final s = server = await TestServer.start((r, _) async {
        r.response.contentLength = body.length;
        await serve(r, body);
      });
      await expectLater(
        fetch(s.url, using: small),
        httpFailure(contains('1024-byte limit')),
      );
      expect(s.requests, 1);
      expect(cacheContents(), isEmpty);
    });

    test('stops a chunked body that exceeds the cap', () async {
      final s = server = await TestServer.start((r, _) async {
        r.response.bufferOutput = false;
        for (var i = 0; i < 8; i++) {
          r.response.add(body.sublist(0, 512));
          await r.response.flush();
        }
        await r.response.close();
      });
      await expectLater(
        fetch(s.url, using: small),
        httpFailure(contains('more than 1024 bytes')),
      );
      expect(s.requests, 1);
      expect(cacheContents(), isEmpty);
    });
  });
}
