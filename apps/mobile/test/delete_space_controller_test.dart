import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/client_security.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/media_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'group_departure_controller_test.dart'
    show DepartureBackend, archiveMessage, reply;
import 'mandatory_update_test.dart' show SecurityFixture;
import 'media_service_test.dart' show wav;

Future<({SecurityFixture f, Directory root, MediaService media})>
newDeleteFixture() async {
  final root = await Directory.systemTemp.createTemp('mentor-delete-space-');
  addTearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  final media = MediaService(directoryProvider: () async => root);
  final f = await SecurityFixture.create(media: media);
  return (f: f, root: root, media: media);
}

Future<List<File>> groupMediaFiles(
  SecurityFixture f,
  Directory root,
  Group group,
) async {
  final prefix = '${await f.crypto.hash(utf8.encode(group.storageId))}-';
  return root
      .list(recursive: true, followLinks: false)
      .where(
        (entry) =>
            entry is File && entry.uri.pathSegments.last.startsWith(prefix),
      )
      .cast<File>()
      .toList();
}

Future<void> expectPurged(SecurityFixture f, Group group) async {
  for (final table in ['groups', 'messages', 'members', 'invitations']) {
    expect(
      await f.db.query(
        table,
        where: 'storageId=?',
        whereArgs: [group.storageId],
      ),
      isEmpty,
      reason: '$table must not retain deleted-space records',
    );
  }
  for (final epoch in [0, 1, 2]) {
    expect(await f.store.groupKey(group, epoch: epoch), isNull);
  }
  final base = 'group-key:${b64(utf8.encode(group.storageId))}';
  expect(
    f.store.secrets.keys.where(
      (key) =>
          key == base ||
          key.startsWith('$base:epoch:') ||
          key == 'pending:$base' ||
          key.startsWith('pending:$base:epoch:'),
    ),
    isEmpty,
  );
  for (final name in ['pending-rekey:', 'pending-rejoin:']) {
    expect(await f.store.readState('$name${group.storageId}'), isNull);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  for (final archived in [false, true]) {
    test(
      'deleting an ${archived ? 'archived' : 'active'} space purges its data but preserves identity and another space',
      () async {
        final fixture = await newDeleteFixture(), f = fixture.f;
        final backend = DepartureBackend(f), original = f.group;
        final other = Group(
          id: original.id,
          server: 'https://other.fixture.example',
          name: 'Keep separate origin',
          ownerId: f.identity.id,
          keyEpoch: 1,
          protocolVersion: 2,
          privacyEpoch: 2,
        );
        await f.store.saveGroup(other);
        await f.store.saveKey(other, List.filled(32, 99));
        await f.store.saveKey(original, List.filled(32, 20), epoch: 0);
        await f.store.saveKey(original, List.filled(32, 22), epoch: 2);
        await f.store.savePendingKey(
          original.copyWith(keyEpoch: 2),
          List.filled(32, 23),
        );
        await f.store.addInvite(
          original,
          'delete-invite',
          DateTime.now().millisecondsSinceEpoch + 60000,
        );
        await f.store.addInvite(
          other,
          'keep-invite',
          DateTime.now().millisecondsSinceEpoch + 60000,
        );
        await archiveMessage(f, 'deleted history');
        await archiveMessage(f, 'deleted outbox', pending: true, number: 3);
        final otherEnvelope = await f.crypto.encrypt(
          identity: f.identity,
          groupId: other.id,
          messageId: '44444444-4444-4444-8444-444444444444',
          text: 'preserved elsewhere',
          groupKey: (await f.store.groupKey(other))!,
          keyEpoch: 1,
        );
        await f.store.saveP2p(other, otherEnvelope);
        await f.store.saveMembers(other, [
          Member(f.identity.id, f.identity.publicKey, 'keep member'),
        ]);
        final cached = await fixture.media.prepareVoice(
          original,
          wav(milliseconds: 40),
        );
        await fixture.media.markMessageStored(original, cached);
        await fixture.media.prepareVoice(original, wav(milliseconds: 50));
        await fixture.media.prepareVoice(other, wav(milliseconds: 60));
        expect(await groupMediaFiles(f, fixture.root, original), hasLength(2));
        final identitySeed = await f.store.readSecret('identity-seed');
        final settings = await f.store.readSecret(
          ChatController.connectionSettingsKey,
        );
        if (archived) {
          await backend.leaveConfirmed();
        } else {
          f.selectGroup();
        }
        await f.store.writeState('pending-rekey:${original.storageId}', {
          'fixture': true,
        });
        final leavesBeforeDelete = backend.leaveIds.length;
        await f.controller.deleteGroupLocallyAndLeave(original.storageId);
        await f.controller.reconnect();
        expect(f.controller.groups, isEmpty);
        expect(f.controller.leftGroups, isEmpty);
        expect(f.controller.activeGroup, isNull);
        expect(f.controller.messages, isEmpty);
        await expectPurged(f, original);
        expect(await groupMediaFiles(f, fixture.root, original), isEmpty);
        expect(await groupMediaFiles(f, fixture.root, other), hasLength(1));
        expect(await f.store.readSecret('identity-seed'), identitySeed);
        expect(
          await f.store.readSecret(ChatController.connectionSettingsKey),
          settings,
        );
        expect(
          (await f.store.groups(other.server)).single.storageId,
          other.storageId,
        );
        expect(
          (await f.store.messages(other)).single['messageId'],
          otherEnvelope.messageId,
        );
        expect(await f.store.groupKey(other), List.filled(32, 99));
        expect(await f.store.members(other), hasLength(1));
        expect(await f.store.invitations(other), hasLength(1));
        expect(
          backend.leaveIds.length,
          archived ? leavesBeforeDelete : leavesBeforeDelete + 1,
        );
        expect((await f.store.groupDepartures())[original.storageId], {
          'leaveId': backend.leaveIds.single,
          'groupId': original.id,
          'server': original.server,
          'pending': false,
          'deleted': true,
          'cleanupPending': false,
        });
      },
    );
  }

  test(
    'offline deletion survives restart with only a minimal retry tombstone',
    () async {
      final fixture = await newDeleteFixture(), f = fixture.f;
      final backend = DepartureBackend(f)..offline = true;
      final original = f.group;
      await archiveMessage(f, 'must disappear even offline');
      await fixture.media.prepareVoice(original, wav(milliseconds: 40));
      f.selectGroup();
      await f.controller.deleteGroupLocallyAndLeave(original.storageId);
      final tombstone = (await f.store.groupDepartures())[original.storageId]!;
      expect(tombstone.keys.toSet(), {
        'leaveId',
        'groupId',
        'server',
        'pending',
        'deleted',
        'cleanupPending',
      });
      expect(tombstone, containsPair('pending', true));
      expect(tombstone, containsPair('deleted', true));
      await expectPurged(f, original);
      expect(await groupMediaFiles(f, fixture.root, original), isEmpty);
      f.controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await f.start();
      expect(f.controller.groups, isEmpty);
      expect(f.controller.leftGroups, isEmpty);
      expect(f.controller.pendingGroupLeaveCount, 1);
      backend.offline = false;
      await f.controller.reconnect();
      expect(f.controller.pendingGroupLeaveCount, 0);
      expect(backend.leaveIds.toSet(), {tombstone['leaveId']});
      expect(backend.leaveIds.length, greaterThanOrEqualTo(2));
      await expectPurged(f, original);
    },
  );

  test('delayed and stale listings cannot recreate a deleted space', () async {
    final fixture = await newDeleteFixture(), f = fixture.f;
    final backend = DepartureBackend(f), original = f.group;
    final entered = Completer<void>(), response = Completer<http.Response>();
    backend.listEntered = entered;
    backend.heldList = response;
    final oldListing = expectLater(
      f.controller.refreshGroups(),
      throwsA(isA<TransportChangedException>()),
    );
    await entered.future;
    await f.controller.deleteGroupLocallyAndLeave(original.storageId);
    response.complete(
      reply({
        'groups': [original.toJson()],
      }),
    );
    await oldListing;
    backend.joined = true;
    await f.controller.refreshGroups();
    expect(f.controller.groups, isEmpty);
    expect(f.controller.leftGroups, isEmpty);
    await expectPurged(f, original);
    expect(
      (await f.store.groupDepartures())[original.storageId]!['deleted'],
      isTrue,
    );
  });

  test(
    'a sync response arriving after deletion cannot restore messages or keys',
    () async {
      final fixture = await newDeleteFixture(), f = fixture.f;
      final backend = DepartureBackend(f), original = f.group;
      final oldMessage = await archiveMessage(f, 'held server message');
      final entered = Completer<void>(), response = Completer<http.Response>();
      f.extraHandler = (request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
          if (!entered.isCompleted) {
            entered.complete();
            return response.future;
          }
        }
        return backend.handle(request);
      };
      f.selectGroup();
      final oldSync = expectLater(
        f.controller.syncActive(),
        throwsA(isA<TransportChangedException>()),
      );
      await entered.future;
      await f.controller.deleteGroupLocallyAndLeave(original.storageId);
      response.complete(
        reply({
          'messages': [
            {
              ...oldMessage.toJson(),
              'seq': 1,
              'storedAt': DateTime.now().millisecondsSinceEpoch,
            },
          ],
          'nextCursor': 1,
          'hasMore': false,
        }),
      );
      await oldSync;
      await expectPurged(f, original);
      expect(f.controller.activeGroup, isNull);
      expect(f.controller.messages, isEmpty);
    },
  );

  for (final lostResponse in [false, true]) {
    test(
      '${lostResponse ? 'lost-response recovery' : 'explicit rejoin'} after deletion starts with no old history or keys',
      () async {
        final fixture = await newDeleteFixture(), f = fixture.f;
        final backend = DepartureBackend(f), original = f.group;
        await archiveMessage(f, 'must not return after rejoin');
        await f.controller.deleteGroupLocallyAndLeave(original.storageId);
        await f.controller.reconnect();
        final invite = backend.invitation();
        final admissionStart = DateTime.now().millisecondsSinceEpoch;
        if (lostResponse) {
          // The deployed older backend has no admission fields. A lost reply
          // must recover the locally persisted boundary, not unlimited history.
          f.extraHandler = (request) async {
            final response = await backend.handle(request);
            if (response != null && response.statusCode == 200) {
              final data = jsonDecode(response.body) as Map<String, dynamic>;
              if (data['groups'] is List) {
                for (final group in data['groups'] as List) {
                  (group as Map).remove('joinedAt');
                  group.remove('historySince');
                }
              } else if (data['groupId'] == original.id &&
                  data['left'] != true) {
                data.remove('joinedAt');
                data.remove('historySince');
              }
              return reply(data);
            }
            if (request.method == 'GET' &&
                request.url.path == '/v1/groups/${original.id}') {
              final data = f.group.toJson()
                ..remove('joinedAt')
                ..remove('historySince');
              return reply({
                ...data,
                'members': [
                  {
                    'deviceId': f.identity.id,
                    'publicKey': f.identity.publicKey,
                    'displayName': '匿名成员',
                    'encryptionPublicKey': f.encryptionKey,
                    'clientBuild': AppSecurity.clientBuild,
                    'protocolVersion': 2,
                    'privacyEpoch': 2,
                    'grantedKeyEpoch': f.group.keyEpoch,
                  },
                ],
              });
            }
            return response;
          };
        }
        backend.loseJoinResponse = lostResponse;
        if (lostResponse) {
          await expectLater(
            f.controller.join(invite),
            throwsA(isA<SocketException>()),
          );
          f.controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await f.start();
        } else {
          await f.controller.join(invite);
        }
        expect(f.controller.groups.single.keyEpoch, 3);
        if (lostResponse) {
          final recovered = f.controller.groups.single;
          expect(recovered.joinedAt, greaterThanOrEqualTo(admissionStart));
          expect(recovered.historySince, greaterThan(0));
          expect(
            recovered.historySince,
            recovered.joinedAt - const Duration(hours: 24).inMilliseconds,
          );
          expect(
            await f.store.readState('pending-admission:${original.storageId}'),
            isNull,
          );
        }
        expect(f.controller.leftGroups, isEmpty);
        expect(await f.store.groupDepartures(), isEmpty);
        expect(await f.store.messages(f.group), isEmpty);
        expect(await f.store.groupKey(original, epoch: 1), isNull);
        expect(await f.store.groupKey(f.group), unb64(invite.groupKey));
        // The media deletion fence is lifted only by this explicit admission.
        await fixture.media.prepareVoice(f.group, wav(milliseconds: 40));
        expect(await groupMediaFiles(f, fixture.root, f.group), hasLength(1));
      },
    );
  }
}
