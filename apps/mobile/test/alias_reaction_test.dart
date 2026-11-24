import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/core/temporary_id.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nearlink/services/local_store.dart';
import 'anonymous_identity_test.dart'
    show AnonymousTestStore, StartupController;

class RotationStore extends AnonymousTestStore {
  RotationStore(super.db);
  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late RotationStore store;
  late StartupController c;
  late Group group;
  late List<int> key;
  final crypto = CryptoService();
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalStore.createSchema(db);
    store = RotationStore(db);
    c = StartupController(store);
    await c.initialize();
    group = Group(
      keyEpoch: 1,
      protocolVersion: 2,
      privacyEpoch: 2,
      minClientBuild: 5,
      id: '11111111-1111-4111-8111-111111111111',
      server: 'https://example.com',
      name: 'group',
      ownerId: c.identity.id,
    );
    key = crypto.randomBytes(32);
    await store.saveGroup(group);
    await store.saveKey(group, key);
    await store.writeSecret(
      ChatController.connectionSettingsKey,
      jsonEncode({'v': 1, 'server': group.server, 'code': ''}),
    );
    c.activeGroup = group;
    c.groups = [group];
  });
  tearDown(() async {
    c.dispose();
    await db.close();
  });
  Future<void> reopen() async {
    c.dispose();
    c = StartupController(store);
    await c.initialize();
    c.api?.close();
    c.api = null;
    c.activeGroup = group;
  }

  test('default one rotates only after successful durable enqueue', () async {
    final alias = c.displayName, state = await store.readAliasState();
    expect(c.aliasRotationLimit, 1);
    await db.execute(
      "CREATE TRIGGER fail_queue BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT,'fixture'); END",
    );
    await expectLater(c.send('must roll back'), throwsA(anything));
    expect(await store.readAliasState(), state);
    expect(c.displayName, alias);
    expect(c.aliasMessagesUsed, 0);
    expect(await store.outbox(group), isEmpty);
    await db.execute('DROP TRIGGER fail_queue');
    await c.send('committed');
    expect(c.displayName, isNot(alias));
    expect(c.aliasMessagesUsed, 0);
    expect((await store.outbox(group)).length, 1);
    expect(c.messages.single.senderName, alias);
  });

  test(
    'concurrent sends cannot exceed ten uses and restart preserves remainder',
    () async {
      await c.setAliasRotationLimit(10);
      final alias = c.displayName;
      await Future.wait(List.generate(11, (n) => c.send('message $n')));
      expect(c.messages.take(10).every((m) => m.senderName == alias), isTrue);
      expect(c.messages[10].senderName, isNot(alias));
      expect(c.aliasMessagesUsed, 1);
      final after = c.displayName, identity = c.identity.id;
      await reopen();
      expect(c.displayName, after);
      expect(c.identity.id, identity);
      expect(c.aliasRotationLimit, 10);
      expect(c.aliasMessagesUsed, 1);
      await c.send('after restart');
      expect(c.aliasMessagesUsed, 2);
      expect(c.messages.last.senderName, after);
    },
  );

  test(
    'changing tiers never replenishes a previously used ID budget',
    () async {
      await c.setAliasRotationLimit(10);
      final alias = c.displayName;
      for (var i = 0; i < 9; i++) {
        await c.send('used $i');
      }
      await c.setAliasRotationLimit(50);
      await c.send('tenth');
      expect(c.displayName, isNot(alias));
      expect(c.aliasRotationLimit, 50);
      expect(c.aliasMessagesUsed, 0);
      final newAlias = c.displayName;
      await c.send('one');
      await c.setAliasRotationLimit(1);
      await c.setAliasRotationLimit(50);
      await c.send('must use another ID');
      expect(c.messages.last.senderName, isNot(newAlias));
      await expectLater(c.setAliasRotationLimit(2), throwsFormatException);
    },
  );

  test(
    'replay and reactions consume no pseudonym budget and produce no extra bubbles',
    () async {
      await c.setAliasRotationLimit(10);
      await c.send('target');
      final state = await store.readAliasState(), alias = c.displayName;
      final message = c.messages.single;
      final original = (await store.outbox(group)).single;
      await store.queue(
        group,
        original,
      ); // replay does not call the counted enqueue.
      await c.toggleReaction(message.envelope.messageId, '👍');
      expect(c.messages.length, 1);
      expect(c.messages.single.reactions.single.emoji, '👍');
      expect(c.messages.single.reactions.single.selectedByMe, isTrue);
      await c.toggleReaction(message.envelope.messageId, '❤️');
      expect(c.messages.single.reactions.single.emoji, '❤️');
      await c.toggleReaction(message.envelope.messageId, '❤️');
      expect(c.messages.single.reactions, isEmpty);
      expect(c.aliasMessagesUsed, 1);
      expect(c.displayName, alias);
      expect(await store.readAliasState(), state);
      expect((await store.outbox(group)).length, 4);
      await reopen();
      await c.toggleReaction(message.envelope.messageId, '🙏');
      final events = await store.outbox(group);
      final clear = await crypto.decrypt(
        events.last,
        key,
        c.identity.publicKey,
        expectedGroupId: group.id,
      );
      expect(clear['counter'], 4);
      expect(clear.containsKey('senderName'), isFalse);
      expect(c.aliasMessagesUsed, 1);
    },
  );

  test(
    'rich reactions persist across restart without using an ID or adding bubbles',
    () async {
      await c.setAliasRotationLimit(10);
      await c.send('target');
      final target = c.messages.single.envelope.messageId;
      final aliasState = await store.readAliasState();
      await c.toggleReaction(target, '🫩');
      expect(c.messages, hasLength(1));
      expect(c.messages.single.reactions.single.emoji, '🫩');
      expect(c.messages.single.reactions.single.selectedByMe, isTrue);
      final sent = (await store.outbox(group)).last;
      final clear = await crypto.decrypt(
        sent,
        key,
        c.identity.publicKey,
        expectedGroupId: group.id,
      );
      expect(clear['action'], 'remove');
      expect(clear['reactionV2'], {'v': 1, 'emoji': '🫩'});
      expect(clear['counter'], 1);
      expect(clear.containsKey('senderName'), isFalse);
      await reopen();
      await c.toggleReaction(target, '🫩');
      expect(c.messages, hasLength(1));
      expect(c.messages.single.reactions, isEmpty);
      final removed = await crypto.decrypt(
        (await store.outbox(group)).last,
        key,
        c.identity.publicKey,
        expectedGroupId: group.id,
      );
      expect(removed['counter'], 2);
      expect(removed['action'], 'remove');
      expect(removed.containsKey('reactionV2'), isFalse);
      expect(await store.readAliasState(), aliasState);
      expect(c.aliasMessagesUsed, 1);
      expect(
        () => c.toggleReaction(target, 'not emoji'),
        throwsFormatException,
      );
      expect(await store.outbox(group), hasLength(3));
    },
  );

  test(
    'missing state after migration fails closed without replacing identity',
    () async {
      final identity = c.identity.id,
          seed = await store.readSecret('identity-seed');
      await db.delete('local_state');
      await reopen();
      expect(c.ready, isFalse);
      expect(c.error, contains('计数记录缺失'));
      expect(c.identity.id, identity);
      expect(await store.readSecret('identity-seed'), seed);
      expect(await store.readAliasState(), isNull);
      await expectLater(c.send('not allowed'), throwsFormatException);
      expect(await store.outbox(group), isEmpty);
    },
  );

  test(
    'committed state repairs missing marker and removes old own member aliases',
    () async {
      await c.setAliasRotationLimit(10);
      await c.send('one');
      final state = await store.readAliasState(), alias = c.displayName;
      await store.deleteSecret(ChatController.aliasMigrationKey);
      await store.writeSecret('display-name', '临时·ABC234');
      await store.saveMembers(group, [
        Member(c.identity.id, c.identity.publicKey, '临时·ABC234'),
      ]);
      await reopen();
      expect(c.displayName, alias);
      expect(c.aliasMessagesUsed, 1);
      expect(await store.readAliasState(), state);
      expect(await store.readSecret(ChatController.aliasMigrationKey), '1');
      expect(await store.readSecret('display-name'), isNull);
      expect((await store.members(group)).single.name, '匿名成员');
      expect(state, isNot(contains(alias)));
      expect((await db.query('local_state')).length, 1);
    },
  );

  test('reaction fold is stable across out of order, remove and replay', () {
    ReactionEvent event(String id, String sender, int counter, String? emoji) =>
        ReactionEvent(
          envelope: Envelope(
            groupId: 'g',
            messageId: id,
            senderId: sender,
            nonce: '',
            ciphertext: '',
            signature: id,
          ),
          targetMessageId: 'm',
          counter: counter,
          emoji: emoji,
        );
    final set = event('a', 'alice', 1, '👍'),
        remove = event('c', 'alice', 2, null),
        tie = event('b', 'alice', 2, '❤️'),
        other = event('d', 'bob', 1, '👍');
    for (final events in [
      [set, remove, tie, other, set],
      [other, tie, set, remove, remove],
      [remove, set, other, tie],
    ]) {
      final folded = foldReactions(events);
      final summary = summarizeReactions(folded['m'], 'alice');
      expect(summary.length, 1);
      expect(summary.single.emoji, '👍');
      expect(summary.single.count, 1);
      expect(summary.single.selectedByMe, isFalse);
    }
  });

  test(
    'legacy upgrade with chat history starts a fresh ID without altering signed records',
    () async {
      final old = c.displayName;
      await c.send('old signed text');
      final envelope = (await store.outbox(group)).single;
      await db.delete('local_state');
      await store.deleteSecret(ChatController.aliasMigrationKey);
      await store.writeSecret('display-name', old);
      await reopen();
      expect(c.displayName, isNot(old));
      expect(c.aliasRotationLimit, 1);
      expect((await store.outbox(group)).single.toJson(), envelope.toJson());
      expect(TemporaryId.isValid(c.displayName), isTrue);
    },
  );
}
