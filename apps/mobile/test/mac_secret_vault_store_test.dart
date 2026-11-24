import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:nearlink/services/mac_secret_vault.dart';
import 'package:nearlink/services/mac_secret_vault_platform.dart';
import 'package:nearlink/services/secret_session_cache.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _vaultState = 'mac-secret-vault-v1';
const _vaultMarker = 'mac-secret-vault-initialized-v1';
final _identitySeed = b64(List.generate(32, (i) => i + 1));
final _oldGroupKey = List.generate(32, (i) => i + 40);
final _currentGroupKey = List.generate(32, (i) => i + 90);
const _group = Group(
  id: 'synthetic-vault-group',
  server: 'https://vault-test.invalid',
  name: 'Synthetic vault group',
  ownerId: 'synthetic-owner',
  keyEpoch: 3,
  protocolVersion: 2,
  privacyEpoch: 2,
);

String _groupKeyName(int epoch) =>
    'group-key:${b64(utf8.encode(_group.storageId))}:epoch:$epoch';

class _LegacySecrets extends FlutterSecureStorage {
  final values = <String, String>{};
  final reads = <String>[];
  final writes = <String>[];
  final deletes = <String>[];
  String? deniedKey;
  int denialStatus = -128;
  bool forbidReads = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads.add(key);
    if (forbidReads) {
      throw StateError('Migrated vault must not read legacy data');
    }
    if (key == deniedKey) {
      throw PlatformException(
        code: 'Unexpected security result code',
        details: denialStatus,
      );
    }
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes.add(key);
    throw StateError('Vault must not rewrite legacy Keychain entries');
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes.add(key);
    throw StateError('Vault must not delete legacy Keychain entries');
  }
}

class _NativeVault {
  _NativeVault(this.legacy);
  final _LegacySecrets legacy;
  final calls = <String>[];
  List<int>? master;
  bool forbidLegacyList = false;

  Future<Object?> handle(MethodCall call) async {
    expect(call.arguments, isNull);
    calls.add(call.method);
    switch (call.method) {
      case 'readMaster':
        return master == null ? null : base64Encode(master!);
      case 'createMaster':
        if (master != null) {
          throw PlatformException(
            code: 'Unexpected security result code',
            details: -25299,
          );
        }
        master = List.generate(32, (i) => 220 - i);
        return base64Encode(master!);
      case 'listLegacyKeys':
        if (forbidLegacyList) {
          throw StateError(
            'Completed migration must not enumerate legacy keys',
          );
        }
        // The real native bridge excludes its master account. Including it
        // here also exercises the Dart wrapper's defensive exclusion.
        return [
          ...legacy.values.keys,
          'mac-vault-master-v1',
          'mac-vault-master-v2',
          'mac-vault-master-v2-initialized',
        ];
      default:
        throw StateError('Unexpected native vault method');
    }
  }
}

class _StoreFixture {
  _StoreFixture(this.directory);
  final Directory directory;
  final legacy = _LegacySecrets();
  late final native = _NativeVault(legacy);
  Database? database;
  LocalStore? store;

  Future<LocalStore> session({bool cacheSecrets = true}) async {
    await store?.close();
    database = await databaseFactoryFfi.openDatabase(
      '${directory.path}/synthetic-vault.sqlite',
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (db, _) => LocalStore.createSchema(db),
      ),
    );
    return store = LocalStore(
      database: database,
      secrets: legacy,
      cacheSecrets: cacheSecrets,
      useMacSecretVault: true,
    );
  }

  void clearCalls() {
    native.calls.clear();
    legacy.reads.clear();
  }

  Future<void> dispose() async {
    await store?.close();
    await directory.delete(recursive: true);
  }
}

Matcher _vaultError(String code) => isA<MacSecretVaultException>().having(
  (error) => error.code,
  'vault error code',
  code,
);

