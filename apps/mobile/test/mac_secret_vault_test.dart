import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/mac_secret_vault.dart';

class FakeVaultIo {
  List<int>? master;
  String? encrypted;
  bool initialized = false;
  final legacy = <String, String>{};
  final calls = <String>[];
  final checkpoints = <String>[];
  Future<List<int>?> Function()? masterRead;
  Future<List<int>> Function()? masterCreate;
  Future<List<String>> Function()? legacyList;
  Future<String?> Function(String)? legacyRead;
  Future<void> Function(String)? encryptedSave;
  Future<bool> Function()? initializationCheck;

  MacSecretVault vault({
    void Function(MacVaultMigrationProgress)? onProgress,
  }) => MacSecretVault(
    loadEncrypted: () async {
      calls.add('load');
      return encrypted;
    },
    saveEncrypted: (value) async {
      calls.add('save');
      if (encryptedSave != null) {
        await encryptedSave!(value);
      } else {
        commit(value);
      }
    },
    readMaster: () async {
      calls.add('master-read');
      if (masterRead != null) return masterRead!();
      return master == null ? null : [...master!];
    },
    createMaster: () async {
      calls.add('master-create');
      if (masterCreate != null) return masterCreate!();
      if (master != null) throw StateError('duplicate');
      master = List.generate(32, (i) => i + 1);
      return [...master!];
    },
    listLegacyKeys: () async {
      calls.add('legacy-list');
      return legacyList == null ? legacy.keys.toList() : await legacyList!();
    },
    readLegacy: (key) async {
      calls.add('legacy-read:$key');
      return legacyRead == null ? legacy[key] : await legacyRead!(key);
    },
    canInitialize: () async {
      calls.add('can-initialize');
      if (initializationCheck != null) return initializationCheck!();
      return !initialized;
    },
    onProgress: onProgress,
  );

  void commit(String value) {
    encrypted = value;
    initialized = true;
    checkpoints.add(value);
  }

  int count(String call) => calls.where((value) => value == call).length;
}

Matcher vaultError(String code) =>
    isA<MacSecretVaultException>().having((error) => error.code, 'code', code);

Future<String> sealFixture(
  List<int> master,
  Object plaintext, {
  String? aad,
}) async {
  final cipher = AesGcm.with256bits();
  final box = await cipher.encrypt(
    utf8.encode(jsonEncode(plaintext)),
    secretKey: SecretKey(master),
    nonce: cipher.newNonce(),
    aad: utf8.encode(aad ?? 'com.nearlink.chat/mac-secret-vault/v1'),
  );
  return jsonEncode({
    'v': 1,
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'mac': base64Encode(box.mac.bytes),
  });
}

Map<String, Object> completeFixture() => {
  'schema': 1,
  'secrets': {'identity-seed': 'original identity'},
  'migrationComplete': true,
  'remainingLegacyKeys': <String>[],
  'migrationTotal': 1,
};

