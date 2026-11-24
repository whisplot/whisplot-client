import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  final fixture =
      jsonDecode(File('../../fixtures/protocol-v1.json').readAsStringSync())
          as Map<String, dynamic>;
  final envelope = Envelope.fromJson(fixture['envelope']);
  final group = Group(
    id: envelope.groupId,
    server: 'https://example.com',
    name: '测试',
    ownerId: envelope.senderId,
  );
  late Database db;
  late LocalStore store;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalStore.createSchema(db);
    store = LocalStore(database: db);
    await store.saveGroup(group);
  });
  tearDown(() async => db.close());
  test(
    'concurrent policy observations cannot lower a persisted floor',
    () async {
      await Future.wait([
        store.mergePolicyFloor('policy', {
          'policyRevision': 4,
          'minClientBuild': 9,
          'protocolVersion': 3,
          'privacyEpoch': 3,
        }),
        store.mergePolicyFloor('policy', {
          'policyRevision': 5,
          'minClientBuild': 5,
          'protocolVersion': 2,
          'privacyEpoch': 2,
        }),
      ]);
      expect(await store.readState('policy'), {
        'policyRevision': 5,
        'minClientBuild': 9,
        'protocolVersion': 3,
        'privacyEpoch': 3,
      });
    },
  );

  test('group metadata cannot downgrade a committed key epoch', () async {
    await store.saveGroup(
      group.copyWith(
        keyEpoch: 3,
        protocolVersion: 2,
        privacyEpoch: 2,
        minClientBuild: 5,
      ),
    );
    await store.saveGroup(group);
    final restored = (await store.groups(group.server)).single;
    expect(restored.keyEpoch, 3);
    expect(restored.privacyEpoch, 2);
    expect(restored.minClientBuild, 5);
  });
  test(
    'Outbox survives retries and merges with server page by message ID',
    () async {
      await store.queue(group, envelope);
      await store.queue(group, envelope);
      expect((await store.outbox(group)).length, 1);
      await store.markStored(group, envelope.messageId, 1, 100);
      expect(await store.outbox(group), isEmpty);
      expect(
        await store.cursor(group),
        0,
      ); // posting alone must not skip earlier messages
      await store.ingestPage(group, [
        {...envelope.toJson(), 'seq': 1, 'storedAt': 100},
      ], 1);
      expect((await store.messages(group)).length, 1);
      expect(await store.cursor(group), 1);
    },
  );
  test(
    'Poison envelope is quarantined without blocking later valid messages',
    () async {
      final invalid = {
        ...envelope.toJson(),
        'messageId': 'bad',
        'ciphertext': 'invalid',
        'seq': 1,
        'storedAt': 100,
      };
      await store.ingestPage(
        group,
        [
          invalid,
          {...envelope.toJson(), 'seq': 2, 'storedAt': 101},
        ],
        2,
        invalidIds: {'bad'},
      );
      expect(await store.cursor(group), 2);
      expect(await store.quarantinedCount(group), 1);
      final visible = await store.messages(group);
      expect(visible.length, 1);
      expect(visible.first['messageId'], envelope.messageId);
    },
  );
  test('Canonical verified envelope replaces a conflicting P2P copy', () async {
    await store.saveP2p(group, envelope);
    final changed = {
      ...envelope.toJson(),
      'signature': b64(List.filled(64, 3)),
      'seq': 1,
      'storedAt': 100,
    };
    expect(await store.ingestPage(group, [changed], 1), 1);
    final stored = jsonDecode(
      (await store.messages(group)).single['envelope'] as String,
    );
    expect(stored['signature'], changed['signature']);
  });
  test(
    'Failing transaction cannot advance cursor or partially persist page',
    () async {
      final second = {
        ...envelope.toJson(),
        'messageId': 'another',
        'seq': 1,
        'storedAt': 100,
      };
      await expectLater(
        store.ingestPage(group, [
          {...envelope.toJson(), 'seq': 1, 'storedAt': 100},
          second,
        ], 2),
        throwsA(anything),
      );
      expect(await store.cursor(group), 0);
      expect(await store.messages(group), isEmpty);
    },
  );
  test('Same group ID on another backend remains isolated', () async {
    final other = Group(
      id: group.id,
      server: 'https://other.example',
      name: 'Other',
      ownerId: group.ownerId,
    );
    await store.saveGroup(other);
    await store.queue(group, envelope);
    expect(await store.outbox(other), isEmpty);
    expect(await store.cursor(other), 0);
  });
}
