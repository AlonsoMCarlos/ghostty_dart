/// Process and thread CPU time from `/proc` (Linux), and the display the
/// benchmarks run on. Shared by the firehose and attribution benchmarks.
library;

import 'dart:io';
import 'dart:ui';

/// CPU time (user + system) of every live thread of this process, by
/// thread name with digits replaced by `#`, in microseconds. Empty off
/// Linux.
Map<String, int> threadCpu() {
  final result = <String, int>{};
  final tasks = Directory('/proc/self/task');
  if (!tasks.existsSync()) return result;
  for (final task in tasks.listSync()) {
    try {
      final stat = File('${task.path}/stat').readAsStringSync();
      final close = stat.lastIndexOf(')');
      final name = stat
          .substring(stat.indexOf('(') + 1, close)
          .replaceAll(RegExp('[0-9]+'), '#');
      final fields = stat.substring(close + 2).split(' ');
      // utime and stime (fields 14 and 15 of proc_pid_stat(5)), in clock
      // ticks of 1/100 s.
      final ticks = int.parse(fields[11]) + int.parse(fields[12]);
      result[name] = (result[name] ?? 0) + ticks * 10000;
    } on FileSystemException {
      // The thread exited while listing.
    }
  }
  return result;
}

/// The thread CPU time spent between two [threadCpu] samples, in
/// milliseconds, for threads that spent at least [minMs].
Map<String, int> threadCpuDelta(
  Map<String, int> before,
  Map<String, int> after, {
  int minMs = 10,
}) => {
  for (final MapEntry(:key, :value) in after.entries)
    if ((value - (before[key] ?? 0)) ~/ 1000 >= minMs)
      key: (value - (before[key] ?? 0)) ~/ 1000,
};

/// The process's CPU time (user + system, all threads, exited ones
/// included) in microseconds. Linux only.
int processCpu() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return (int.parse(fields[11]) + int.parse(fields[12])) * 10000;
}

/// The name [threadCpu] gives the main thread (the process's own, which
/// runs the UI isolate and GTK), or `''` off Linux.
String mainThreadName() {
  final file = File('/proc/self/comm');
  if (!file.existsSync()) return '';
  return file.readAsStringSync().trim().replaceAll(RegExp('[0-9]+'), '#');
}

/// The window's size in physical pixels: what the embedder presents each
/// frame.
String windowSize() {
  final size = PlatformDispatcher.instance.views.first.physicalSize;
  return '${size.width.round()} x ${size.height.round()}';
}

/// The windowing system GTK uses: `wayland` or `x11` (`GDK_BACKEND` when
/// set, else the session's). On X11 Flutter's Linux embedder copies every
/// frame through the CPU (`fl_view_renderer.cc`: frames are shareable
/// only on Wayland).
String displayBackend() {
  final env = Platform.environment;
  final backend = env['GDK_BACKEND'];
  if (backend != null && backend.isNotEmpty) return backend;
  if ((env['WAYLAND_DISPLAY'] ?? '').isNotEmpty) return 'wayland';
  if ((env['DISPLAY'] ?? '').isNotEmpty) return 'x11';
  return env['XDG_SESSION_TYPE'] ?? 'unknown';
}
