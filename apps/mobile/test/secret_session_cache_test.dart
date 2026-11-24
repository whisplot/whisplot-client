import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:nearlink/services/secret_session_cache.dart';

class FakeSecretIo {
  final values = <String, String>{};
  final calls = <String>[];
  Future<String?> Function(String)? onRead;
  Future<void> Function(String, String)? onWrite;
  Future<void> Function(String)? onDelete;
  Future<String?> read(String key) async {
    calls.add('read:$key');
    if (onRead != null) return onRead!(key);
    return values[key];
  }

  Future<void> write(String key, String value) async {
    calls.add('write:$key');
    if (onWrite != null) return onWrite!(key, value);
    values[key] = value;
  }

  Future<void> delete(String key) async {
    calls.add('delete:$key');
    if (onDelete != null) return onDelete!(key);
    values.remove(key);
  }

  SecretSessionCache cache({bool enabled = true}) => SecretSessionCache(
    enabled: enabled,
    read: read,
    write: write,
    delete: delete,
  );
}

class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage(this.readValue);
  final Future<String?> Function(String) readValue;
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => readValue(key);
}

PlatformException denied(int status) =>
    PlatformException(code: 'Unexpected security result code', details: status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'successful reads are shared and identical writes do not access storage',
    () async {
      final io = FakeSecretIo()..values['group-key'] = 'authorized';
      final cache = io.cache();
      final reads = List.generate(50, (_) => cache.read('group-key'));
      expect(await Future.wait(reads), everyElement('authorized'));
      await cache.write('group-key', 'authorized');
      expect(await cache.read('group-key'), 'authorized');
      expect(io.calls, ['read:group-key']);
      await cache.write('group-key', 'updated');
      expect(await cache.read('group-key'), 'updated');
      expect(io.calls, ['read:group-key', 'write:group-key']);
    },
  );

  test('a missing item is not cached as success', () async {
    final io = FakeSecretIo();
    final cache = io.cache();
    expect(await cache.read('missing'), isNull);
    io.values['missing'] = 'created elsewhere';
    expect(await cache.read('missing'), 'created elsewhere');
    expect(io.calls, ['read:missing', 'read:missing']);
  });

  test(
    'ordinary failures propagate once and do not poison a later request',
    () async {
      final io = FakeSecretIo()
        ..onRead = (_) async => throw StateError('temporary failure');
      final cache = io.cache();
      final first = cache.read('identity');
      final second = cache.read('identity');
      expect(identical(first, second), isTrue);
      await Future.wait([
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ]);
      expect(io.calls, ['read:identity']);
      expect(cache.accessBlocked, isFalse);
      io.onRead = (_) async => 'restored';
      expect(await cache.read('identity'), 'restored');
      expect(io.calls, ['read:identity', 'read:identity']);
    },
  );

  for (final status in [-128, -25293, -25308, -25294]) {
    test(
      'authorization status $status blocks queued IO until explicit retry',
      () async {
        final io = FakeSecretIo()..onRead = (_) async => throw denied(status);
        final cache = io.cache();
        final blocked = isA<SecretAccessBlockedException>().having(
          (e) => e.status,
          'status',
          status,
        );
        await Future.wait([
          expectLater(cache.read('identity'), throwsA(blocked)),
          expectLater(cache.read('group-key'), throwsA(blocked)),
          expectLater(cache.write('marker', 'value'), throwsA(blocked)),
          expectLater(cache.delete('pending'), throwsA(blocked)),
        ]);
        expect(io.calls, ['read:identity']);
        expect(cache.accessBlocked, isTrue);
        io.onRead = (_) async => 'authorized';
        await expectLater(cache.read('another-key'), throwsA(blocked));
        expect(io.calls, ['read:identity']);
        cache.retryAccess();
        expect(cache.accessBlocked, isFalse);
        expect(await cache.read('identity'), 'authorized');
        expect(io.calls, ['read:identity', 'read:identity']);
      },
    );
  }

  test(
    'successfully cached values remain usable while new access is blocked',
    () async {
      final io = FakeSecretIo()..values['old-key'] = 'authorized';
      final cache = io.cache();
      expect(await cache.read('old-key'), 'authorized');
      io.onRead = (_) async => throw denied(-128);
      await expectLater(
        cache.read('new-key'),
        throwsA(isA<SecretAccessBlockedException>()),
      );
      await cache.write('old-key', 'authorized');
      await expectLater(
        cache.write('old-key', 'not-yet-saved'),
        throwsA(isA<SecretAccessBlockedException>()),
      );
      expect(await cache.read('old-key'), 'authorized');
      expect(io.calls, ['read:old-key', 'read:new-key']);
    },
  );

  test('a delayed read cannot overwrite a newer successful write', () async {
    final firstRead = Completer<String?>();
    final io = FakeSecretIo()..onRead = (_) => firstRead.future;
    final cache = io.cache();
    final before = cache.read('key');
    final write = cache.write('key', 'new');
    final after = cache.read('key');
    await Future<void>.delayed(Duration.zero);
    expect(io.calls, ['read:key']);
    firstRead.complete('old');
    expect(await before, 'old');
    await write;
    expect(await after, 'new');
    expect(await cache.read('key'), 'new');
    expect(io.calls, ['read:key', 'write:key']);
  });

  test(
    'all keys share one IO queue and a late read cannot undo deletion',
    () async {
      final firstRead = Completer<String?>();
      final io = FakeSecretIo()..onRead = (_) => firstRead.future;
      final cache = io.cache();
      final reading = cache.read('key');
      final otherWrite = cache.write('other', 'value');
      final deletion = cache.delete('key');
      final after = cache.read('key');
      await Future<void>.delayed(Duration.zero);
      expect(io.calls, ['read:key']);
      io.onRead = (_) async => null;
      firstRead.complete('old');
      expect(await reading, 'old');
      await otherWrite;
      await deletion;
      expect(await after, isNull);
      expect(io.calls, ['read:key', 'write:other', 'delete:key', 'read:key']);
    },
  );

  test('failed writes never cache the attempted value', () async {
    final io = FakeSecretIo()..values['key'] = 'old';
    final cache = io.cache();
    expect(await cache.read('key'), 'old');
    io.onWrite = (_, _) async => throw StateError('write failed');
    await expectLater(cache.write('key', 'new'), throwsStateError);
    expect(await cache.read('key'), 'old');
    expect(io.calls, ['read:key', 'write:key', 'read:key']);
  });

  test(
    'failed deletes preserve cached values and success invalidates them',
    () async {
      final io = FakeSecretIo()..values['key'] = 'old';
      final cache = io.cache();
      expect(await cache.read('key'), 'old');
      io.onDelete = (_) async => throw StateError('delete failed');
      await expectLater(cache.delete('key'), throwsStateError);
      expect(await cache.read('key'), 'old');
      io.onDelete = null;
      await cache.delete('key');
      expect(await cache.read('key'), isNull);
      expect(io.calls, ['read:key', 'delete:key', 'delete:key', 'read:key']);
    },
  );

  test(
    'clearing memory prevents in-flight reads from refilling the session',
    () async {
      final firstRead = Completer<String?>();
      final io = FakeSecretIo()..onRead = (_) => firstRead.future;
      final cache = io.cache();
      final old = cache.read('key');
      await Future<void>.delayed(Duration.zero);
      cache.clear();
      io.onRead = (_) async => 'new session';
      firstRead.complete('old session');
      expect(await old, 'old session');
      expect(await cache.read('key'), 'new session');
      expect(io.calls, ['read:key', 'read:key']);
    },
  );

  test(
    'close cancels queued IO and does not allow an in-flight result to reopen access',
    () async {
      final pendingRead = Completer<String?>();
      final io = FakeSecretIo()..onRead = (_) => pendingRead.future;
      final cache = io.cache();
      final old = cache.read('identity');
      final queuedWrite = cache.write('another-key', 'not-written');
      final rejectedWrite = expectLater(queuedWrite, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(io.calls, ['read:identity']);
      cache.close();
      pendingRead.complete('old-authorized-value');
      expect(await old, 'old-authorized-value');
      await rejectedWrite;
      cache.retryAccess();
      cache.clear();
      await expectLater(cache.read('identity'), throwsStateError);
      await expectLater(
        cache.write('identity', 'replacement'),
        throwsStateError,
      );
      await expectLater(cache.delete('identity'), throwsStateError);
      expect(io.calls, ['read:identity']);
      expect(io.values, isEmpty);
    },
  );

  test(
    'clear also cancels queued operations from the previous generation',
    () async {
      final pendingRead = Completer<String?>();
      final io = FakeSecretIo()..onRead = (_) => pendingRead.future;
      final cache = io.cache();
      final old = cache.read('identity');
      final queuedWrite = expectLater(
        cache.write('another-key', 'stale'),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      cache.clear();
      io.onRead = (_) async => 'fresh';
      pendingRead.complete('old');
      expect(await old, 'old');
      await queuedWrite;
      expect(await cache.read('identity'), 'fresh');
      expect(io.calls, ['read:identity', 'read:identity']);
    },
  );

  test(
    'disabled cache preserves direct IO and never enables the access latch',
    () async {
      final io = FakeSecretIo()..values['key'] = 'one';
      final cache = io.cache(enabled: false);
      expect(await cache.read('key'), 'one');
      io.values['key'] = 'two';
      expect(await cache.read('key'), 'two');
      await cache.write('key', 'two');
      await cache.write('key', 'two');
      io.onRead = (_) async => throw denied(-128);
      await expectLater(cache.read('key'), throwsA(isA<PlatformException>()));
      expect(cache.accessBlocked, isFalse);
      io.onRead = (_) async => 'allowed';
      expect(await cache.read('key'), 'allowed');
      expect(io.calls, [
        'read:key',
        'read:key',
        'write:key',
        'write:key',
        'read:key',
        'read:key',
      ]);
    },
  );

  test(
    'LocalStore uses the cache and close permanently ends its secret session',
    () async {
      final io = FakeSecretIo()..values['key'] = 'first';
      final store = LocalStore(
        secrets: FakeSecureStorage(io.read),
        cacheSecrets: true,
      );
      expect(await store.readSecret('key'), 'first');
      io.values['key'] = 'second';
      expect(await store.readSecret('key'), 'first');
      await store.close();
      await expectLater(store.readSecret('key'), throwsStateError);
      await expectLater(store.writeSecret('key', 'third'), throwsStateError);
      await expectLater(store.deleteSecret('key'), throwsStateError);
      expect(io.calls, ['read:key']);
    },
  );

  test(
    'LocalStore exposes explicit authorization retry without replacing a secret',
    () async {
      final io = FakeSecretIo()..onRead = (_) async => throw denied(-25293);
      final store = LocalStore(
        secrets: FakeSecureStorage(io.read),
        cacheSecrets: true,
      );
      await expectLater(
        store.readSecret('identity-seed'),
        throwsA(isA<SecretAccessBlockedException>()),
      );
      expect(store.secretAccessBlocked, isTrue);
      io.onRead = (_) async => 'original identity';
      store.retrySecretAccess();
      expect(await store.readSecret('identity-seed'), 'original identity');
      expect(io.calls, ['read:identity-seed', 'read:identity-seed']);
      await store.close();
    },
  );

  test('LocalStore enables caching by default only on macOS', () async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final target in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      debugDefaultTargetPlatformOverride = target;
      final io = FakeSecretIo()..values['key'] = 'first';
      final store = LocalStore(secrets: FakeSecureStorage(io.read));
      expect(await store.readSecret('key'), 'first');
      io.values['key'] = 'second';
      expect(
        await store.readSecret('key'),
        target == TargetPlatform.macOS ? 'first' : 'second',
      );
      await store.close();
    }
  });
}
