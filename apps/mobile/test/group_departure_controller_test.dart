import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nearlink/core/client_security.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'mandatory_update_test.dart' show SecurityFixture;

http.Response reply(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

class DepartureBackend {
  DepartureBackend(this.fixture) {
    fixture.extraHandler = handle;
  }
  final SecurityFixture fixture;
  bool joined = true, offline = false, loseJoinResponse = false;
  final leaveIds = <String>[];
  Completer<void>? listEntered;
  Completer<http.Response>? heldList;

  Future<http.Response?> handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/leave')) {
      final data = jsonDecode(request.body) as Map<String, dynamic>;
      leaveIds.add(data['leaveId'] as String);
    }
    if (offline) throw const SocketException('fixture offline');
    if (path.endsWith('/leave')) {
      final data = jsonDecode(request.body) as Map<String, dynamic>;
      joined = false;
      return reply({
        'left': true,
        'leaveId': data['leaveId'],
        'groupId': fixture.group.id,
      });
    }
    if (path.endsWith('/join')) {
      final data = jsonDecode(request.body) as Map<String, dynamic>;
      fixture.group = fixture.group.copyWith(
        keyEpoch: data['keyEpoch'] as int,
        membershipRevision: fixture.group.membershipRevision + 2,
        minClientBuild: AppSecurity.clientBuild,
        rekeyRequired: false,
      );
      joined = true;
      if (loseJoinResponse) {
        loseJoinResponse = false;
        throw const SocketException('join committed but response lost');
      }
      return reply(fixture.group.toJson());
    }
    if (path == '/v1/groups' && request.method == 'GET') {
      final pending = heldList;
      if (pending != null) {
        heldList = null;
        listEntered!.complete();
        return pending.future;
      }
      return reply({
        'groups': joined ? [fixture.group.toJson()] : [],
      });
    }
    if (!joined && path == '/v1/groups/${fixture.group.id}') {
      return reply({
        'error': {'code': 'not_a_member', 'message': 'left'},
      }, 403);
    }
    return null;
  }

  Future<void> leaveConfirmed() async {
    fixture.selectGroup();
    expect(await fixture.controller.leaveActiveGroup(), isTrue);
    await fixture.controller.reconnect();
  }

  Invite invitation() => Invite(
    server: fixture.group.server,
    groupId: fixture.group.id,
    name: fixture.group.name,
    inviteId: '33333333-3333-4333-8333-333333333333',
    secret: b64(List.filled(32, 17)),
    groupKey: b64(List.filled(32, 71)),
    expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
    keyEpoch: 3,
    protocolVersion: 2,
    privacyEpoch: 2,
    minClientBuild: AppSecurity.clientBuild,
  );
}

