import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nearlink/core/client_security.dart';
import 'package:nearlink/core/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'mandatory_update_test.dart' show SecurityFixture;
import 'support/security_fixture.dart' show policyWire;
import 'voice_controller_test.dart' show FixtureMedia;

const targetId = '22222222-2222-4222-8222-222222222222';
const missingId = '99999999-9999-4999-8999-999999999999';

class DelayedQuoteMedia extends FixtureMedia {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<VoiceAttachment> prepareVoice(Group group, Uint8List wav) async {
    final prepared = await super.prepareVoice(group, wav);
    entered.complete();
    await release.future;
    return prepared;
  }
}

Future<Map<String, dynamic>> decryptRecord(
  SecurityFixture f,
  Map<String, Object?> row,
) async {
  final envelope = Envelope.fromJson(jsonDecode(row['envelope'] as String));
  return f.crypto.decrypt(
    envelope,
    (await f.store.groupKey(f.group, epoch: envelope.keyEpoch))!,
    f.identity.publicKey,
    expectedGroupId: f.group.id,
  );
}

Future<Envelope> seedTarget(
  SecurityFixture f, {
  Group? group,
  int epoch = 1,
  String messageId = targetId,
  Map<String, dynamic>? payload,
}) async {
  final destination = group ?? f.group;
  final envelope = await f.crypto.encryptPayload(
    identity: f.identity,
    groupId: destination.id,
    messageId: messageId,
    groupKey: List.filled(32, 41),
    keyEpoch: epoch,
    payload:
        payload ??
        {
          'text': 'original private text',
          'senderName': f.controller.displayName,
          'createdAt': 100,
        },
  );
  await f.store.saveP2p(destination, envelope);
  return envelope;
}

Group otherGroup(SecurityFixture f, {bool sameIdDifferentServer = false}) =>
    Group(
      id: sameIdDifferentServer
          ? f.group.id
          : '44444444-4444-4444-8444-444444444444',
      server: sameIdDifferentServer
          ? 'https://other.fixture.example'
          : f.group.server,
      name: 'Another room',
      ownerId: f.identity.id,
      keyEpoch: 1,
      protocolVersion: 2,
      privacyEpoch: 2,
      minClientBuild: AppSecurity.clientBuild,
    );

