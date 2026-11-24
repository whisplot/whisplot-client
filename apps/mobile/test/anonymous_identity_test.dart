import 'support/security_fixture.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/default_connection.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/core/temporary_id.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AnonymousTestStore extends LocalStore {
  AnonymousTestStore(Database db) : super(database: db);
  final secrets = <String, String>{};
  @override
  Future<String?> readSecret(String key) async => secrets[key];
  @override
  Future<void> writeSecret(String key, String value) async {
    secrets[key] = value;
  }

  @override
  Future<void> deleteSecret(String key) async {
    secrets.remove(key);
  }
}

class StartupController extends PermittedController {
  StartupController(LocalStore store)
    : super(store: store, defaultConnection: const DefaultConnection());
  int reconnects = 0;
  @override
  Future<void> reconnect() async {
    reconnects++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('Build without bundled access keeps manual first-run setup', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalStore.createSchema(db);
    final store = AnonymousTestStore(db);
    final controller = StartupController(store);
    await controller.initialize();
    expect(controller.ready, isTrue);
    expect(controller.configured, isFalse);
    expect(controller.server, isEmpty);
    expect(controller.api, isNull);
    expect(controller.reconnects, 0);
    expect(controller.registrationCode, isEmpty);
    expect(await store.readSecret('server'), isNull);
    expect(
      controller.suggestedServer,
      const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: ChatController.defaultServer,
      ),
    );
    expect(TemporaryId.isValid(controller.displayName), isTrue);
    controller.dispose();
  });
  test(
    'Saved connection takes precedence over the suggested default on restart',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalStore.createSchema(db);
      final store = AnonymousTestStore(db);
      final identity = await CryptoService().identity();
      await store.writeSecret('identity-seed', b64(identity.seed));
      await store.writeSecret('server', 'https://saved.example');
      await store.writeSecret('registration-code', 'local-test-code');
      final controller = StartupController(store);
      await controller.initialize();
      expect(controller.configured, isTrue);
      expect(controller.server, 'https://saved.example');
      expect(controller.suggestedServer, 'https://saved.example');
      expect(controller.api!.server, 'https://saved.example');
      expect(controller.reconnects, 1);
      expect(controller.registrationCode, 'local-test-code');
      controller.dispose();
    },
  );
  test(
    'Random temporary IDs need no personal information and follow a readable format',
    () {
      final generated = List.generate(100, (_) => TemporaryId.generate());
      expect(generated.every(TemporaryId.isValid), isTrue);
      expect(generated.toSet().length, generated.length);
      expect(
        TemporaryId.generate(differentFrom: generated.first),
        isNot(generated.first),
      );
      expect(TemporaryId.isValid('真实姓名'), isFalse);
    },
  );

  test(
    'Automatic threshold rotation preserves identity, keys and signed history',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalStore.createSchema(db);
      final store = AnonymousTestStore(db), crypto = CryptoService();
      final controller = StartupController(store);
      await controller.initialize();
      final identity = controller.identity, original = controller.displayName;
      await controller.setAliasRotationLimit(10);
      final group = Group(
        keyEpoch: 1,
        protocolVersion: 2,
        privacyEpoch: 2,
        minClientBuild: 5,
        id: '11111111-1111-4111-8111-111111111111',
        server: 'https://example.com',
        name: '匿名小群',
        ownerId: identity.id,
      );
      final key = crypto.randomBytes(32);
      await store.saveGroup(group);
      await store.saveKey(group, key);
      controller.activeGroup = group;
      controller.groups = [group];
      for (var i = 0; i < 10; i++) {
        await controller.send('第$i条');
      }
      expect(controller.displayName, isNot(original));
      expect(controller.aliasMessagesUsed, 0);
      expect(controller.identity.id, identity.id);
      expect(await store.readSecret('identity-seed'), b64(identity.seed));
      expect(await store.groupKey(group), key);
      expect(controller.groups.single.id, group.id);
      expect(controller.messages.map((m) => m.senderName).toSet(), {original});
      final outbox = await store.outbox(group);
      expect(outbox.length, 10);
      final clear = await crypto.decrypt(
        outbox.first,
        key,
        identity.publicKey,
        expectedGroupId: group.id,
      );
      expect(
        clear['senderName'],
        original,
      ); // Original signed history is not falsified.
      expect(await store.readSecret('display-name'), isNull);
      controller.dispose();
    },
  );

  test(
    'Sender alias is inside authenticated ciphertext, preserving the v1 envelope format',
    () async {
      final crypto = CryptoService(),
          identity = await CryptoService().identity(),
          key = CryptoService().randomBytes(32);
      final encrypted = await crypto.encrypt(
        identity: identity,
        groupId: 'g',
        messageId: 'm',
        text: '消息',
        senderName: '临时·K7M2Q9',
        groupKey: key,
      );
      expect(encrypted.toJson().containsKey('senderName'), isFalse);
      expect(jsonEncode(encrypted.toJson()), isNot(contains('临时·K7M2Q9')));
      final clear = await crypto.decrypt(
        encrypted,
        key,
        identity.publicKey,
        expectedGroupId: 'g',
      );
      expect(clear['senderName'], '临时·K7M2Q9');
      await expectLater(
        crypto.encrypt(
          identity: identity,
          groupId: 'g',
          messageId: 'bad',
          text: '消息',
          senderName: 'bad\nname',
          groupKey: key,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'Legacy messages keep a fixed fallback ID instead of the current profile name',
    () {
      const message = ChatMessage(
        envelope: Envelope(
          groupId: 'g',
          messageId: 'm',
          senderId: 'old-device-identity',
          nonce: '',
          ciphertext: '',
          signature: '',
        ),
        text: '旧消息',
        createdAt: 1,
        state: 'stored',
      );
      expect(message.temporarySenderId, '旧ID·OLD-DE');
      expect(message.senderName, isNull);
    },
  );
}
