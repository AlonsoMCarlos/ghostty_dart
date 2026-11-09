/// Collects worker results and renders them as Markdown.
library;

import 'orchestrator.dart';
import 'workloads.dart';

/// Workloads whose screens must be identical across engines. The others
/// exercise areas where engines legitimately differ (grapheme clustering,
/// emoji width, scroll-region edge cases) and are reported, not enforced.
const requiredAgreement = {'ascii', 'sgr'};

/// Versions under test; they must match the exact pins in pubspec.yaml.
const engineVersions = {
  'ghostty_dart': 'ghostty_dart (workspace)',
  'xterm': 'xterm 4.0.0',
  'xterm2_core': 'xterm2_core 1.0.0',
};

/// The accumulated results of one benchmark run.
final class Report {
  Report(this.options, {required this.machineInfo});

  final BenchOptions options;
  final Map<String, String> machineInfo;

  // runtime -> workload -> engine -> worker JSON
  final _throughput =
      <String, Map<String, Map<String, Map<String, Object?>>>>{};
  final _screens = <String, Map<String, Map<String, List<String>>>>{};
  final _memory = <String, Map<String, Map<String, Map<String, Object?>>>>{};

  /// Records a throughput worker's result and final screen.
  void addThroughput(
    String runtime,
    Map<String, Object?> r,
    List<String> screen,
  ) {
    final w = r['workload']! as String;
    final e = r['engine']! as String;
    ((_throughput[runtime] ??= {})[w] ??= {})[e] = r;
    ((_screens[runtime] ??= {})[w] ??= {})[e] = screen;
  }

  /// Records a memory worker's result.
  void addMemory(String runtime, Map<String, Object?> r) {
    final w = r['workload']! as String;
    final e = r['engine']! as String;
    ((_memory[runtime] ??= {})[w] ??= {})[e] = r;
  }

  /// Whether a [requiredAgreement] workload's screens differ between engines.
  bool get hasRequiredMismatch {
    for (final byWorkload in _screens.values) {
      for (final MapEntry(key: w, value: byEngine) in byWorkload.entries) {
        if (!requiredAgreement.contains(w)) continue;
        final screens = byEngine.values.toList();
        for (var i = 1; i < screens.length; i++) {
          if (_diff(screens[0], screens[i]) != null) return true;
        }
      }
    }
    return false;
  }

  /// The full report.
  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('## Machine')
      ..writeln()
      ..writeln('| | |')
      ..writeln('|---|---|');
    for (final MapEntry(:key, :value) in machineInfo.entries) {
      b.writeln('| $key | ${value.replaceAll('|', '/')} |');
    }
    b
      ..writeln()
      ..writeln('## Settings')
      ..writeln()
      ..writeln(
        '- Engines: ${options.engines.map((e) => engineVersions[e] ?? e).join(', ')}',
      )
      ..writeln(
        '- Terminal: ${benchCols}x$benchRows, $benchScrollback scrollback lines',
      )
      ..writeln(
        '- Workload size: ${options.mib} MiB each; chunk sizes: '
        '${options.chunkSizes.map(_size).join(', ')}',
      )
      ..writeln(
        '- ${options.warmup} warm-up + ${options.runs} measured runs per cell; '
        'median shown. MB/s = 10^6 bytes of pty input per second.',
      )
      ..writeln();

