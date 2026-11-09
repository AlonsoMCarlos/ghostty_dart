/// The measuring side: one fresh process per engine × workload × task, so a
/// JIT profile, heap growth or native allocation from one engine never
/// affects another.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'engines.dart';
import 'workloads.dart';

/// Options a worker process receives from the orchestrator.
final class WorkerOptions {
  const WorkerOptions({
    required this.engine,
    required this.workload,
    required this.bytes,
    required this.runs,
    required this.warmup,
    required this.chunkSizes,
    required this.task,
    this.screenPath,
  });

  /// Parses `--key=value` arguments.
  factory WorkerOptions.parse(Map<String, String> a) => WorkerOptions(
    engine: a['engine']!,
    workload: a['workload']!,
    bytes: int.parse(a['bytes']!),
    runs: int.parse(a['runs']!),
    warmup: int.parse(a['warmup']!),
    chunkSizes: a['chunks']!.split(',').map(int.parse).toList(),
    task: a['task']!,
    screenPath: a['screen'],
  );

  final String engine;
  final String workload;
  final int bytes;
  final int runs;
  final int warmup;
  final List<int> chunkSizes;

  /// `throughput` or `memory`.
  final String task;

  /// Where to write the final visible screen as JSON (throughput only).
  final String? screenPath;

  /// The same options as command-line arguments.
  List<String> toArgs() => [
    '--engine=$engine',
    '--workload=$workload',
    '--bytes=$bytes',
    '--runs=$runs',
    '--warmup=$warmup',
    '--chunks=${chunkSizes.join(',')}',
    '--task=$task',
    if (screenPath != null) '--screen=$screenPath',
  ];
}

/// Splits [data] into pty-sized chunks of [size] bytes (views, no copies).
/// Like a real pty read, boundaries ignore UTF-8 and escape sequences.
List<Uint8List> chunk(Uint8List data, int size) => [
  for (var i = 0; i < data.length; i += size)
    Uint8List.sublistView(
      data,
      i,
      i + size > data.length ? data.length : i + size,
    ),
];

/// Decodes [chunks] like an app's `utf8.decoder` stream transformer does:
/// a multi-byte sequence split across chunks is completed in the next one.
List<String> decodeChunks(List<Uint8List> chunks) {
  final out = <String>[];
  final sink = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(_ListSink(out));
  for (final c in chunks) {
    sink.add(c);
  }
  sink.close();
  return out;
}

final class _ListSink implements Sink<String> {
  _ListSink(this.out);
  final List<String> out;
  @override
  void add(String data) {
    if (data.isNotEmpty) out.add(data);
  }

  @override
  void close() {}
}

final class _EngineSink implements Sink<String> {
  _EngineSink(this.engine);
  final Engine engine;
  @override
  void add(String data) {
    if (data.isNotEmpty) engine.writeString(data);
  }

  @override
  void close() {}
}

/// How input reaches the engine.
enum Feed {
  /// Raw pty bytes (ghostty_dart).
  bytes,

  /// Bytes decoded with a chunked UTF-8 decoder inside the timed loop:
  /// what an app using flutter_pty or dartssh2 pays end to end.
  decode,

  /// Strings decoded before timing: the parser alone.
  text,
}

/// Feeds the whole workload to [engine], calling [afterChunk] (if any) after
/// each chunk.
void _feed(
  Engine engine,
  Feed feed,
  List<Uint8List> chunks,
  List<String>? strings, {
  void Function()? afterChunk,
}) {
  switch (feed) {
    case Feed.bytes:
      for (final c in chunks) {
        engine.writeBytes(c);
        afterChunk?.call();
      }
    case Feed.decode:
      final sink = const Utf8Decoder(
        allowMalformed: true,
      ).startChunkedConversion(_EngineSink(engine));
      for (final c in chunks) {
        sink.add(c);
        afterChunk?.call();
      }
      sink.close();
    case Feed.text:
      for (final s in strings!) {
        engine.writeString(s);
        afterChunk?.call();
      }
  }
}

/// Runs the worker task and prints one JSON line with the results.
void runWorker(WorkerOptions o) {
  final data = workloadNamed(o.workload).generate(o.bytes);
  final probe = createEngine(o.engine);
  final takesBytes = probe.takesBytes;
  probe.dispose();
  final feeds = takesBytes ? [Feed.bytes] : [Feed.decode, Feed.text];

  if (o.task == 'memory') {
    final chunks = chunk(data, o.chunkSizes.last);
    final feed = feeds.first;
    final rssBefore = ProcessInfo.currentRss;
    final engine = createEngine(o.engine);
    // Sample RSS after every chunk for the peak. `ProcessInfo.maxRss` is no
    // use here: Linux carries ru_maxrss over from the parent process (the
    // orchestrator) across fork and exec.
    var peak = rssBefore;
    _feed(
      engine,
      feed,
      chunks,
      null,
      afterChunk: () {
        final rss = ProcessInfo.currentRss;
        if (rss > peak) peak = rss;
      },
    );
    final rssAfter = ProcessInfo.currentRss;
    // Keep the engine reachable until after the measurement.
    final rows = engine.screen().length;
    engine.dispose();
    stdout.writeln(
      jsonEncode({
        'engine': o.engine,
        'workload': o.workload,
        'bytes': data.length,
        'feed': feed.name,
        'chunk': o.chunkSizes.last,
        'rssBefore': rssBefore,
        'rssAfter': rssAfter,
        'rssPeak': peak,
        'rows': rows,
      }),
    );
    return;
  }

  final results = <Map<String, Object?>>[];
  List<String>? firstScreen;
  var chunkingConsistent = true;
  for (final size in o.chunkSizes) {
    final chunks = chunk(data, size);
    final strings = takesBytes ? null : decodeChunks(chunks);
    for (final feed in feeds) {
      final times = <int>[];
      for (var run = 0; run < o.warmup + o.runs; run++) {
        // Construction is outside the timed region: only input is measured.
        final engine = createEngine(o.engine);
        final sw = Stopwatch()..start();
        _feed(engine, feed, chunks, strings);
        sw.stop();
        if (run >= o.warmup) times.add(sw.elapsedMicroseconds);
        if (run == o.warmup + o.runs - 1) {
          final screen = engine.screen();
          if (firstScreen == null) {
            firstScreen = screen;
          } else if (!_listEquals(firstScreen, screen)) {
            chunkingConsistent = false;
          }
        }
        engine.dispose();
      }
      results.add({'chunk': size, 'feed': feed.name, 'micros': times});
    }
  }
  if (o.screenPath != null) {
    File(o.screenPath!).writeAsStringSync(jsonEncode(firstScreen));
  }
  stdout.writeln(
    jsonEncode({
      'engine': o.engine,
      'workload': o.workload,
      'bytes': data.length,
      'chunkingConsistent': chunkingConsistent,
      'results': results,
    }),
  );
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
