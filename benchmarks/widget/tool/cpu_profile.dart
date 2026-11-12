/// Samples the CPU profile of a running app's UI isolate through the Dart
/// VM service and prints the hottest functions, self and inclusive.
///
/// Usage:
///
/// ```sh
/// dart tool/cpu_profile.dart <ws://host:port/ws> <seconds> [delay seconds]
/// ```
///
/// Start the profile build with the engine switches
/// `vm-service-port=<port>` and `disable-service-auth-codes`
/// (`FLUTTER_ENGINE_SWITCHES`), as `mise run bench:attribution:profile`
/// does; samples come from the window between the delay and its end.
library;

import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: cpu_profile.dart <ws uri> <seconds> [delay]');
    exit(2);
  }
  final seconds = int.parse(args[1]);
  final delay = args.length > 2 ? int.parse(args[2]) : 0;
  VmService? service;
  for (var attempt = 0; service == null; attempt++) {
    try {
      service = await vmServiceConnectUri(args[0]);
    } on Object {
      if (attempt > 100) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  // Profile builds start with the sampling profiler off (DevTools turns
  // it on the same way).
  await service.setFlag('profiler', 'true');
  await service.setFlag('profile_period', '500');
  final vm = await service.getVM();
  final isolate = vm.isolates!.firstWhere((i) => i.name == 'main');
  await Future<void>.delayed(Duration(seconds: delay));
  await service.clearCpuSamples(isolate.id!);
  await Future<void>.delayed(Duration(seconds: seconds));
  final samples = await service.getCpuSamples(isolate.id!, 0, 9007199254740991);
  await service.dispose();
  final total = samples.sampleCount ?? samples.samples!.length;
  final functions = samples.functions!;
  stdout.writeln(
    'CPU_PROFILE ${seconds}s, $total samples '
    '(period ${samples.samplePeriod} us)',
  );
  void top(String title, int Function(ProfileFunction) ticks, int count) {
    final sorted = [...functions]..sort((a, b) => ticks(b).compareTo(ticks(a)));
    stdout.writeln('CPU_PROFILE -- $title');
    for (final function in sorted.take(count)) {
      final share = 100 * ticks(function) / total;
      stdout.writeln(
        'CPU_PROFILE ${share.toStringAsFixed(1).padLeft(5)}%  '
        '${_name(function.function)}',
      );
    }
  }

  top('self', (f) => f.exclusiveTicks ?? 0, 30);
  top('inclusive', (f) => f.inclusiveTicks ?? 0, 120);
}

String _name(Object? function) {
  switch (function) {
    case FuncRef(:final name, :final owner):
      final prefix = switch (owner) {
        ClassRef(:final name) => '$name.',
        FuncRef() => '${_name(owner)}.',
        LibraryRef(:final uri) => '${uri?.split('/').last}: ',
        _ => '',
      };
      return '$prefix$name';
    case NativeFunction(:final name):
      return '[native] $name';
    default:
      return '$function';
  }
}