    for (final MapEntry(key: runtime, value: byWorkload)
        in _throughput.entries) {
      _throughputTable(b, runtime, byWorkload);
    }
    for (final MapEntry(key: runtime, value: byWorkload) in _memory.entries) {
      _memoryTable(b, runtime, byWorkload);
    }
    _correctness(b);
    return b.toString();
  }

  void _throughputTable(
    StringBuffer b,
    String runtime,
    Map<String, Map<String, Map<String, Object?>>> byWorkload,
  ) {
    // Column = engine + feed, in a stable order.
    final columns = <(String, String)>[];
    for (final e in options.engines) {
      if (e == 'ghostty_dart') {
        columns.add((e, 'bytes'));
      } else {
        columns
          ..add((e, 'decode'))
          ..add((e, 'text'));
      }
    }
    final hasGhostty = options.engines.contains('ghostty_dart');
    b
      ..writeln('## Throughput — ${runtime.toUpperCase()}')
      ..writeln()
      ..writeln(
        '`bytes`: raw pty bytes. `decode`: UTF-8 decoding inside the timed loop '
        '(end to end, as apps do). `text`: pre-decoded strings (parser only).',
      )
      ..writeln();
    b.write('| Workload | Chunk |');
    for (final (e, f) in columns) {
      b.write(' $e ($f) |');
    }
    if (hasGhostty) b.write(' ghostty_dart vs fastest other, end to end |');
    b
      ..writeln()
      ..write('|---|---:|');
    for (final _ in columns) {
      b.write('---:|');
    }
    if (hasGhostty) b.write('---:|');
    b.writeln();

    for (final w in options.workloadNames) {
      final byEngine = byWorkload[w];
      if (byEngine == null) continue;
      for (final chunk in options.chunkSizes) {
        b.write('| $w | ${_size(chunk)} |');
        double? ghostty;
        double? bestOther;
        for (final (e, f) in columns) {
          final r = byEngine[e];
          final micros = r == null ? null : _median(r, chunk, f);
          if (micros == null) {
            b.write(' – |');
            continue;
          }
          final bytes = r!['bytes']! as int;
          final mbs = bytes / micros; // bytes per µs == MB/s
          b.write(
            ' ${mbs.toStringAsFixed(1)} MB/s · '
            '${(micros / 1000).toStringAsFixed(0)} ms |',
          );
          if (e == 'ghostty_dart') {
            ghostty = mbs;
          } else if (f == 'decode' && (bestOther == null || mbs > bestOther)) {
            bestOther = mbs;
          }
        }
        if (hasGhostty) {
          b.write(
            ghostty != null && bestOther != null
                ? ' ${(ghostty / bestOther).toStringAsFixed(1)}× |'
                : ' – |',
          );
        }
        b.writeln();
      }
    }
    b.writeln();
  }

  void _memoryTable(
    StringBuffer b,
    String runtime,
    Map<String, Map<String, Map<String, Object?>>> byWorkload,
  ) {
    b
      ..writeln('## Memory — ${runtime.toUpperCase()}, fresh process per cell')
      ..writeln()
      ..writeln(
        'Resident set size growth while writing the whole workload once '
        '(${_size(options.chunkSizes.last)} chunks; xterm engines include '
        'UTF-8 decoding): `ProcessInfo.currentRss` after − before, and in '
        'brackets the peak growth (sampled after every chunk). Includes native memory.',
      )
      ..writeln()
      ..write('| Workload |');
    for (final e in options.engines) {
      b.write(' $e |');
    }
    b
      ..writeln()
      ..write('|---|');
    for (final _ in options.engines) {
      b.write('---:|');
    }
    b.writeln();
    for (final w in options.workloadNames) {
      final byEngine = byWorkload[w];
      if (byEngine == null) continue;
      b.write('| $w |');
      for (final e in options.engines) {
        final m = byEngine[e];
        if (m == null) {
          b.write(' – |');
          continue;
        }
        final delta = (m['rssAfter']! as int) - (m['rssBefore']! as int);
        final peak = (m['rssPeak']! as int) - (m['rssBefore']! as int);
        b.write(' ${_mib(delta)} (peak ${_mib(peak)}) |');
      }
      b.writeln();
    }
    b.writeln();
  }

  void _correctness(StringBuffer b) {
    b
      ..writeln('## Correctness')
      ..writeln()
      ..writeln(
        'Visible screen text after each workload (empty cells as spaces, '
        'trailing blanks trimmed). Required to match: '
        '${requiredAgreement.join(', ')}. "chunking" checks that every chunk '
        'size and feed left each engine with the same screen.',
      )
      ..writeln();
    final pairs = <(String, String)>[
      for (var i = 0; i < options.engines.length; i++)
        for (var j = i + 1; j < options.engines.length; j++)
          (options.engines[i], options.engines[j]),
    ];
    b.write('| Runtime | Workload |');
    for (final (a, c) in pairs) {
      b.write(' $a vs $c |');
    }
    b
      ..writeln(' chunking |')
      ..write('|---|---|');
    for (final _ in pairs) {
      b.write('---|');
    }
    b.writeln('---|');
    final details = <String>[];
    for (final MapEntry(key: runtime, value: byWorkload) in _screens.entries) {
      for (final w in options.workloadNames) {
        final byEngine = byWorkload[w];
        if (byEngine == null) continue;
        b.write('| $runtime | $w |');
        for (final (a, c) in pairs) {
          final d = _diff(byEngine[a]!, byEngine[c]!);
          if (d == null) {
            b.write(' ✅ identical |');
          } else {
            final mark = requiredAgreement.contains(w) ? '❌' : '⚠️';
            b.write(' $mark ${d.count}/${d.total} rows differ |');
            if (runtime == _screens.keys.first) {
              details.add(
                '- $w, $a vs $c, first at row ${d.row}:\n'
                '  - $a: `${_show(d.left, d.right)}`\n'
                '  - $c: `${_show(d.right, d.left)}`',
              );
            }
          }
        }
        final consistent = options.engines.every(
          (e) => _throughput[runtime]![w]![e]!['chunkingConsistent'] == true,
        );
        b.writeln(consistent ? ' ✅ |' : ' ⚠️ |');
      }
    }
    b.writeln();
    if (details.isNotEmpty) {
      b
        ..writeln('First differing row per mismatch:')
        ..writeln()
        ..writeln(details.join('\n'))
        ..writeln();
    }
  }
}