Future<void> reloadMessages(SecurityFixture f) async {
  f.selectGroup();
  await f.controller.grantPendingKeys();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'text quote persists only an encrypted pointer and never copies the expired alias',
    () async {
      final f = await SecurityFixture.create();
      f.selectGroup();
      final originalAlias = f.controller.displayName;
      await f.controller.send('original secret not copied into reply');
      final target = f.controller.messages.single;
      expect(target.expiredOwnId, isTrue);
      expect(target.temporarySenderId, '已过期 ID');
      await f.controller.send(
        'my separate reply',
        replyToMessageId: target.envelope.messageId,
        expectedStorageId: f.group.storageId,
      );
      final rows = await f.store.messages(f.group);
      final reply = f.controller.messages.singleWhere(
        (m) => m.text == 'my separate reply',
      );
      final savedReply = rows.singleWhere(
        (row) => row['messageId'] == reply.envelope.messageId,
      );
      final clear = await decryptRecord(f, savedReply);
      expect(clear['replyTo'], {
        'v': 1,
        'messageId': target.envelope.messageId,
      });
      expect(jsonEncode(clear), isNot(contains(originalAlias)));
      expect(jsonEncode(clear), isNot(contains(target.text)));
      expect(savedReply['envelope'], isNot(contains('replyTo')));
      expect(
        savedReply['envelope'],
        isNot(contains(target.envelope.messageId)),
      );
      expect(savedReply['envelope'], isNot(contains('my separate reply')));
      expect(reply.replyToMessageId, target.envelope.messageId);
      f.controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await f.start();
      await reloadMessages(f);
      final restored = f.controller.messages.singleWhere(
        (m) => m.text == 'my separate reply',
      );
      final source = f.controller.messages.singleWhere(
        (m) => m.envelope.messageId == target.envelope.messageId,
      );
      expect(restored.replyToMessageId, target.envelope.messageId);
      expect(source.temporarySenderId, '已过期 ID');
      expect(source.temporarySenderId, isNot(originalAlias));
    },
  );

  test(
    'voice reply stores the same pointer without a copy of the quoted text or alias',
    () async {
      final media = FixtureMedia();
      final f = await SecurityFixture.create(media: media);
      f.selectGroup();
      final originalAlias = f.controller.displayName;
      await f.controller.send('private quoted text');
      final target = f.controller.messages.single;
      await f.controller.sendVoice(
        Uint8List.fromList([1, 2, 3]),
        replyToMessageId: target.envelope.messageId,
        expectedStorageId: f.group.storageId,
      );
      final voice = f.controller.messages.singleWhere((m) => m.voice != null);
      final row = (await f.store.messages(
        f.group,
      )).singleWhere((r) => r['messageId'] == voice.envelope.messageId);
      final clear = await decryptRecord(f, row);
      expect(clear['type'], 'voice');
      expect(clear['replyTo'], {
        'v': 1,
        'messageId': target.envelope.messageId,
      });
      expect(jsonEncode(clear), isNot(contains(originalAlias)));
      expect(jsonEncode(clear), isNot(contains(target.text)));
      expect(row['envelope'], isNot(contains('replyTo')));
      expect(voice.replyToMessageId, target.envelope.messageId);
      await reloadMessages(f);
      expect(
        f.controller.messages
            .singleWhere((m) => m.voice != null)
            .replyToMessageId,
        target.envelope.messageId,
      );
    },
  );

  for (final invalidTarget in [
    'missing',
    'other-group',
    'other-server',
    'quarantined',
    'bad-signature',
    'missing-history-key',
    'reaction',
    'wrong-envelope-group',
    'mismatched-message-index',
  ]) {
    test(
      'quote and quick-like reject $invalidTarget without consuming an alias or writing',
      () async {
        final media = FixtureMedia();
        final f = await SecurityFixture.create(media: media);
        f.selectGroup();
        switch (invalidTarget) {
          case 'missing':
            break;
          case 'other-group':
          case 'other-server':
            await seedTarget(
              f,
              group: otherGroup(
                f,
                sameIdDifferentServer: invalidTarget == 'other-server',
              ),
            );
          case 'quarantined':
            await seedTarget(f);
            await f.store.quarantine(f.group, targetId);
          case 'bad-signature':
            final original = await seedTarget(f);
            await f.db.update(
              'messages',
              {
                'envelope': jsonEncode(
                  original.withSignature(b64(List.filled(64, 0))).toJson(),
                ),
              },
              where: 'storageId=? AND messageId=?',
              whereArgs: [f.group.storageId, targetId],
            );
          case 'missing-history-key':
            await seedTarget(f, epoch: 9);
          case 'reaction':
            await seedTarget(
              f,
              payload: {
                'type': 'reaction',
                'targetMessageId': missingId,
                'action': 'set',
                'emoji': '👍',
                'counter': 1,
                'createdAt': 100,
              },
            );
          case 'mismatched-message-index':
            await seedTarget(f);
            await f.db.update(
              'messages',
              {'messageId': missingId},
              where: 'storageId=? AND messageId=?',
              whereArgs: [f.group.storageId, targetId],
            );
            break;
          case 'wrong-envelope-group':
            final wrong = await seedTarget(f, group: otherGroup(f));
            await f.store.saveP2p(f.group, wrong);
        }
        final requestedTarget = invalidTarget == 'mismatched-message-index'
            ? missingId
            : targetId;
        final alias = await f.store.readAliasState(),
            before = (await f.store.messages(f.group)).length;
        await expectLater(
          f.controller.send(
            'must fail',
            replyToMessageId: requestedTarget,
            expectedStorageId: f.group.storageId,
          ),
          throwsA(anything),
        );
        await expectLater(
          f.controller.sendVoice(
            Uint8List.fromList([1, 2, 3]),
            replyToMessageId: requestedTarget,
            expectedStorageId: f.group.storageId,
          ),
          throwsA(anything),
        );
        await expectLater(
          f.controller.quickLike(
            requestedTarget,
            expectedStorageId: f.group.storageId,
          ),
          throwsA(anything),
        );
        expect(await f.store.readAliasState(), alias);
        expect((await f.store.messages(f.group)).length, before);
        expect(f.posts, 0);
        expect(media.log, isNot(contains('prepare')));
      },
    );
  }

  test(
    'a switch before a queued text send rejects the stale reply destination',
    () async {
      final f = await SecurityFixture.create();
      f.selectGroup();
      await seedTarget(f);
      final state = await f.store.readAliasState();
      final sending = f.controller.send(
        'stale compose',
        replyToMessageId: targetId,
        expectedStorageId: f.group.storageId,
      );
      final rejected = expectLater(sending, throwsA(anything));
      final next = otherGroup(f);
      f.controller.activeGroup = next;
      await rejected;
      expect(await f.store.readAliasState(), state);
      expect(await f.store.outbox(f.group), isEmpty);
      expect(await f.store.outbox(next), isEmpty);
      expect(f.posts, 0);
    },
  );

  test(
    'switching groups during voice preparation discards audio without enqueue or alias consumption',
    () async {
      final media = DelayedQuoteMedia();
      final f = await SecurityFixture.create(media: media);
      f.selectGroup();
      await seedTarget(f);
      final state = await f.store.readAliasState();
      final sending = f.controller.sendVoice(
        Uint8List.fromList([1, 2, 3]),
        replyToMessageId: targetId,
        expectedStorageId: f.group.storageId,
      );
      final rejected = expectLater(sending, throwsA(anything));
      await media.entered.future;
      await f.controller.closeGroup();
      f.controller.activeGroup = otherGroup(f);
      media.release.complete();
      await rejected;
      expect(media.log, contains('discard'));
      expect(await f.store.readAliasState(), state);
      expect(await f.store.outbox(f.group), isEmpty);
      expect(f.posts, 0);
    },
  );

  test(
    'stale expectedStorageId rejects all compose gestures immediately',
    () async {
      final f = await SecurityFixture.create();
      f.selectGroup();
      await seedTarget(f);
      final expected = otherGroup(f).storageId;
      final state = await f.store.readAliasState();
      await expectLater(
        f.controller.send(
          'wrong room',
          replyToMessageId: targetId,
          expectedStorageId: expected,
        ),
        throwsA(anything),
      );
      await expectLater(
        f.controller.quickLike(targetId, expectedStorageId: expected),
        throwsA(anything),
      );
      await expectLater(
        f.controller.toggleReaction(
          targetId,
          '❤️',
          expectedStorageId: expected,
        ),
        throwsA(anything),
      );
      expect(await f.store.readAliasState(), state);
      expect(await f.store.outbox(f.group), isEmpty);
    },
  );

  for (final readOnly in ['left', 'rekey-barrier', 'policy-block']) {
    test('$readOnly room cannot quote or quick-like', () async {
      final media = FixtureMedia();
      final f = await SecurityFixture.create(media: media);
      f.selectGroup();
      await seedTarget(f);
      if (readOnly == 'left') {
        f.extraHandler = (request) async {
          if (!request.url.path.endsWith('/leave')) return null;
          final operation = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'left': true,
              'leaveId': operation['leaveId'],
              'groupId': f.group.id,
            }),
            200,
          );
        };
        expect(await f.controller.leaveActiveGroup(), isTrue);
        await f.controller.reconnect();
      } else if (readOnly == 'rekey-barrier') {
        f.group = f.group.copyWith(
          ownerId: (await f.crypto.identity()).id,
          keyEpoch: 2,
          membershipRevision: 2,
          rekeyRequired: true,
        );
        await f.controller.refreshGroups();
        f.selectGroup();
      } else {
        f.policy = await policyWire(
          f.crypto,
          revision: 2,
          minBuild: AppSecurity.clientBuild + 1,
        );
        await f.controller.refreshPolicy();
      }
      final state = await f.store.readAliasState();
      await expectLater(
        f.controller.send(
          'readonly quote',
          replyToMessageId: targetId,
          expectedStorageId: f.group.storageId,
        ),
        throwsA(anything),
      );
      await expectLater(
        f.controller.sendVoice(
          Uint8List.fromList([1, 2, 3]),
          replyToMessageId: targetId,
          expectedStorageId: f.group.storageId,
        ),
        throwsA(anything),
      );
      await expectLater(
        f.controller.quickLike(targetId, expectedStorageId: f.group.storageId),
        throwsA(anything),
      );
      expect(await f.store.readAliasState(), state);
      expect(await f.store.outbox(f.group), isEmpty);
      expect(f.posts, 0);
      expect(media.log, isNot(contains('prepare')));
    });
  }

  for (final previousEmoji in [null, '❤️', '👍', '♥️']) {
    test(
      'concurrent quick-like is an idempotent set over ${previousEmoji ?? 'no previous reaction'}',
      () async {
        final f = await SecurityFixture.create();
        f.selectGroup();
        await f.controller.setAliasRotationLimit(10);
        await f.controller.send('like this');
        final target = f.controller.messages.single.envelope.messageId;
        if (previousEmoji != null) {
          await f.controller.toggleReaction(target, previousEmoji);
        }
        final count = (await f.store.messages(f.group)).length;
        final state = await f.store.readAliasState(),
            alias = f.controller.displayName;
        await Future.wait(
          List.generate(
            12,
            (_) => f.controller.quickLike(
              target,
              expectedStorageId: f.group.storageId,
            ),
          ),
        );
        expect(
          (await f.store.messages(f.group)).length,
          count + (previousEmoji == '♥️' ? 0 : 1),
        );
        expect(f.controller.messages, hasLength(1));
        expect(ReactionEmoji.quickLike, '♥️');
        expect(f.controller.messages.single.reactions.single.emoji, '♥️');
        expect(
          f.controller.messages.single.reactions.single.selectedByMe,
          isTrue,
        );
        expect(await f.store.readAliasState(), state);
        expect(f.controller.displayName, alias);
        expect(f.controller.aliasMessagesUsed, 1);
        for (final row in await f.store.messages(f.group)) {
          final payload = await decryptRecord(f, row);
          if (payload['type'] == 'reaction') {
            expect(payload.containsKey('senderName'), isFalse);
            expect(payload.containsKey('replyTo'), isFalse);
          }
        }
        // The original explicit toggle remains cancellable.
        await f.controller.toggleReaction(
          target,
          '♥️',
          expectedStorageId: f.group.storageId,
        );
        expect(f.controller.messages.single.reactions, isEmpty);
        expect(await f.store.readAliasState(), state);
      },
    );
  }
}
