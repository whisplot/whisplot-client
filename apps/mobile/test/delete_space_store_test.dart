import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'group_departure_store_test.dart' show DepartureStore;

void main() {
  sqfliteFfiInit();
  final fixture =
      jsonDecode(File('../../fixtures/protocol-v1.json').readAsStringSync())
          as Map<String, dynamic>;
  final envelope = Envelope.fromJson(fixture['envelope']);
  final group = Group(
    id: envelope.groupId,
    server: 'https://example.com',
    name: 'Delete me',
    ownerId: envelope.senderId,
  );
  late Database db;
  late DepartureStore store;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalStore.createSchema(db);
    store = DepartureStore(db);
    await store.saveGroup(group);
  });
  tearDown(() async => db.close());

  test(
    'deletion transaction either removes the whole space or preserves every original record',
    () async {
      await store.queue(group, envelope);
      await store.saveMembers(group, [
        Member(group.ownerId, 'public-key', 'prior alias'),
      ]);
      await store.addInvite(group, 'existing-invite', 1000);
      await store.writeState('pending-rekey:${group.storageId}', {
        'context': 'pending',
      });
      await db.execute(
        "CREATE TRIGGER fail_space_delete BEFORE DELETE ON groups BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      await expectLater(
        store.markGroupDeleted(group, 'deletion'),
        throwsA(anything),
      );
      expect(await store.groupDepartures(), isEmpty);
      expect(await store.groups(group.server), hasLength(1));
      expect(await store.outbox(group), hasLength(1));
      expect(await store.members(group), hasLength(1));
      expect(await store.invitations(group), hasLength(1));
      expect(
        await store.readState('pending-rekey:${group.storageId}'),
        isNotNull,
      );
    },
  );

  test(
    'deleted-space tombstone fences late metadata, message, secret and rekey writes',
    () async {
      await store.markGroupDeleted(group, 'deletion');
      await store.saveGroup(group);
      await store.saveMembers(group, [
        Member(group.ownerId, 'old-key', 'old alias'),
      ]);
      await expectLater(store.queue(group, envelope), throwsStateError);
      await expectLater(store.saveP2p(group, envelope), throwsStateError);
      await expectLater(
        store.ingestPage(group, [
          {...envelope.toJson(), 'seq': 1, 'storedAt': 1000},
        ], 1),
        throwsStateError,
      );
      await expectLater(
        store.addInvite(group, 'late-invite', 1000),
        throwsStateError,
      );
      await expectLater(
        store.writeGroupState(group, 'pending-rekey:${group.storageId}', {
          'late': true,
        }),
        throwsStateError,
      );
      await expectLater(
        store.saveKey(group, List.filled(32, 1)),
        throwsStateError,
      );
      await expectLater(
        store.savePendingKey(group, List.filled(32, 2)),
        throwsStateError,
      );
      expect(await store.groups(group.server), isEmpty);
      expect(await store.messages(group), isEmpty);
      expect(await store.members(group), isEmpty);
      expect(await store.invitations(group), isEmpty);
      expect(await store.readState('pending-rekey:${group.storageId}'), isNull);
      expect(store.secrets, isEmpty);
    },
  );

  test(
    'a rejoin cannot clear a changed departure or unfinished cleanup',
    () async {
      await store.markGroupDeleted(group, 'first');
      await store.confirmGroupLeft(group, 'first');
      await expectLater(
        store.prepareGroupJoin(group, 'first', 100000000, newAdmission: true),
        throwsStateError,
      );
      await store.finishGroupDeletion(group);
      await store.prepareGroupJoin(
        group,
        'first',
        100000000,
        newAdmission: true,
      );
      await store.markGroupLeft(group, 'second');
      await expectLater(
        store.finishGroupJoin(group, 'first'),
        throwsStateError,
      );
      expect(
        (await store.groupDepartures())[group.storageId]!['leaveId'],
        'second',
      );
      expect(
        (await store.groupDepartures())[group.storageId]!['pending'],
        isTrue,
      );
    },
  );
}