Future<Envelope> archiveMessage(
  SecurityFixture fixture,
  String text, {
  bool pending = false,
  Identity? sender,
  int number = 2,
}) async {
  final envelope = await fixture.crypto.encrypt(
    identity: sender ?? fixture.identity,
    groupId: fixture.group.id,
    messageId:
        '${'$number' * 8}-${'$number' * 4}-4${'$number' * 3}-8${'$number' * 3}-${'$number' * 12}',
    text: text,
    groupKey: (await fixture.store.groupKey(fixture.group))!,
    keyEpoch: fixture.group.keyEpoch,
  );
  if (pending) {
    await fixture.store.queue(fixture.group, envelope);
  } else {
    await fixture.store.saveP2p(fixture.group, envelope);
  }
  return envelope;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  for (final owner in [false, true]) {
    test(
      '${owner ? 'owner' : 'ordinary member'} can leave and retain a read-only archive',
      () async {
        final f = await SecurityFixture.create();
        final backend = DepartureBackend(f);
        if (!owner) {
          f.group = f.group.copyWith(ownerId: (await f.crypto.identity()).id);
          await f.controller.refreshGroups();
        }
        final oldKey = await f.store.groupKey(f.group);
        await archiveMessage(f, 'history retained');
        await archiveMessage(f, 'unsent retained', pending: true, number: 3);
        await backend.leaveConfirmed();
        expect(f.controller.groups, isEmpty);
        expect(f.controller.leftGroups.single.storageId, f.group.storageId);
        expect(f.controller.isGroupLeft(f.group), isTrue);
        expect(f.controller.canSendToGroup(f.group), isFalse);
        expect(f.controller.pendingGroupLeaveCount, 0);
        expect(await f.store.outbox(f.group), isEmpty);
        expect(await f.store.groupKey(f.group), oldKey);
        expect(
          f.controller.messages.map((m) => m.text),
          containsAll(['history retained', 'unsent retained']),
        );
        final records = await f.store.messages(f.group);
        expect(records.where((row) => row['state'] == 'retired'), hasLength(1));
        final posts = f.posts;
        await expectLater(
          f.controller.send('must be blocked'),
          throwsA(isA<ApiException>()),
        );
        await f.controller.flushOutbox(f.group);
        expect(f.posts, posts);
        expect(
          (await f.store.groupDepartures())[f.group.storageId]!['pending'],
          isFalse,
        );
      },
    );
  }

  test(
    'offline departure survives restart and retries the same operation id',
    () async {
      final f = await SecurityFixture.create();
      final backend = DepartureBackend(f)..offline = true;
      f.selectGroup();
      expect(await f.controller.leaveActiveGroup(), isFalse);
      final id = (await f.store
          .groupDepartures())[f.group.storageId]!['leaveId'];
      expect(f.controller.pendingGroupLeaveCount, 1);
      f.controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await f.start();
      expect(f.controller.groups, isEmpty);
      expect(f.controller.leftGroups, hasLength(1));
      expect(f.controller.pendingGroupLeaveCount, 1);
      backend.offline = false;
      await f.controller.reconnect();
      expect(f.controller.pendingGroupLeaveCount, 0);
      expect(backend.leaveIds.toSet(), {id});
      expect(backend.leaveIds.length, greaterThanOrEqualTo(2));
      expect(
        (await f.store.groupDepartures())[f.group.storageId]!['pending'],
        isFalse,
      );
    },
  );

  test(
    'a delayed or stale group listing cannot resurrect a departed membership',
    () async {
      final f = await SecurityFixture.create();
      final backend = DepartureBackend(f);
      final entered = Completer<void>(), response = Completer<http.Response>();
      backend.listEntered = entered;
      backend.heldList = response;
    final oldListing = expectLater(
      f.controller.refreshGroups(),
      throwsA(isA<TransportChangedException>()),
    );
      await entered.future;
      await backend.leaveConfirmed();
      response.complete(
        reply({
          'groups': [f.group.toJson()],
        }),
      );
      await oldListing;
      backend.joined =
          true; // A stale server index still reports the old group.
      await f.controller.refreshGroups();
      expect(f.controller.groups, isEmpty);
      expect(f.controller.leftGroups, hasLength(1));
      expect(f.controller.canSendToGroup(f.group), isFalse);
      expect(await f.store.groupDepartures(), isNotEmpty);
    },
  );

  test(
    'opening an archived group loads history without any network request',
    () async {
      final f = await SecurityFixture.create();
      final backend = DepartureBackend(f);
      await archiveMessage(f, 'offline archive');
      await backend.leaveConfirmed();
      await f.controller.closeGroup();
      await Future<void>.delayed(Duration.zero);
      f.requests.clear();
      await f.controller.openGroup(f.controller.leftGroups.single);
      await Future<void>.delayed(Duration.zero);
      expect(f.requests, isEmpty);
      expect(f.controller.messages.single.text, 'offline archive');
      expect(f.controller.canSendToGroup(f.controller.activeGroup!), isFalse);
    },
  );

  test(
    'automatic rekey excludes archived departed members but keeps their history verifiable',
    () async {
      final f = await SecurityFixture.create();
      final removed = await f.crypto.identity();
      final encryption = await f.crypto.encryptionIdentity();
      await f.store.saveMembers(f.group, [
        Member(
          removed.id,
          removed.publicKey,
          'old ID',
          encryptionPublicKey: encryption.publicKey,
          clientBuild: AppSecurity.clientBuild,
          protocolVersion: 2,
          privacyEpoch: 2,
          grantedKeyEpoch: 1,
        ),
      ]);
      final oldKey = await f.store.groupKey(f.group);
      final historical = await archiveMessage(
        f,
        'departed member history',
        sender: removed,
      );
      f.group = f.group.copyWith(
        keyEpoch: 2,
        membershipRevision: 2,
        rekeyRequired: true,
        minClientBuild: AppSecurity.clientBuild,
      );
      await f.controller.reconnect();
      expect(f.rekeys, 1);
      expect(f.group.keyEpoch, 3);
      expect(f.group.rekeyRequired, isFalse);
      expect(f.rotatedWraps.map((w) => w['recipientId']), [f.identity.id]);
      expect(
        f.grantedWraps.where((w) => w['recipientId'] == removed.id),
        isEmpty,
      );
      final retainedMember = (await f.store.members(
        f.group,
      )).singleWhere((m) => m.id == removed.id);
      expect(retainedMember.publicKey, removed.publicKey);
      expect(await f.store.groupKey(f.group, epoch: 1), oldKey);
      expect(await f.store.groupKey(f.group), isNot(oldKey));
      final clear = await f.crypto.decrypt(
        historical,
        oldKey!,
        retainedMember.publicKey,
        expectedGroupId: f.group.id,
      );
      expect(clear['text'], 'departed member history');
      f.selectGroup();
      await f.controller.grantPendingKeys();
      expect(f.controller.messages.single.text, 'departed member history');
      expect(await f.store.quarantinedCount(f.group), 0);
    },
  );

  test(
    'a pending pre-leave rekey is replaced with a fresh operation for the barrier epoch',
    () async {
      final f = await SecurityFixture.create();
      final oldKey = await f.store.groupKey(f.group);
      const oldRotation = '99999999-9999-4999-8999-999999999999';
      await f.store.writeState('pending-rekey:${f.group.storageId}', {
        'rotationId': oldRotation,
        'expectedKeyEpoch': 1,
        'wrappedKeys': <dynamic>[],
      });
      f.group = f.group.copyWith(
        keyEpoch: 2,
        membershipRevision: 2,
        rekeyRequired: true,
        minClientBuild: AppSecurity.clientBuild,
      );
      await f.controller.reconnect();
      expect(f.rekeys, 1);
      final operation =
          jsonDecode(
                f.requests
                    .singleWhere((r) => r.url.path.endsWith('/rekey'))
                    .body,
              )
              as Map<String, dynamic>;
      expect(operation['rotationId'], isNot(oldRotation));
      expect(operation['expectedKeyEpoch'], 2);
      expect(f.rotatedWraps.single['keyEpoch'], 3);
      expect(
        await f.store.readState('pending-rekey:${f.group.storageId}'),
        isNull,
      );
      expect(await f.store.groupKey(f.group), isNot(oldKey));
    },
  );

  test(
    'pending remote departure rejects rejoin before sending a join request',
    () async {
      final f = await SecurityFixture.create();
      final backend = DepartureBackend(f)..offline = true;
      f.selectGroup();
      expect(await f.controller.leaveActiveGroup(), isFalse);
      await expectLater(
        f.controller.join(backend.invitation()),
        throwsA(isA<ApiException>()),
      );
      expect(f.requests.where((r) => r.url.path.endsWith('/join')), isEmpty);
      expect(
        await f.store.readState('pending-rejoin:${f.group.storageId}'),
        isNull,
      );
    },
  );

  test(
    'lost rejoin response recovers explicit intent and staged key after restart',
    () async {
      final f = await SecurityFixture.create();
      final backend = DepartureBackend(f);
      final originalKey = await f.store.groupKey(f.group);
      await backend.leaveConfirmed();
      final invite = backend.invitation();
      backend.loseJoinResponse = true;
      await expectLater(
        f.controller.join(invite),
        throwsA(isA<SocketException>()),
      );
      expect(f.controller.groups, isEmpty);
      expect(
        await f.store.readState('pending-rejoin:${f.group.storageId}'),
        isNotNull,
      );
      f.controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await f.start();
      expect(f.controller.groups.single.keyEpoch, 3);
      expect(f.controller.leftGroups, isEmpty);
      expect(f.controller.canSendToGroup(f.controller.groups.single), isTrue);
      expect(await f.store.groupDepartures(), isEmpty);
      expect(
        await f.store.readState('pending-rejoin:${f.group.storageId}'),
        isNull,
      );
      expect(await f.store.groupKey(f.group), unb64(invite.groupKey));
      expect(await f.store.groupKey(f.group, epoch: 1), originalKey);
    },
  );

  test(
    'a group request started before explicit rejoin intent cannot clear departure',
    () async {
      final f = await SecurityFixture.create();
      final backend = DepartureBackend(f);
      await backend.leaveConfirmed();
      final entered = Completer<void>(), response = Completer<http.Response>();
      backend.listEntered = entered;
      backend.heldList = response;
      final oldListing = f.controller.refreshGroups();
      await entered.future;
      backend.loseJoinResponse = true;
      await expectLater(
        f.controller.join(backend.invitation()),
        throwsA(isA<SocketException>()),
      );
      response.complete(
        reply({
          'groups': [f.group.toJson()],
        }),
      );
      await oldListing;
      expect(f.controller.groups, isEmpty);
      expect(await f.store.groupDepartures(), isNotEmpty);
      await f.controller.refreshGroups();
      expect(f.controller.groups.single.keyEpoch, 3);
      expect(await f.store.groupDepartures(), isEmpty);
    },
  );
}
