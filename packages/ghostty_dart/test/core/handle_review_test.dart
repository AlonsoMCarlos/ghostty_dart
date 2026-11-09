import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:test/test.dart';

final _mallocFinalizer = NativeFinalizer(malloc.nativeFree);

NativeHandle<Uint8> _handle(
  List<String> log,
  String name, {
  bool throwOnFree = false,
}) => NativeHandle<Uint8>(
  malloc<Uint8>(8),
  typeName: name,
  free: (p) {
    log.add('free $name');
    malloc.free(p);
    if (throwOnFree) throw StateError('boom $name');
  },
  finalizer: _mallocFinalizer,
);

void main() {
  test('owner disposed while a dependent is in its own use (owner idle)', () {
    final log = <String>[];
    final owner = _handle(log, 'O');
    final dep = _handle(log, 'D');
    owner.addDependent(dep);
    dep.use((_) {
      owner.dispose();
      log.add('after owner.dispose');
    });
    expect(log, ['after owner.dispose', 'free D', 'free O']);
  });

  test('owner disposed in a nested owner use inside the dependent use', () {
    final log = <String>[];
    final owner = _handle(log, 'O');
    final dep = _handle(log, 'D');
    owner.addDependent(dep);
    dep.use((_) {
      owner.use((_) => owner.dispose());
      log.add('owner use returned');
    });
    expect(log, ['owner use returned', 'free D', 'free O']);
  });

  test(
    'deferred dependent whose free throws still frees owner, error surfaces',
    () {
      final log = <String>[];
      final owner = _handle(log, 'O');
      final dep = _handle(log, 'D', throwOnFree: true);
      owner.addDependent(dep);
      expect(
        () => owner.use((_) => owner.dispose()),
        throwsA(isA<StateError>().having((e) => e.message, 'm', 'boom D')),
      );
      expect(log, ['free D', 'free O']);
      expect(owner.isInUse, isFalse);
    },
  );

  test('re-entrant uses with an exception keep depth right', () {
    final log = <String>[];
    final owner = _handle(log, 'O');
    final dep = _handle(log, 'D');
    owner.addDependent(dep);
    owner.use((_) {
      expect(
        () => owner.use((_) {
          dep.dispose();
          throw Exception('x');
        }),
        throwsException,
      );
      expect(owner.isInUse, isTrue);
      expect(log, isEmpty);
    });
    expect(log, ['free D']);
    expect(owner.isInUse, isFalse);
    owner.dispose();
    expect(log, ['free D', 'free O']);
  });

  test('grandchild chain: all deferred, freed leaf first', () {
    final log = <String>[];
    final g = _handle(log, 'G');
    final o = _handle(log, 'O');
    final d = _handle(log, 'D');
    g.addDependent(o);
    o.addDependent(d);
    g.use((_) => o.use((_) => g.dispose()));
    expect(log, ['free D', 'free O', 'free G']);
  });

  test('dependent disposed in owner use, then owner disposed in same use', () {
    final log = <String>[];
    final o = _handle(log, 'O');
    final d = _handle(log, 'D');
    o.addDependent(d);
    o.use((_) {
      d.dispose();
      o.dispose();
      d.dispose();
    });
    expect(log, ['free D', 'free O']);
  });

  test('dependent disposed in owner use, owner disposed later outside', () {
    final log = <String>[];
    final o = _handle(log, 'O');
    final d = _handle(log, 'D');
    o.addDependent(d);
    o.use((_) => d.dispose());
    expect(log, ['free D']);
    o.dispose();
    expect(log, ['free D', 'free O']);
  });

  test('a busy dependent whose free throws still lets the owner be freed', () {
    final log = <String>[];
    final owner = _handle(log, 'O');
    final dep = _handle(log, 'D', throwOnFree: true);
    owner.addDependent(dep);
    expect(
      () => dep.use((_) => owner.dispose()),
      throwsA(isA<StateError>().having((e) => e.message, 'm', 'boom D')),
    );
    expect(log, ['free D', 'free O']);
  });

  test('pruning keeps a disposed dependent that is still in its use', () {
    final log = <String>[];
    final owner = _handle(log, 'O');
    final busy = _handle(log, 'D');
    owner.addDependent(busy);
    busy.use((_) {
      busy.dispose();
      for (var i = 0; i < 20; i++) {
        owner.addDependent(_handle(log, 'x$i')..dispose());
      }
      log.clear();
      owner.dispose();
      expect(log, isEmpty);
    });
    expect(log, ['free D', 'free O']);
  });
}
