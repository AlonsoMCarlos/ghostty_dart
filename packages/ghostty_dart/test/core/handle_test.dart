import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

final _mallocFinalizer = NativeFinalizer(malloc.nativeFree);

/// A handle over a malloc'd block that records every free.
NativeHandle<Uint8> _handle(List<String> log, {String name = 'Thing'}) =>
    NativeHandle<Uint8>(
      malloc<Uint8>(8),
      typeName: name,
      free: (p) {
        log.add('free $name');
        malloc.free(p);
      },
      finalizer: _mallocFinalizer,
    );

void main() {
  group('NativeHandle', () {
    test('rejects NULL', () {
      expect(
        () => NativeHandle<Uint8>(
          nullptr,
          typeName: 'Thing',
          free: (_) {},
          finalizer: null,
        ),
        throwsArgumentError,
      );
    });

    test('dispose is idempotent and frees once', () {
      final log = <String>[];
      final handle = _handle(log);
      expect(handle.isDisposed, isFalse);
      handle
        ..dispose()
        ..dispose();
      expect(handle.isDisposed, isTrue);
      expect(log, ['free Thing']);
    });

    test('pointer and use throw StateError after dispose', () {
      final handle = _handle([])..dispose();
      final message = contains('Thing has been disposed');
      expect(() => handle.pointer, throwsA(isA<StateError>()));
      expect(() => handle.use((_) {}), throwsStateError);
      expect(
        handle.checkNotDisposed,
        throwsA(isA<StateError>().having((e) => e.message, 'm', message)),
      );
      expect(() => handle.addCleanup(() {}), throwsStateError);
    });

    test('dispose inside use defers the free until use returns', () {
      final log = <String>[];
      final handle = _handle(log);
      handle.use((outer) {
        handle.use((inner) {
          handle.dispose();
          expect(handle.isDisposed, isTrue);
          expect(log, isEmpty, reason: 'still inside a native call');
        });
        expect(log, isEmpty, reason: 'outer use still running');
        expect(handle.isInUse, isTrue);
      });
      expect(log, ['free Thing']);
      expect(handle.isInUse, isFalse);
    });

    test('use releases the busy state when the action throws', () {
      final handle = _handle([]);
      expect(
        () => handle.use<void>((_) => throw StateError('x')),
        throwsStateError,
      );
      expect(handle.isInUse, isFalse);
      handle.dispose();
    });

    test('cleanups run after the free, last added first, once', () {
      final log = <String>[];
      final handle = _handle(log)
        ..addCleanup(() => log.add('first'))
        ..addCleanup(() => log.add('second'));
      handle
        ..dispose()
        ..dispose();
      expect(log, ['free Thing', 'second', 'first']);
    });

    test('a failing cleanup does not stop the others', () {
      final log = <String>[];
      final handle = _handle(log)
        ..addCleanup(() => log.add('first'))
        ..addCleanup(() => throw StateError('boom'));
      expect(handle.dispose, throwsStateError);
      expect(log, ['free Thing', 'first']);
    });

    test('dependents are disposed before the owner is freed', () {
      final log = <String>[];
      final parent = _handle(log, name: 'parent');
      final child = _handle(log, name: 'child');
      final orphan = _handle(log, name: 'orphan');
      parent
        ..addDependent(child)
        ..addDependent(orphan);
      orphan.dispose();
      parent.dispose();
      expect(log, ['free orphan', 'free child', 'free parent']);
      expect(child.isDisposed, isTrue);
    });

    group('dependent frees wait for the owner', () {
      test('a dependent disposed inside the owner use is freed after it', () {
        final log = <String>[];
        final owner = _handle(log, name: 'Owner');
        final dependent = _handle(log, name: 'Dep');
        owner.addDependent(dependent);
        owner.use((_) {
          dependent.dispose();
          expect(dependent.isDisposed, isTrue);
          expect(() => dependent.pointer, throwsStateError);
          expect(log, isEmpty);
          log.add('use ends');
        });
        expect(log, ['use ends', 'free Dep']);
        owner.dispose();
        expect(log.last, 'free Owner');
      });

      test('an owner disposed inside use frees dependents first, after', () {
        final log = <String>[];
        final owner = _handle(log, name: 'Owner');
        final dependent = _handle(log, name: 'Dep');
        owner.addDependent(dependent);
        owner.use((_) {
          owner.use((_) => owner.dispose());
          expect(dependent.isDisposed, isTrue);
          expect(log, isEmpty, reason: 'still inside the outermost use');
        });
        expect(log, ['free Dep', 'free Owner']);
      });

      test('a dependent in its own use waits for both uses to end', () {
        final log = <String>[];
        final owner = _handle(log, name: 'Owner');
        final dependent = _handle(log, name: 'Dep');
        owner.addDependent(dependent);
        dependent.use((_) {
          owner.use((_) => dependent.dispose());
          expect(log, isEmpty, reason: 'the dependent is still in use');
        });
        expect(log, ['free Dep']);
        owner.use((_) {
          final second = _handle(log, name: 'Dep2');
          owner.addDependent(second);
          second.use((_) => second.dispose());
          expect(log, ['free Dep'], reason: 'the owner is still in use');
        });
        expect(log, ['free Dep', 'free Dep2']);
        owner.dispose();
      });

      test('outside any use a dependent is freed at once', () {
        final log = <String>[];
        final owner = _handle(log, name: 'Owner');
        final dependent = _handle(log, name: 'Dep');
        owner.addDependent(dependent);
        dependent.dispose();
        expect(log, ['free Dep']);
        owner.dispose();
      });

      test('a failing deferred cleanup does not skip the owner free', () {
        final log = <String>[];
        final owner = _handle(log, name: 'Owner');
        final dependent = _handle(log, name: 'Dep')
          ..addCleanup(() => throw StateError('boom'));
        owner.addDependent(dependent);
        expect(
          () => owner.use((_) => owner.dispose()),
          throwsA(isA<StateError>().having((e) => e.message, 'm', 'boom')),
        );
        expect(log, ['free Dep', 'free Owner']);
      });

      test('a handle has one owner', () {
        final first = _handle([]);
        final second = _handle([]);
        final dependent = _handle([]);
        first
          ..addDependent(dependent)
          ..addDependent(dependent);
        expect(() => second.addDependent(dependent), throwsStateError);
        first.dispose();
        second.dispose();
      });
    });

    test('epoch counts mutations', () {
      final handle = _handle([]);
      final before = handle.epoch;
      handle
        ..bumpEpoch()
        ..bumpEpoch();
      expect(handle.epoch, before + 2);
      handle.dispose();
    });

    test('attachments are stored per key and dropped on dispose', () {
      final handle = _handle([]);
      final key = Object();
      expect(handle.attachment<String>(key), isNull);
      handle.setAttachment(key, 'value');
      expect(handle.attachment<String>(key), 'value');
      handle.setAttachment(key, null);
      expect(handle.attachment<String>(key), isNull);
      handle
        ..setAttachment(key, 'again')
        ..dispose();
      expect(handle.attachment<String>(key), isNull);
    });
  });

  group('handle registry', () {
    test('handleOf returns the handle bound to a VtTerminal', () {
      final terminal = VtTerminal(cols: 10, rows: 5);
      final handle = handleOf<GhosttyTerminalImpl>(terminal);
      expect(handle.typeName, 'VtTerminal');
      expect(handle.pointer, isNot(nullptr));
      terminal.dispose();
      expect(handle.isDisposed, isTrue);
      expect(() => handle.pointer, throwsStateError);
    });

    test('handleOf throws for objects without a handle', () {
      expect(
        () => handleOf<GhosttyTerminalImpl>(Object()),
        throwsArgumentError,
      );
    });

    test('bindHandle refuses a second handle', () {
      final owner = Object();
      final first = _handle([]);
      final second = _handle([]);
      bindHandle(owner, first);
      expect(() => bindHandle(owner, second), throwsStateError);
      first.dispose();
      second.dispose();
    });
  });

  group('createNative', () {
    test('returns the created pointer', () {
      final pointer = createNative<GhosttyTerminalImpl>(
        'ghostty_terminal_new',
        (out) => ghostty_terminal_new(nullptr, out, 4, 4),
      );
      expect(pointer, isNot(nullptr));
      ghostty_terminal_free(pointer);
    });

    test('maps a failing constructor to GhosttyException', () {
      expect(
        () => createNative<GhosttyTerminalImpl>(
          'ghostty_terminal_new',
          (out) => ghostty_terminal_new(nullptr, out, 0, 4),
        ),
        throwsA(
          isA<GhosttyException>()
              .having((e) => e.operation, 'op', 'ghostty_terminal_new')
              .having((e) => e.code, 'code', GhosttyResultCode.invalidValue),
        ),
      );
    });

    test('treats a NULL result as invalidValue', () {
      expect(
        () => createNative<GhosttyTerminalImpl>('fake_new', (_) => 0),
        throwsA(isA<GhosttyException>()),
      );
    });
  });
}
