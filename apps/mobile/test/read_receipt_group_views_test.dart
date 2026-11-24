import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'mandatory_update_test.dart' show SecurityFixture;
import 'quote_reply_controller_test.dart' show reloadMessages;
import 'read_receipt_test.dart' show receiptPayload;

const aMessageId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const bMessageId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

Future<Envelope> content(SecurityFixture sender, String id) =>
    sender.crypto.encryptPayload(
      identity: sender.identity,
      groupId: sender.group.id,
      messageId: id,
      groupKey: List.filled(32, 41),
      keyEpoch: 1,
      payload: {'text': 'synthetic group message', 'createdAt': 100},
    );

Future<void> deliverToAll(
  List<SecurityFixture> views,
  Envelope envelope,
) async {
  for (final view in views) {
    await view.store.saveP2p(view.group, envelope);
    await reloadMessages(view);
  }
}

void expectReadInEveryView(
  List<SecurityFixture> views,
  String messageId,
  bool isRead,
) {
  for (var index = 0; index < views.length; index++) {
    final message = views[index].controller.messages.singleWhere(
      (message) => message.envelope.messageId == messageId,
    );
    expect(message.isRead, isRead, reason: 'group view $index');
  }
}

Future<List<Envelope>> signedOwnReceipts(SecurityFixture view) async {
  final result = <Envelope>[];
  for (final row in await view.store.messages(view.group)) {
    final envelope = Envelope.fromJson(jsonDecode(row['envelope'] as String));
    if (envelope.senderId != view.identity.id) continue;
    final clear = await view.crypto.decrypt(
      envelope,
      List.filled(32, 41),
      view.identity.publicKey,
      expectedGroupId: view.group.id,
    );
    if (ReadReceiptEvent.isPayload(clear)) result.add(envelope);
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'A B C see identical group status after the second distinct viewer, regardless of sender',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mentor-three-reader-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final a = await SecurityFixture.create(
        databasePath: '${directory.path}/a.sqlite',
      );
      final b = await SecurityFixture.create(
        databasePath: '${directory.path}/b.sqlite',
      );
      final c = await SecurityFixture.create(
        databasePath: '${directory.path}/c.sqlite',
      );
      final views = [a, b, c];
      expect(views.map((view) => view.identity.id).toSet().length, 3);
      for (final view in views) {
        view.group = view.group.copyWith(ownerId: a.identity.id);
        await view.store.saveGroup(view.group);
        for (final other in views.where((other) => other != view)) {
          view.extraMembers.add({
            'deviceId': other.identity.id,
            'publicKey': other.identity.publicKey,
            'displayName': '匿名成员',
            'clientBuild': 8,
            'protocolVersion': 2,
            'privacyEpoch': 2,
            'grantedKeyEpoch': 1,
          });
        }
        await view.store.saveMembers(view.group, [
          for (final member in views)
            Member(member.identity.id, member.identity.publicKey, '匿名成员'),
        ]);
      }

      await deliverToAll(views, await content(a, aMessageId));
      expectReadInEveryView(views, aMessageId, false);
      a.controller.setChatVisibility(a.group.storageId, true);
      for (var repeat = 0; repeat < 3; repeat++) {
        await a.controller.markMessagesVisible(a.group.storageId, [aMessageId]);
        await a.controller.flushVisibleReadReceipts();
      }
      expect(await signedOwnReceipts(a), isEmpty);
      expectReadInEveryView(views, aMessageId, false);

      // Even distinct event IDs signed by the same sender do not create a
      // second viewer. Counting events instead of signer identity is wrong.
      for (var repeat = 1; repeat <= 2; repeat++) {
        final eventId =
            'cccccccc-cccc-4ccc-8ccc-${repeat.toString().padLeft(12, '0')}';
        final repeatedSender = await a.crypto.encryptPayload(
          identity: a.identity,
          groupId: a.group.id,
          messageId: eventId,
          groupKey: List.filled(32, 41),
          keyEpoch: 1,
          payload: receiptPayload(eventId, [aMessageId]),
        );
        await deliverToAll(views, repeatedSender);
      }
      expectReadInEveryView(views, aMessageId, false);

      b.controller.setChatVisibility(b.group.storageId, true);
      await b.controller.markMessagesVisible(b.group.storageId, [aMessageId]);
      await b.controller.flushVisibleReadReceipts();
      final bReceipt = (await signedOwnReceipts(b)).single;
      await deliverToAll(views, bReceipt);
      expectReadInEveryView(views, aMessageId, true);
      // C has only downloaded the content and receipt; it has never reported
      // that message as visible, yet sees the group's same read status.
      expect(await signedOwnReceipts(c), isEmpty);
      await deliverToAll(views, bReceipt);
      expectReadInEveryView(views, aMessageId, true);

      await deliverToAll(views, await content(b, bMessageId));
      expectReadInEveryView(views, bMessageId, false);
      await b.controller.markMessagesVisible(b.group.storageId, [bMessageId]);
      await b.controller.flushVisibleReadReceipts();
      expect((await signedOwnReceipts(b)).length, 1);
      expectReadInEveryView(views, bMessageId, false);

      final before = (await signedOwnReceipts(
        a,
      )).map((e) => e.messageId).toSet();
      await a.controller.markMessagesVisible(a.group.storageId, [bMessageId]);
      await a.controller.flushVisibleReadReceipts();
      final aReceipt = (await signedOwnReceipts(
        a,
      )).singleWhere((envelope) => !before.contains(envelope.messageId));
      await deliverToAll(views, aReceipt);
      expectReadInEveryView(views, bMessageId, true);
      expectReadInEveryView(views, aMessageId, true);
      expect(await signedOwnReceipts(c), isEmpty);
      for (final view in views) {
        expect(view.controller.messages.length, 2);
        expect(
          view.controller.messages.every((m) => m.reactions.isEmpty),
          isTrue,
        );
      }
    },
  );

  test(
    'an unconfirmed outgoing message stays pending after the sender views it',
    () async {
      final sender = await SecurityFixture.create();
      await sender.store.queue(sender.group, await content(sender, aMessageId));
      await reloadMessages(sender);
      final before = sender.controller.messages.single;
      expect(before.state, 'pending');
      expect(before.isRead, false);
      sender.controller.setChatVisibility(sender.group.storageId, true);
      await sender.controller.markMessagesVisible(sender.group.storageId, [
        aMessageId,
      ]);
      await sender.controller.flushVisibleReadReceipts();
      expect(sender.controller.messages.single.state, 'pending');
      expect(sender.controller.messages.single.isRead, false);
      expect(await signedOwnReceipts(sender), isEmpty);
    },
  );
}
