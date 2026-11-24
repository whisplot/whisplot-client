import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DepartureStore extends LocalStore {
  DepartureStore(Database database) : super(database: database);
  final secrets = <String, String>{};
  @override
  Future<String?> readSecret(String key) async => secrets[key];
  @override
  Future<void> writeSecret(String key, String value) async =>
      secrets[key] = value;
  @override
  Future<void> deleteSecret(String key) async => secrets.remove(key);
  @override
  Future<List<String>> listSecretKeys() async => secrets.keys.toList();
}

void main() {
  sqfliteFfiInit();
  sqlite.databaseFactory = databaseFactoryFfi;
  final fixture =
      jsonDecode(File('../../fixtures/protocol-v1.json').readAsStringSync())
          as Map<String, dynamic>;
  final envelope = Envelope.fromJson(fixture['envelope']);
  final group = Group(
    id: envelope.groupId,
    server: 'https://example.com',
    name: 'Archive',
    ownerId: envelope.senderId,
  );
  Envelope message(String id) =>
      Envelope.fromJson({...envelope.toJson(), 'messageId': id});
  late Database db;
  late DepartureStore store;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalStore.createSchema(db);
    store = DepartureStore(db);
    await store.saveGroup(group);
  });
  tearDown(() async => db.close());

  test('membership model accepts legacy, wire and SQLite representations', () {
    final legacy = Group.fromJson({
      'groupId': group.id,
      'name': group.name,
      'ownerId': group.ownerId,
    }, group.server);
    expect(legacy.rekeyRequired, isFalse);
    expect(legacy.membershipRevision, 0);
    final frozen = group.copyWith(
      ownerId: 'successor',
      keyEpoch: 4,
      rekeyRequired: true,
      membershipRevision: 2,
    );
    expect(
      Group.fromJson(frozen.toJson(), group.server).toJson(),
      frozen.toJson(),
    );
    expect(
      Group.fromJson(frozen.toDb(), group.server).toJson(),
      frozen.toJson(),
    );
    expect(frozen.toDb()['rekeyRequired'], 1);
    expect(frozen.copyWith(rekeyRequired: false).rekeyRequired, isFalse);
  });

  test(
    'late metadata cannot undo owner transfer or the rekey barrier',
    () async {
      final frozen = group.copyWith(
        ownerId: 'successor',
        keyEpoch: 4,
        membershipRevision: 2,
        rekeyRequired: true,
        lastSeq: 20,
      );
      await store.saveGroup(frozen);
      for (final stale in [
        group.copyWith(keyEpoch: 3, membershipRevision: 2, lastSeq: 10),
        group.copyWith(keyEpoch: 4, membershipRevision: 1, lastSeq: 9),
        group.copyWith(keyEpoch: 5, membershipRevision: 1, lastSeq: 21),
      ]) {
        await store.saveGroup(stale);
        final restored = (await store.groups(group.server)).single;
        expect(restored.keyEpoch, 4);
        expect(restored.membershipRevision, 2);
        expect(restored.ownerId, 'successor');
        expect(restored.rekeyRequired, isTrue);
        expect(restored.lastSeq, greaterThanOrEqualTo(20));
      }
      await store.saveGroup(frozen.copyWith(keyEpoch: 5, rekeyRequired: false));
      final current = (await store.groups(group.server)).single;
      expect(current.keyEpoch, 5);
      expect(current.rekeyRequired, isFalse);
      expect(current.lastSeq, 21);
    },
  );

  test(
    'leave retires only this group outbox and preserves the archive',
    () async {
      final other = Group(
        id: group.id,
        server: 'https://other.example',
        name: 'Other backend',
        ownerId: group.ownerId,
      );
      await store.saveGroup(other);
      await store.queue(group, message('pending'));
      await store.queue(other, message('other-pending'));
      await store.saveP2p(group, message('history'));
      await store.saveMembers(group, [
        Member(group.ownerId, 'archived-key', 'ID'),
      ]);
      await store.saveKey(group, List.filled(32, 23));
      await store.markGroupLeft(group, 'leave-one');
      expect(await store.groupDepartures(), {
        group.storageId: {
          'leaveId': 'leave-one',
          'groupId': group.id,
          'server': group.server,
          'pending': true,
        },
      });
      expect(await store.outbox(group), isEmpty);
      expect(await store.outbox(other), hasLength(1));
      expect(await store.groups(group.server), hasLength(1));
      expect((await store.members(group)).single.publicKey, 'archived-key');
      expect(await store.groupKey(group), List.filled(32, 23));
      expect(
        {
          for (final row in await store.messages(group))
            row['messageId']: row['state'],
        },
        {'pending': 'retired', 'history': 'p2p'},
      );
      expect(
        await LocalStore(database: db).groupDepartures(),
        await store.groupDepartures(),
      );
    },
  );

  test(
    'departed queue rejects late sends without consuming the alias state',
    () async {
      await store.updateAliasState(null, 'before', ownDeviceId: group.ownerId);
      await store.markGroupLeft(group, 'leave-one');
      for (final confirmed in [false, true]) {
        if (confirmed) await store.confirmGroupLeft(group, 'leave-one');
        await expectLater(store.queue(group, envelope), throwsStateError);
        await expectLater(
          store.queueWithAliasState(
            group,
            envelope,
            expectedState: 'before',
            nextState: 'after',
            ownDeviceId: group.ownerId,
          ),
          throwsStateError,
        );
        expect(await store.readAliasState(), 'before');
        expect(await store.messages(group), isEmpty);
      }
      await store.clearGroupDeparture(group);
      await store.queueWithAliasState(
        group,
        envelope,
        expectedState: 'before',
        nextState: 'after',
        ownDeviceId: group.ownerId,
      );
      expect(await store.readAliasState(), 'after');
      expect(await store.outbox(group), hasLength(1));
    },
  );

  test(
    'an old acknowledgement cannot confirm a newer departure or recreate one',
    () async {
      await store.markGroupLeft(group, 'first');
      await store.markGroupLeft(group, 'second');
      await store.confirmGroupLeft(group, 'first');
      expect(
        (await store.groupDepartures())[group.storageId]!['pending'],
        isTrue,
      );
      await store.confirmGroupLeft(group, 'second');
      expect(
        (await store.groupDepartures())[group.storageId]!['pending'],
        isFalse,
      );
      await store.clearGroupDeparture(group);
      await store.confirmGroupLeft(group, 'second');
      expect(await store.groupDepartures(), isEmpty);
    },
  );

  test('retirement failure rolls back the departure marker atomically', () async {
    await store.queue(group, envelope);
    await db.execute(
      "CREATE TRIGGER fail_retirement BEFORE UPDATE OF state ON messages WHEN NEW.state='retired' BEGIN SELECT RAISE(ABORT,'fixture'); END",
    );
    await expectLater(
      store.markGroupLeft(group, 'leave-one'),
      throwsA(anything),
    );
    expect(await store.groupDepartures(), isEmpty);
    expect(await store.outbox(group), hasLength(1));
  });

  test(
    'racing enqueues and departure never leave a pending outbox entry',
    () async {
      Future<void> enqueue(String id) async {
        try {
          await store.queue(group, message(id));
        } on StateError {
          // The departure transaction won and fenced this enqueue.
        }
      }

      await Future.wait([
        enqueue('before'),
        store.markGroupLeft(group, 'leave-one'),
        enqueue('during'),
      ]);
      expect(await store.outbox(group), isEmpty);
      expect(
        (await store.groupDepartures())[group.storageId]!['pending'],
        isTrue,
      );
    },
  );

  for (final oldVersion in [1, 3, 4, 5]) {
    test(
      'database v$oldVersion upgrades to v6 without losing history',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'mentor-store-migration-',
        );
        final previousPath = await databaseFactoryFfi.getDatabasesPath();
        await databaseFactoryFfi.setDatabasesPath(directory.path);
        final legacy = await databaseFactoryFfi.openDatabase(
          '${directory.path}/nearlink-v1.db',
          options: OpenDatabaseOptions(
            version: oldVersion,
            onCreate: (database, _) async {
              await LocalStore.createSchema(database);
              for (final column in [
                'joinedAt',
                'historySince',
                if (oldVersion < 4) ...['rekeyRequired', 'membershipRevision'],
              ]) {
                await database.execute(
                  'ALTER TABLE groups DROP COLUMN $column',
                );
              }
              if (oldVersion == 1) {
                await database.execute('DROP TABLE local_state');
                for (final table in {
                  'groups': [
                    'keyEpoch',
                    'protocolVersion',
                    'privacyEpoch',
                    'minClientBuild',
                  ],
                  'members': [
                    'encryptionPublicKey',
                    'clientBuild',
                    'protocolVersion',
                    'privacyEpoch',
                    'grantedKeyEpoch',
                  ],
                }.entries) {
                  for (final column in table.value) {
                    await database.execute(
                      'ALTER TABLE ${table.key} DROP COLUMN $column',
                    );
                  }
                }
              }
            },
          ),
        );
        final oldRow = group.toDb()
          ..remove('joinedAt')
          ..remove('historySince');
        if (oldVersion < 4) {
          oldRow.remove('rekeyRequired');
          oldRow.remove('membershipRevision');
        }
        if (oldVersion == 1) {
          for (final column in [
            'keyEpoch',
            'protocolVersion',
            'privacyEpoch',
            'minClientBuild',
          ]) {
            oldRow.remove(column);
          }
        } else {
          oldRow['keyEpoch'] = 6;
        }
        await legacy.insert('groups', oldRow);
        await legacy.insert('messages', {
          'storageId': group.storageId,
          'messageId': envelope.messageId,
          'envelope': jsonEncode(envelope.toJson()),
          'state': 'pending',
        });
        await legacy.close();
        final upgraded = LocalStore();
        try {
          await upgraded.open();
          expect(await upgraded.db.getVersion(), 6);
          expect((await upgraded.groups(group.server)).single.historySince, 0);
          final restored = (await upgraded.groups(group.server)).single;
          expect(restored.ownerId, group.ownerId);
          expect(restored.rekeyRequired, isFalse);
          expect(restored.membershipRevision, 0);
          expect(restored.keyEpoch, oldVersion == 1 ? 0 : 6);
          expect(await upgraded.outbox(group), hasLength(1));
          await upgraded.markGroupLeft(group, 'after-upgrade');
          expect(await upgraded.outbox(group), isEmpty);
        } finally {
          await upgraded.close();
          await databaseFactoryFfi.setDatabasesPath(previousPath);
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