Matcher _denied(int status) => anyOf(
  isA<PlatformException>()
      .having((error) => error.code, 'code', 'Unexpected security result code')
      .having((error) => error.details, 'OSStatus', status),
  isA<SecretAccessBlockedException>().having(
    (error) => error.status,
    'OSStatus',
    status,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _StoreFixture fixture;

  setUp(() async {
    fixture = _StoreFixture(
      await Directory.systemTemp.createTemp('mentor-vault-store-test-'),
    );
    messenger.setMockMethodCallHandler(
      MacSecretVaultPlatform.channel,
      fixture.native.handle,
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(MacSecretVaultPlatform.channel, null);
    await fixture.dispose();
  });

  test(
    'legacy identity and epoch keys migrate into encrypted SQLite state',
    () async {
      fixture.legacy.values.addAll({
        'identity-seed': _identitySeed,
        _groupKeyName(1): b64(_oldGroupKey),
        _groupKeyName(3): b64(_currentGroupKey),
        'pending:${_groupKeyName(3)}': b64(List.filled(32, 177)),
        'registration-code': 'synthetic-private-registration-value',
        'appearance-v1': 'synthetic-old-theme',
        'display-name': 'synthetic-retired-alias',
      });
      final before = Map<String, String>.of(fixture.legacy.values);
      final store = await fixture.session();
      await store.saveGroup(_group);
      await store.open();

      expect(await store.readSecret('identity-seed'), _identitySeed);
      expect(await store.groupKey(_group, epoch: 1), _oldGroupKey);
      expect(await store.groupKey(_group), _currentGroupKey);
      expect(await store.readSecret('appearance-v1'), isNull);
      expect(await store.readSecret('display-name'), isNull);
      expect(fixture.legacy.reads, isNot(contains('appearance-v1')));
      expect(fixture.legacy.reads, isNot(contains('display-name')));
      expect(fixture.legacy.reads, isNot(contains('mac-vault-master-v1')));
      expect(fixture.legacy.reads, isNot(contains('mac-vault-master-v2')));
      expect(
        fixture.legacy.reads,
        isNot(contains('mac-vault-master-v2-initialized')),
      );
      expect(fixture.legacy.reads.length, 5);
      expect(fixture.legacy.values, before);
      expect(fixture.legacy.writes, isEmpty);
      expect(fixture.legacy.deletes, isEmpty);
      expect(fixture.native.calls, [
        'readMaster',
        'createMaster',
        'listLegacyKeys',
      ]);
      expect(store.secretMigrationProgress?.migrationComplete, isTrue);
      expect(store.secretMigrationProgress?.completed, 5);

      final state = await store.readState(_vaultState);
      expect(state?.keys, ['sealed']);
      final envelope = jsonDecode(state!['sealed'] as String) as Map;
      expect(envelope.keys.toSet(), {'v', 'nonce', 'ciphertext', 'mac'});
      expect(base64Decode(envelope['nonce'] as String).length, 12);
      expect(base64Decode(envelope['mac'] as String).length, 16);
      expect(await store.readState(_vaultMarker), {'v': 1});
      final persisted = jsonEncode(
        await fixture.database!.query('local_state'),
      );
      for (final value in before.values) {
        expect(persisted, isNot(contains(value)));
      }
      expect(persisted, isNot(contains(base64Encode(fixture.native.master!))));
      expect(persisted, isNot(contains('identity-seed')));
      expect(persisted, isNot(contains(_groupKeyName(1))));
      expect((await store.groups(_group.server)).single.id, _group.id);
    },
  );

  for (final cacheSecrets in [true, false]) {
    test(
      'reopened vault uses one master read with session cache $cacheSecrets',
      () async {
        fixture.legacy.values.addAll({
          'identity-seed': _identitySeed,
          _groupKeyName(1): b64(_oldGroupKey),
          _groupKeyName(3): b64(_currentGroupKey),
          'retired-secret': 'synthetic-legacy-value-that-must-not-resurrect',
        });
        final first = await fixture.session(cacheSecrets: cacheSecrets);
        await first.open();
        final next = await fixture.session(cacheSecrets: cacheSecrets);
        fixture.clearCalls();
        fixture.native.forbidLegacyList = true;
        fixture.legacy.forbidReads = true;
        await next.open();

        final values = await Future.wait(
          List.generate(20, (_) => next.readSecret('identity-seed')),
        );
        expect(values, everyElement(_identitySeed));
        for (var i = 0; i < 8; i++) {
          expect(await next.groupKey(_group, epoch: 1), _oldGroupKey);
          expect(await next.groupKey(_group), _currentGroupKey);
          await next.savePendingKey(_group, List.filled(32, i + 1));
          await next.discardPendingKey(_group);
          expect(await next.readSecret('pending:${_groupKeyName(3)}'), isNull);
          await next.writeSecret('scratch-secret', 'synthetic-value-$i');
          expect(await next.readSecret('scratch-secret'), 'synthetic-value-$i');
          await next.deleteSecret('scratch-secret');
        }
        await next.deleteSecret('retired-secret');
        expect(await next.readSecret('retired-secret'), isNull);
        expect(fixture.native.calls, ['readMaster']);
        expect(fixture.legacy.reads, isEmpty);
        expect(fixture.legacy.writes, isEmpty);
        expect(fixture.legacy.deletes, isEmpty);

        final third = await fixture.session(cacheSecrets: cacheSecrets);
        fixture.clearCalls();
        await third.open();
        expect(await third.readSecret('retired-secret'), isNull);
        expect(await third.readSecret('identity-seed'), _identitySeed);
        expect(fixture.native.calls, ['readMaster']);
        expect(fixture.legacy.reads, isEmpty);
        expect(fixture.legacy.values['retired-secret'], isNotNull);
      },
    );
  }

  test(
    'initialized marker with missing vault refuses reinitialization',
    () async {
      fixture.legacy.values['identity-seed'] = _identitySeed;
      final store = await fixture.session();
      await store.writeState(_vaultMarker, {'v': 1});
      await expectLater(store.open(), throwsA(_vaultError('vaultMissing')));
      expect(store.secretAccessBlocked, isTrue);
      await expectLater(
        store.writeSecret('identity-seed', 'must-never-replace-identity'),
        throwsA(_vaultError('vaultMissing')),
      );
      expect(fixture.native.calls, isEmpty);
      expect(fixture.legacy.reads, isEmpty);
      expect(await store.readState(_vaultState), isNull);
      expect(await store.readState(_vaultMarker), {'v': 1});
    },
  );

  test(
    'ciphertext tampering blocks reads without falling back to legacy keys',
    () async {
      fixture.legacy.values['identity-seed'] = _identitySeed;
      final first = await fixture.session();
      await first.open();
      final state = (await first.readState(_vaultState))!;
      final envelope = Map<String, dynamic>.from(
        jsonDecode(state['sealed'] as String) as Map,
      );
      final ciphertext = base64Decode(envelope['ciphertext'] as String);
      ciphertext[ciphertext.length ~/ 2] ^= 1;
      envelope['ciphertext'] = base64Encode(ciphertext);
      final corrupted = {'sealed': jsonEncode(envelope)};
      await first.writeState(_vaultState, corrupted);

      final next = await fixture.session();
      fixture.clearCalls();
      fixture.native.forbidLegacyList = true;
      fixture.legacy.forbidReads = true;
      await expectLater(
        next.open(),
        throwsA(_vaultError('authenticationFailed')),
      );
      await expectLater(
        next.readSecret('identity-seed'),
        throwsA(_vaultError('authenticationFailed')),
      );
      expect(next.secretAccessBlocked, isTrue);
      expect(fixture.native.calls, ['readMaster']);
      expect(fixture.legacy.reads, isEmpty);
      expect(await next.readState(_vaultState), corrupted);
      expect(await next.readState(_vaultMarker), {'v': 1});
      next.retrySecretAccess();
      await expectLater(
        next.open(),
        throwsA(_vaultError('authenticationFailed')),
      );
      expect(fixture.native.calls, ['readMaster']);
      expect(fixture.legacy.reads, isEmpty);
    },
  );

  for (final status in [-128, -25293]) {
    test(
      'migration authorization $status latches until explicit checkpoint retry',
      () async {
        fixture.legacy.values.addAll({
          'a-before-identity': 'synthetic-already-checkpointed-value',
          'identity-seed': _identitySeed,
          'z-after-identity': 'synthetic-remaining-value',
        });
        fixture.legacy.deniedKey = 'identity-seed';
        fixture.legacy.denialStatus = status;
        final store = await fixture.session();
        final progress = <int>[];
        store.onSecretMigrationProgress = () {
          progress.add(store.secretMigrationProgress!.completed);
        };
        await expectLater(store.open(), throwsA(_denied(status)));
        expect(store.secretAccessBlocked, isTrue);
        expect(store.secretMigrationProgress?.completed, 1);
        expect(store.secretMigrationProgress?.remaining, 2);
        expect(store.secretMigrationProgress?.migrationComplete, isFalse);
        expect(await store.readState(_vaultMarker), {'v': 1});
        final calls = List<String>.of(fixture.native.calls);
        final reads = List<String>.of(fixture.legacy.reads);
        expect(reads, ['a-before-identity', 'identity-seed']);

        fixture.legacy.deniedKey = null;
        await expectLater(store.open(), throwsA(_denied(status)));
        await expectLater(
          store.readSecret('identity-seed'),
          throwsA(_denied(status)),
        );
        await expectLater(
          store.writeSecret('new-key', 'not-yet'),
          throwsA(_denied(status)),
        );
        await expectLater(
          store.deleteSecret('a-before-identity'),
          throwsA(_denied(status)),
        );
        expect(fixture.native.calls, calls);
        expect(fixture.legacy.reads, reads);

        store.retrySecretAccess();
        await store.open();
        expect(store.secretAccessBlocked, isFalse);
        expect(await store.readSecret('identity-seed'), _identitySeed);
        expect(
          await store.readSecret('a-before-identity'),
          'synthetic-already-checkpointed-value',
        );
        expect(await store.readSecret('new-key'), isNull);
        expect(fixture.legacy.reads, [
          'a-before-identity',
          'identity-seed',
          'identity-seed',
          'z-after-identity',
        ]);
        expect(fixture.native.calls, calls);
        expect(progress, [0, 1, 2, 3]);
        expect(store.secretMigrationProgress?.migrationComplete, isTrue);
        expect(fixture.legacy.writes, isEmpty);
        expect(fixture.legacy.deletes, isEmpty);
      },
    );
  }

  test(
    'migration checkpoint survives store restart without rereading copied keys',
    () async {
      fixture.legacy.values.addAll({
        'a-before-identity': 'synthetic-checkpoint-value',
        'identity-seed': _identitySeed,
        'z-after-identity': 'synthetic-last-value',
      });
      fixture.legacy.deniedKey = 'identity-seed';
      final first = await fixture.session();
      await expectLater(first.open(), throwsA(_denied(-128)));
      final next = await fixture.session();
      fixture.clearCalls();
      fixture.legacy.deniedKey = null;
      fixture.native.forbidLegacyList = true;
      await next.open();
      expect(fixture.native.calls, ['readMaster']);
      expect(fixture.legacy.reads, ['identity-seed', 'z-after-identity']);
      expect(
        await next.readSecret('a-before-identity'),
        'synthetic-checkpoint-value',
      );
      expect(await next.readSecret('identity-seed'), _identitySeed);
      expect(next.secretMigrationProgress?.completed, 3);
      expect(next.secretMigrationProgress?.migrationComplete, isTrue);
    },
  );

  test(
    'existing encrypted vault with missing master never creates a replacement',
    () async {
      fixture.legacy.values['identity-seed'] = _identitySeed;
      final first = await fixture.session();
      await first.open();
      final persisted = await first.readState(_vaultState);
      final next = await fixture.session();
      fixture.clearCalls();
      fixture.native.master = null;
      await expectLater(next.open(), throwsA(_vaultError('masterMissing')));
      expect(next.secretAccessBlocked, isTrue);
      expect(fixture.native.calls, ['readMaster']);
      expect(fixture.legacy.reads, isEmpty);
      expect(await next.readState(_vaultState), persisted);
    },
  );
}