void main() {
  test(
    'migration checkpoints secrets without plaintext persistence or old writes',
    () async {
      final io = FakeVaultIo()
        ..legacy.addAll({
          'identity-seed': 'sensitive original device identity',
          'group-key:old:epoch:1': 'sensitive historical group secret',
          'group-key:old:epoch:2': 'sensitive current group secret',
        });
      final progress = <MacVaultMigrationProgress>[];
      final vault = io.vault(onProgress: progress.add);
      await vault.open();
      expect(await vault.read('identity-seed'), io.legacy['identity-seed']);
      expect(vault.isOpen, isTrue);
      expect(vault.accessBlocked, isFalse);
      expect(io.checkpoints, hasLength(4));
      expect(progress.map((p) => p.completed), [0, 1, 2, 3]);
      expect(progress.last.total, 3);
      expect(progress.last.migrationComplete, isTrue);
      expect(io.count('master-read'), 1);
      expect(io.count('master-create'), 1);
      for (final encrypted in io.checkpoints) {
        for (final entry in io.legacy.entries) {
          expect(encrypted, isNot(contains(entry.key)));
          expect(encrypted, isNot(contains(entry.value)));
        }
      }
      expect(io.legacy, hasLength(3));
      vault.close();
    },
  );

  test(
    'concurrent opens share migration and later operations avoid Keychain',
    () async {
      final io = FakeVaultIo()..legacy['identity-seed'] = 'original';
      final vault = io.vault();
      await Future.wait(List.generate(30, (_) => vault.open()));
      await Future.wait(List.generate(30, (_) => vault.read('identity-seed')));
      await vault.write('group-key:one', 'secret one');
      await vault.write('group-key:two', 'secret two');
      await vault.delete('group-key:one');
      expect(io.count('master-read'), 1);
      expect(io.count('master-create'), 1);
      expect(io.count('legacy-list'), 1);
      expect(io.count('legacy-read:identity-seed'), 1);
      expect(await vault.read('group-key:one'), isNull);
      expect(await vault.read('group-key:two'), 'secret two');
      final nonceValues = io.checkpoints.map(
        (checkpoint) => (jsonDecode(checkpoint) as Map)['nonce'],
      );
      expect(nonceValues.toSet(), hasLength(io.checkpoints.length));
      vault.close();
    },
  );

  test(
    'key enumeration stays in the current vault and shares one master access',
    () async {
      final io = FakeVaultIo()
        ..legacy.addAll({
          'identity-seed': 'original',
          'group-key:one:epoch:1': 'old group secret',
        });
      final initial = io.vault();
      await initial.open();
      initial.close();
      io.calls.clear();
      final vault = io.vault();
      final results = await Future.wait(List.generate(20, (_) => vault.keys()));
      expect(
        results.every((keys) => keys.toSet().containsAll(io.legacy.keys)),
        isTrue,
      );
      expect(io.count('master-read'), 1);
      expect(io.count('master-create'), 0);
      expect(io.count('legacy-list'), 0);
      expect(io.count('legacy-read:identity-seed'), 0);
      final detached = await vault.keys();
      detached[0] = 'changed by caller';
      expect(await vault.keys(), isNot(contains('changed by caller')));
      await vault.delete('group-key:one:epoch:1');
      expect(await vault.keys(), ['identity-seed']);
      expect(io.count('master-read'), 1);
      vault.close();
      await expectLater(vault.keys(), throwsA(vaultError('closed')));
    },
  );

  test(
    'denial keeps checkpoint and blocks normal writes until explicit retry',
    () async {
      final io = FakeVaultIo()..legacy.addAll({'a': 'first', 'b': 'second'});
      final denial = StateError('user denied legacy b');
      var deny = true;
      io.legacyRead = (key) async {
        if (key == 'b' && deny) throw denial;
        return io.legacy[key];
      };
      final vault = io.vault();
      await expectLater(vault.open(), throwsA(same(denial)));
      expect(vault.accessBlocked, isTrue);
      expect(vault.progress.completed, 1);
      expect(vault.progress.remaining, 1);
      expect(vault.isOpen, isFalse);
      final checkpoint = io.encrypted;
      await expectLater(
        vault.write('identity-seed', 'replacement'),
        throwsA(same(denial)),
      );
      await expectLater(vault.read('a'), throwsA(same(denial)));
      expect(io.encrypted, checkpoint);
      expect(io.count('legacy-read:b'), 1);
      deny = false;
      vault.retryAccess();
      await vault.open();
      expect(await vault.read('a'), 'first');
      expect(await vault.read('b'), 'second');
      expect(io.count('legacy-read:a'), 1);
      expect(io.count('legacy-read:b'), 2);
      expect(io.count('master-read'), 1);
      expect(io.legacy, {'a': 'first', 'b': 'second'});
      vault.close();
    },
  );

  test('a new process resumes only uncompleted legacy items', () async {
    final io = FakeVaultIo()..legacy.addAll({'a': 'first', 'b': 'second'});
    io.legacyRead = (key) async {
      if (key == 'b') throw StateError('interrupted');
      return io.legacy[key];
    };
    final first = io.vault();
    await expectLater(first.open(), throwsStateError);
    first.close();
    io.legacyRead = null;
    io.calls.clear();
    final restarted = io.vault();
    await restarted.open();
    expect(io.count('legacy-read:a'), 0);
    expect(io.count('legacy-read:b'), 1);
    expect(io.count('legacy-list'), 0);
    expect(io.count('master-read'), 1);
    expect(io.count('master-create'), 0);
    expect(await restarted.read('a'), 'first');
    restarted.close();
  });

  test(
    'a listed legacy item returning null cannot silently finish migration',
    () async {
      final io = FakeVaultIo()..legacy['identity-seed'] = 'original';
      io.legacyRead = (_) async => null;
      final vault = io.vault();
      await expectLater(vault.open(), throwsA(vaultError('legacyItemMissing')));
      expect(vault.progress.completed, 0);
      expect(vault.progress.migrationComplete, isFalse);
      expect(io.legacy['identity-seed'], 'original');
      vault.close();
    },
  );

  test(
    'write failure reloads prior durable state without another master read',
    () async {
      final io = FakeVaultIo()..legacy['identity-seed'] = 'original';
      final vault = io.vault();
      await vault.open();
      final original = io.encrypted;
      io.encryptedSave = (_) async => throw StateError('disk full');
      await expectLater(
        vault.write('identity-seed', 'replacement'),
        throwsStateError,
      );
      expect(vault.accessBlocked, isTrue);
      expect(io.encrypted, original);
      io.encryptedSave = null;
      vault.retryAccess();
      expect(await vault.read('identity-seed'), 'original');
      expect(io.count('master-read'), 1);
      vault.close();
    },
  );

  test(
    'ambiguous save failure reconciles committed data after explicit retry',
    () async {
      final io = FakeVaultIo();
      final vault = io.vault();
      await vault.open();
      io.encryptedSave = (value) async {
        io.commit(value);
        throw StateError('commit completed but acknowledgement failed');
      };
      await expectLater(
        vault.write('group-key', 'committed'),
        throwsStateError,
      );
      io.encryptedSave = null;
      vault.retryAccess();
      expect(await vault.read('group-key'), 'committed');
      expect(io.count('master-read'), 1);
      vault.close();
    },
  );

  test(
    'existing vault without master fails without creating or reading legacy',
    () async {
      final io = FakeVaultIo();
      final old = io.vault();
      await old.open();
      old.close();
      io.master = null;
      io.calls.clear();
      final vault = io.vault();
      await expectLater(vault.open(), throwsA(vaultError('masterMissing')));
      expect(io.count('master-create'), 0);
      expect(io.count('legacy-list'), 0);
      vault.close();
    },
  );

  test(
    'initialized marker prevents deleted vault from creating a fresh identity',
    () async {
      final io = FakeVaultIo()..initialized = true;
      final vault = io.vault();
      await expectLater(vault.open(), throwsA(vaultError('vaultMissing')));
      expect(io.count('master-read'), 0);
      expect(io.count('master-create'), 0);
      expect(io.count('legacy-list'), 0);
      vault.close();
    },
  );

  test(
    'tampered ciphertext is rejected rather than falling back to old secrets',
    () async {
      final io = FakeVaultIo()..legacy['identity-seed'] = 'original';
      final old = io.vault();
      await old.open();
      old.close();
      final envelope = jsonDecode(io.encrypted!) as Map<String, dynamic>;
      final bytes = base64Decode(envelope['ciphertext'] as String);
      bytes[0] ^= 1;
      envelope['ciphertext'] = base64Encode(bytes);
      io.encrypted = jsonEncode(envelope);
      io.calls.clear();
      final vault = io.vault();
      await expectLater(
        vault.open(),
        throwsA(vaultError('authenticationFailed')),
      );
      expect(io.count('master-create'), 0);
      expect(io.count('legacy-list'), 0);
      expect(io.count('legacy-read:identity-seed'), 0);
      vault.close();
    },
  );

  test('AEAD domain is required when restoring a vault', () async {
    final io = FakeVaultIo()..master = List.filled(32, 7);
    io.encrypted = await sealFixture(
      io.master!,
      completeFixture(),
      aad: 'another app',
    );
    final vault = io.vault();
    await expectLater(
      vault.open(),
      throwsA(vaultError('authenticationFailed')),
    );
    expect(io.count('master-create'), 0);
    vault.close();
  });

  test(
    'malformed authenticated snapshots and malformed envelopes fail closed',
    () async {
      final malformed = <Object>[
        {'schema': 1},
        {...completeFixture(), 'schema': 2},
        {...completeFixture(), 'schema': 1.0},
        {
          ...completeFixture(),
          'secrets': {'identity-seed': null},
        },
        {
          ...completeFixture(),
          'remainingLegacyKeys': ['identity-seed'],
        },
        {...completeFixture(), 'migrationComplete': false},
        {...completeFixture(), 'migrationTotal': -1},
        {...completeFixture(), 'unrecognized': 'field'},
      ];
      for (final payload in malformed) {
        final io = FakeVaultIo()..master = List.filled(32, 9);
        io.encrypted = await sealFixture(io.master!, payload);
        final vault = io.vault();
        await expectLater(vault.open(), throwsA(vaultError('invalidVault')));
        expect(io.count('master-create'), 0);
        expect(io.count('legacy-list'), 0);
        vault.close();
      }
      for (final encoded in [
        'not json',
        '{}',
        '{"v":99}',
        '{"v":1,"nonce":null}',
      ]) {
        final io = FakeVaultIo()
          ..master = List.filled(32, 9)
          ..encrypted = encoded;
        final vault = io.vault();
        await expectLater(vault.open(), throwsA(vaultError('invalidVault')));
        expect(io.count('master-create'), 0);
        vault.close();
      }
    },
  );

  test(
    'master creation failure has no implicit retry or replacement',
    () async {
      final io = FakeVaultIo();
      io.masterCreate = () async {
        io.master = List.filled(32, 42);
        throw StateError('duplicate or lost response');
      };
      final vault = io.vault();
      await expectLater(vault.open(), throwsStateError);
      expect(io.count('master-read'), 1);
      expect(io.count('master-create'), 1);
      expect(io.count('save'), 0);
      await expectLater(vault.open(), throwsStateError);
      expect(io.count('master-read'), 1);
      vault.retryAccess();
      await vault.open();
      expect(io.count('master-read'), 2);
      expect(io.count('master-create'), 1);
      expect(io.master, List.filled(32, 42));
      vault.close();
    },
  );

  test(
    'crash before first snapshot can reuse the already stored master',
    () async {
      final io = FakeVaultIo();
      io.encryptedSave = (_) async =>
          throw StateError('crash before DB commit');
      final first = io.vault();
      await expectLater(first.open(), throwsStateError);
      final master = [...io.master!];
      first.close();
      expect(io.initialized, isFalse);
      io.encryptedSave = null;
      io.calls.clear();
      final restarted = io.vault();
      await restarted.open();
      expect(io.master, master);
      expect(io.count('master-create'), 0);
      expect(restarted.isOpen, isTrue);
      restarted.close();
    },
  );

  test(
    'deleted values stay deleted after reopen despite preserved old Keychain items',
    () async {
      final io = FakeVaultIo()..legacy['old-key'] = 'preserved old copy';
      final vault = io.vault();
      await vault.open();
      await vault.delete('old-key');
      vault.close();
      io.calls.clear();
      final restarted = io.vault();
      expect(await restarted.read('old-key'), isNull);
      expect(io.legacy['old-key'], 'preserved old copy');
      expect(io.count('master-read'), 1);
      expect(io.count('legacy-list'), 0);
      expect(io.count('legacy-read:old-key'), 0);
      restarted.close();
    },
  );

  test(
    'close during master read prevents any late initialization or queued write',
    () async {
      final io = FakeVaultIo();
      final entered = Completer<void>();
      final pending = Completer<List<int>?>();
      io.masterRead = () {
        entered.complete();
        return pending.future;
      };
      final vault = io.vault();
      final opening = vault.open();
      final queued = vault.write('identity-seed', 'must not persist');
      final assertions = Future.wait([
        expectLater(opening, throwsA(vaultError('closed'))),
        expectLater(queued, throwsA(vaultError('closed'))),
      ]);
      await entered.future;
      vault.close();
      pending.complete(List.filled(32, 8));
      await assertions;
      expect(io.count('save'), 0);
      expect(io.count('master-create'), 0);
      expect(io.count('legacy-list'), 0);
      expect(vault.isOpen, isFalse);
      await expectLater(
        vault.read('identity-seed'),
        throwsA(vaultError('closed')),
      );
    },
  );

  test(
    'cancelled legacy result cannot enter checkpoint and retry resumes safely',
    () async {
      final io = FakeVaultIo()..legacy['identity-seed'] = 'original';
      final entered = Completer<void>();
      final pending = Completer<String?>();
      io.legacyRead = (_) {
        entered.complete();
        return pending.future;
      };
      final vault = io.vault();
      final opening = vault.open();
      final assertion = expectLater(opening, throwsA(vaultError('cancelled')));
      await entered.future;
      final checkpoint = io.encrypted;
      vault.cancelAccess();
      pending.complete('late value must not be adopted');
      await assertion;
      expect(io.encrypted, checkpoint);
      expect(vault.isOpen, isFalse);
      expect(vault.accessBlocked, isTrue);
      io.legacyRead = null;
      vault.retryAccess();
      await vault.open();
      expect(await vault.read('identity-seed'), 'original');
      expect(vault.progress.migrationComplete, isTrue);
      vault.close();
    },
  );

  test(
    'closing while a commit is in flight does not resurrect the session',
    () async {
      final io = FakeVaultIo();
      final vault = io.vault();
      await vault.open();
      final entered = Completer<void>();
      final release = Completer<void>();
      io.encryptedSave = (value) async {
        entered.complete();
        await release.future;
        io.commit(value);
      };
      final write = vault.write('key', 'value');
      final assertion = expectLater(write, throwsA(vaultError('closed')));
      await entered.future;
      vault.close();
      release.complete();
      await assertion;
      expect(vault.isOpen, isFalse);
      await expectLater(vault.read('key'), throwsA(vaultError('closed')));
    },
  );

  test(
    'unchanged writes and nonexistent deletes do not commit again',
    () async {
      final io = FakeVaultIo()..legacy['key'] = 'value';
      final vault = io.vault();
      await vault.open();
      final count = io.count('save');
      await vault.write('key', 'value');
      await vault.delete('absent');
      expect(io.count('save'), count);
      vault.close();
    },
  );

  test(
    'an observer failure cannot invalidate a successful migration',
    () async {
      final io = FakeVaultIo();
      final vault = io.vault(
        onProgress: (_) => throw StateError('disposed UI'),
      );
      await vault.open();
      expect(vault.isOpen, isTrue);
      expect(vault.accessBlocked, isFalse);
      vault.close();
    },
  );

  test(
    'progress callback can close fresh or restored vault without late work',
    () async {
      for (final restore in [false, true]) {
        final io = FakeVaultIo();
        if (restore) {
          final original = io.vault();
          await original.open();
          original.close();
        }
        io.calls.clear();
        late MacSecretVault vault;
        vault = io.vault(onProgress: (_) => vault.close());
        await expectLater(vault.open(), throwsA(vaultError('closed')));
        expect(vault.isOpen, isFalse);
        final completedCalls = [...io.calls];
        await expectLater(vault.read('key'), throwsA(vaultError('closed')));
        await expectLater(
          vault.write('key', 'value'),
          throwsA(vaultError('closed')),
        );
        expect(io.calls, completedCalls);
      }
    },
  );

  test(
    'progress cancellation preserves checkpoint and stops the next legacy read',
    () async {
      final io = FakeVaultIo()..legacy.addAll({'a': 'first', 'b': 'second'});
      var shouldCancel = true;
      late MacSecretVault vault;
      vault = io.vault(
        onProgress: (progress) {
          if (progress.completed == 1 && shouldCancel) {
            shouldCancel = false;
            vault.cancelAccess();
          }
        },
      );
      await expectLater(vault.open(), throwsA(vaultError('cancelled')));
      expect(io.count('legacy-read:a'), 1);
      expect(io.count('legacy-read:b'), 0);
      expect(vault.isOpen, isFalse);
      vault.retryAccess();
      await vault.open();
      expect(await vault.read('a'), 'first');
      expect(await vault.read('b'), 'second');
      expect(io.count('legacy-read:a'), 1);
      expect(io.count('legacy-read:b'), 1);
      vault.close();
    },
  );

  test(
    'cancel during initialization marker check reports cancellation before Keychain',
    () async {
      final io = FakeVaultIo();
      final entered = Completer<void>();
      final pending = Completer<bool>();
      io.initializationCheck = () {
        entered.complete();
        return pending.future;
      };
      final vault = io.vault();
      final opening = vault.open();
      final assertion = expectLater(opening, throwsA(vaultError('cancelled')));
      await entered.future;
      vault.cancelAccess();
      pending.complete(false);
      await assertion;
      expect(io.count('master-read'), 0);
      expect(io.count('master-create'), 0);
      vault.close();
    },
  );

  test(
    'invalid master and duplicate legacy names fail without a snapshot',
    () async {
      for (final master in [
        <int>[],
        List.filled(31, 3),
        List.filled(32, 256),
      ]) {
        final io = FakeVaultIo()..master = master;
        final vault = io.vault();
        await expectLater(vault.open(), throwsA(vaultError('invalidMaster')));
        expect(io.count('save'), 0);
        expect(io.count('master-create'), 0);
        vault.close();
      }
      final io = FakeVaultIo()..legacyList = () async => ['same', 'same'];
      final vault = io.vault();
      await expectLater(vault.open(), throwsA(vaultError('invalidLegacyList')));
      expect(io.count('save'), 0);
      vault.close();
    },
  );
}
