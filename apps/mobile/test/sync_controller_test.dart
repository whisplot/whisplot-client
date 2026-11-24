import 'support/security_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MemorySecretsStore extends LocalStore {
  MemorySecretsStore(Database db) : super(database: db);
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

class MailboxApi extends ApiClient {
  MailboxApi(Identity id, CryptoService crypto, this.page)
    : super(server: 'https://example.com', identity: id, crypto: crypto);
  final List<Map<String, dynamic>> page;
  int acks = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    if (path.contains('/messages?')) {
      return {'messages': page, 'nextCursor': 2, 'hasMore': false};
    }
    if (path.endsWith('/ack')) {
      acks++;
      return {'ok': true};
    }
    throw StateError('Unexpected $method $path');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'Controller quarantines signed but undecryptable message and shows later valid text',
    () async {
      final fixture = jsonDecode(
        File('../../fixtures/protocol-v1.json').readAsStringSync(),
      );
      final crypto = CryptoService(),
          identity = await CryptoService().identity(
            unb64(fixture['identitySeed']),
          );
      final valid = Envelope.fromJson(fixture['envelope']);
      final group = Group(
        id: valid.groupId,
        server: 'https://example.com',
        name: '群',
        ownerId: identity.id,
      );
      final poison = await crypto.encrypt(
        identity: identity,
        groupId: group.id,
        messageId: '44444444-4444-4444-8444-444444444444',
        text: 'wrong key',
        groupKey: List.filled(32, 99),
      );
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalStore.createSchema(db);
      final store = MemorySecretsStore(db);
      await store.saveGroup(group);
      await store.saveKey(group, unb64(fixture['groupKey']));
      await store.saveMembers(group, [
        Member(identity.id, identity.publicKey, 'sender'),
      ]);
      final api = MailboxApi(identity, crypto, [
        {...poison.toJson(), 'seq': 1, 'storedAt': 100},
        {...valid.toJson(), 'seq': 2, 'storedAt': 101},
      ]);
      final controller = PermittedController(store: store, crypto: crypto)
        ..identity = identity
        ..api = api
        ..activeGroup = group;
      await controller.syncActive();
      expect(await store.cursor(group), 2);
      expect(controller.quarantinedMessages, 1);
      expect(controller.messages.single.text, '你好，NearLink 🔐');
      expect(api.acks, 0);
      expect(controller.error, contains('已隔离'));
      controller.dispose();
    },
  );
}
