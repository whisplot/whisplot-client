import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'mandatory_update_test.dart' show SecurityFixture;
import 'quote_reply_controller_test.dart' show reloadMessages;

const incomingId = '33333333-3333-4333-8333-333333333333';
const ownId = '44444444-4444-4444-8444-444444444444';
const receiptId = '55555555-5555-4555-8555-555555555555';
Map<String, dynamic> receiptPayload(String id, List<String> ids) => {
  'type': 'reaction',
  'targetMessageId': id,
  'action': 'remove',
  'counter': 1,
  'createdAt': 100,
  'readReceiptV1': {'v': 1, 'messageIds': ids},
};
Future<Identity> addOther(SecurityFixture f) async {
  final other = await f.crypto.identity();
  f.extraMembers.add({
    'deviceId': other.id,
    'publicKey': other.publicKey,
    'displayName': '匿名成员',
    'clientBuild': 8,
    'protocolVersion': 2,
    'privacyEpoch': 2,
    'grantedKeyEpoch': 1,
  });
  await f.store.saveMembers(f.group, [
    Member(other.id, other.publicKey, '匿名成员'),
  ]);
  return other;
}

Future<Envelope> seed(
  SecurityFixture f,
  Identity sender,
  String id, {
  Map<String, dynamic>? payload,
}) async {
  final e = await f.crypto.encryptPayload(
    identity: sender,
    groupId: f.group.id,
    messageId: id,
    groupKey: List.filled(32, 41),
    keyEpoch: 1,
    payload: payload ?? {'text': 'test', 'createdAt': 100},
  );
  await f.store.saveP2p(f.group, e);
  return e;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'sync is not reading; visible other messages batch once without alias use and survive restart',
    () async {
      final f = await SecurityFixture.create(),
          other = await CryptoService().identity();
      f.extraMembers.add({
        'deviceId': other.id,
        'publicKey': other.publicKey,
        'displayName': '匿名成员',
        'clientBuild': 8,
        'protocolVersion': 2,
        'privacyEpoch': 2,
        'grantedKeyEpoch': 1,
      });
      await f.store.saveMembers(f.group, [
        Member(other.id, other.publicKey, '匿名成员'),
      ]);
      await seed(f, other, incomingId);
      await seed(f, f.identity, ownId);
      await reloadMessages(f);
      expect(f.controller.messages.every((m) => !m.isRead), isTrue);
      final alias = f.controller.displayName,
          used = f.controller.aliasMessagesUsed;
      await f.controller.markMessagesVisible(f.group.storageId, [
        incomingId,
        ownId,
      ]);
      expect((await f.store.messages(f.group)).length, 2);
      f.controller.setChatVisibility(f.group.storageId, true);
      await Future.wait([
        f.controller.markMessagesVisible(f.group.storageId, [
          incomingId,
          ownId,
        ]),
        f.controller.markMessagesVisible(f.group.storageId, [incomingId]),
      ]);
      await f.controller.flushVisibleReadReceipts();
      expect(f.controller.displayName, alias);
      expect(f.controller.aliasMessagesUsed, used);
      expect(f.controller.messages.length, 2);
      expect(
        f.controller.messages
            .singleWhere((m) => m.envelope.messageId == incomingId)
            .isRead,
        isTrue,
      );
      expect(
        f.controller.messages
            .singleWhere((m) => m.envelope.messageId == ownId)
            .isRead,
        isFalse,
      );
      final rows = await f.store.messages(f.group);
      expect(rows.length, 3);
      final record = rows.singleWhere(
        (r) => r['messageId'] != incomingId && r['messageId'] != ownId,
      );
      final envelope = Envelope.fromJson(
        jsonDecode(record['envelope'] as String),
      );
      final clear = await f.crypto.decrypt(
        envelope,
        List.filled(32, 41),
        f.identity.publicKey,
        expectedGroupId: f.group.id,
      );
      expect(clear['readReceiptV1'], {
        'v': 1,
        'messageIds': [incomingId],
      });
      expect(clear.containsKey('senderName'), isFalse);
      expect(clear['targetMessageId'], envelope.messageId);
      expect(record['envelope'], isNot(contains(incomingId)));
      f.controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await f.start();
      await reloadMessages(f);
      expect(
        f.controller.messages
            .singleWhere((m) => m.envelope.messageId == incomingId)
            .isRead,
        isTrue,
      );
      f.controller.setChatVisibility(f.group.storageId, true);
      await f.controller.markMessagesVisible(f.group.storageId, [incomingId]);
      expect((await f.store.messages(f.group)).length, 3);
    },
  );
  test(
    'own sender cannot mark own message read; one other signed receipt suffices and replay stays hidden',
    () async {
      final f = await SecurityFixture.create();
      final other = await addOther(f);
      await seed(f, f.identity, ownId);
      await seed(
        f,
        f.identity,
        receiptId,
        payload: receiptPayload(receiptId, [ownId]),
      );
      await reloadMessages(f);
      expect(f.controller.messages.single.isRead, isFalse);
      const next = '66666666-6666-4666-8666-666666666666';
      final e = await seed(
        f,
        other,
        next,
        payload: receiptPayload(next, [ownId]),
      );
      await reloadMessages(f);
      expect(f.controller.messages.single.isRead, isTrue);
      expect(f.controller.messages.single.reactions, isEmpty);
      await f.store.saveP2p(f.group, e);
      await reloadMessages(f);
      expect(f.controller.messages.length, 1);
      expect(f.controller.messages.single.isRead, isTrue);
    },
  );
  test(
    'covered, inactive, stale room and unknown IDs do not emit receipts',
    () async {
      final f = await SecurityFixture.create();
      final other = await addOther(f);
      await seed(f, other, incomingId);
      await reloadMessages(f);
      f.controller.setChatVisibility(f.group.storageId, false);
      await f.controller.markMessagesVisible(f.group.storageId, [incomingId]);
      f.controller.setChatVisibility(f.group.storageId, true);
      await f.controller.markMessagesVisible('another-room', [incomingId]);
      await f.controller.markMessagesVisible(f.group.storageId, ['unknown']);
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await f.controller.markMessagesVisible(f.group.storageId, [incomingId]);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect((await f.store.messages(f.group)).length, 1);
      expect(f.controller.messages.single.isRead, isFalse);
    },
  );
  test(
    'visible bursts coalesce and another reader suppresses redundant receipts; hiding cancels pending',
    () async {
      final f = await SecurityFixture.create();
      final author = await addOther(f), reader = await addOther(f);
      const second = '88888888-8888-4888-8888-888888888888';
      await seed(f, author, incomingId);
      await seed(f, author, second);
      await reloadMessages(f);
      f.controller.setChatVisibility(f.group.storageId, true);
      await f.controller.markMessagesVisible(f.group.storageId, [incomingId]);
      await f.controller.markMessagesVisible(f.group.storageId, [second]);
      expect((await f.store.messages(f.group)).length, 2);
      await seed(
        f,
        reader,
        receiptId,
        payload: receiptPayload(receiptId, [incomingId]),
      );
      await reloadMessages(f);
      await f.controller.flushVisibleReadReceipts();
      final rows = await f.store.messages(f.group);
      expect(rows.length, 4);
      final ownControl = rows
          .map((r) => Envelope.fromJson(jsonDecode(r['envelope'] as String)))
          .singleWhere((e) => e.senderId == f.identity.id);
      final clear = await f.crypto.decrypt(
        ownControl,
        List.filled(32, 41),
        f.identity.publicKey,
        expectedGroupId: f.group.id,
      );
      expect(clear['readReceiptV1'], {
        'v': 1,
        'messageIds': [second],
      });
      const third = '99999999-9999-4999-8999-999999999999';
      await seed(f, author, third);
      await reloadMessages(f);
      await f.controller.markMessagesVisible(f.group.storageId, [third]);
      f.controller.setChatVisibility(f.group.storageId, false);
      await f.controller.flushVisibleReadReceipts();
      expect((await f.store.messages(f.group)).length, 5);
    },
  );

  test(
    'queued text is submitted ahead of earlier read-control envelopes',
    () async {
      final f = await SecurityFixture.create();
      final control = await f.crypto.encryptPayload(
        identity: f.identity,
        groupId: f.group.id,
        messageId: receiptId,
        groupKey: List.filled(32, 41),
        keyEpoch: 1,
        payload: receiptPayload(receiptId, [incomingId]),
      );
      final content = await f.crypto.encryptPayload(
        identity: f.identity,
        groupId: f.group.id,
        messageId: ownId,
        groupKey: List.filled(32, 41),
        keyEpoch: 1,
        payload: {'text': 'prioritize this text', 'createdAt': 100},
      );
      await f.store.queue(f.group, control);
      await f.store.queue(f.group, content);
      await f.controller.flushOutbox(f.group);
      expect(f.posted.map((e) => e['messageId']), [ownId, receiptId]);
    },
  );

  test('strict signed receipt shape, binding and batch limits', () async {
    final c = CryptoService(), identity = await CryptoService().identity();
    final invalid = [
      receiptPayload('not-event', [ownId]),
      {
        ...receiptPayload(receiptId, [ownId]),
        'type': 'text',
      },
      {
        ...receiptPayload(receiptId, [ownId]),
        'action': 'set',
        'emoji': '👍',
      },
      {
        ...receiptPayload(receiptId, [ownId]),
        'senderName': '临时·XXXXXX',
      },
      receiptPayload(receiptId, []),
      receiptPayload(receiptId, [ownId, ownId]),
      receiptPayload(receiptId, List.generate(65, (i) => 'target-$i')),
      {
        ...receiptPayload(receiptId, [ownId]),
        'readReceiptV1': {
          'v': 1.0,
          'messageIds': [ownId],
        },
      },
      {
        ...receiptPayload(receiptId, [ownId]),
        'readReceiptV1': {
          'v': 1,
          'messageIds': [ownId],
          'reader': identity.id,
        },
      },
    ];
    for (final p in invalid) {
      await expectLater(
        c.encryptPayload(
          identity: identity,
          groupId: 'group',
          messageId: receiptId,
          groupKey: List.filled(32, 41),
          keyEpoch: 1,
          payload: p,
        ),
        throwsFormatException,
      );
    }
    final e = await c.encryptPayload(
      identity: identity,
      groupId: 'group',
      messageId: receiptId,
      groupKey: List.filled(32, 41),
      keyEpoch: 1,
      payload: receiptPayload(receiptId, List.generate(64, (i) => 'target-$i')),
    );
    final p = await c.decrypt(
      e,
      List.filled(32, 41),
      identity.publicKey,
      expectedGroupId: 'group',
    );
    expect(ReadReceiptEvent.fromPayload(e, p).messageIds.length, 64);
    final attacker = await c.identity();
    await expectLater(
      c.decrypt(
        e,
        List.filled(32, 41),
        attacker.publicKey,
        expectedGroupId: 'group',
      ),
      throwsFormatException,
    );
  });
}