double? _median(Map<String, Object?> r, int chunk, String feed) {
  for (final entry in (r['results']! as List).cast<Map<String, Object?>>()) {
    if (entry['chunk'] == chunk && entry['feed'] == feed) {
      final micros = (entry['micros']! as List).cast<int>().toList()..sort();
      final n = micros.length;
      return n.isOdd
          ? micros[n ~/ 2].toDouble()
          : (micros[n ~/ 2 - 1] + micros[n ~/ 2]) / 2;
    }
  }
  return null;
}

final class _Diff {
  _Diff(this.count, this.total, this.row, this.left, this.right);
  final int count;
  final int total;
  final int row;
  final String left;
  final String right;
}

_Diff? _diff(List<String> a, List<String> b) {
  final total = a.length > b.length ? a.length : b.length;
  var count = 0;
  int? first;
  for (var i = 0; i < total; i++) {
    final x = i < a.length ? a[i] : '<missing>';
    final y = i < b.length ? b[i] : '<missing>';
    if (x != y) {
      count++;
      first ??= i;
    }
  }
  if (first == null) return null;
  return _Diff(
    count,
    total,
    first,
    first < a.length ? a[first] : '<missing>',
    first < b.length ? b[first] : '<missing>',
  );
}

/// [s] cut to a window around the first difference from [other] (by rune),
/// for a Markdown code span.
String _show(String s, String other) {
  final a = s.runes.toList();
  final b = other.runes.toList();
  var first = 0;
  while (first < a.length && first < b.length && a[first] == b[first]) {
    first++;
  }
  final start = first > 30 ? first - 30 : 0;
  final end = start + 70 < a.length ? start + 70 : a.length;
  final window = String.fromCharCodes(a.sublist(start, end));
  return '${start > 0 ? '…' : ''}${window.replaceAll('`', "'")}'
      '${end < a.length ? '…' : ''}';
}

String _size(int bytes) =>
    bytes % 1024 == 0 ? '${bytes ~/ 1024} KiB' : '$bytes B';

String _mib(int bytes) {
  final sign = bytes >= 0 ? '+' : '−';
  return '$sign${(bytes.abs() / 1024 / 1024).toStringAsFixed(1)} MiB';
}
