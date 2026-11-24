import 'support/security_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestStore extends LocalStore {
  TestStore(Database db) : super(database: db);
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

class JoinApi extends ApiClient {
  JoinApi(Identity identity, CryptoService crypto)
    : super(server: 'https://example.com', identity: identity, crypto: crypto);
  bool reject = true;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    if (reject) throw const ApiException('Invite rejected', status: 403);
    return {
      'groupId': '11111111-1111-4111-8111-111111111111',
      'name': '群',
      'ownerId': identity.id,
      'createdAt': 1,
      'lastSeq': 0,
      'keyEpoch': 1,
      'protocolVersion': 2,
      'privacyEpoch': 2,
      'minClientBuild': 5,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'A rejected invitation cannot poison the key for a later valid invitation',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalStore.createSchema(db);
      final store = TestStore(db),
          crypto = CryptoService(),
          identity = await CryptoService().identity();
      final api = JoinApi(identity, crypto);
      final controller = PermittedController(store: store, crypto: crypto)
        ..identity = identity
        ..server = api.server
        ..api = api;
      Invite invite(int key) => Invite(
        keyEpoch: 1,
        protocolVersion: 2,
        privacyEpoch: 2,
        minClientBuild: 5,
        server: api.server,
        groupId: '11111111-1111-4111-8111-111111111111',
        name: '群',
        inviteId: '22222222-2222-4222-8222-222222222222',
        secret: b64(List.filled(32, key)),
        groupKey: b64(List.filled(32, key)),
        expiresAt: 9999999999999,
      );
      await expectLater(
        controller.join(invite(1)),
        throwsA(isA<ApiException>()),
      );
      expect(store.secrets, isEmpty);
      api.reject = false;
      final joined = await controller.join(invite(2));
      expect(await store.groupKey(joined), List.filled(32, 2));
      expect(
        store.secrets.keys.any((key) => key.startsWith('pending:')),
        isFalse,
      );
      controller.dispose();
    },
  );
  test(
    'Pending join key is promoted only when authenticated membership is confirmed',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalStore.createSchema(db);
      final store = TestStore(db),
          group = const Group(
            keyEpoch: 1,
            protocolVersion: 2,
            privacyEpoch: 2,
            minClientBuild: 5,
            id: 'g',
            server: 'https://example.com',
            name: '群',
            ownerId: 'owner',
          );
      await store.savePendingKey(group, List.filled(32, 7));
      expect(await store.groupKey(group), isNull);
      await store.recoverPendingKey(group);
      expect(await store.groupKey(group), List.filled(32, 7));
      expect(
        store.secrets.keys.any((key) => key.startsWith('pending:')),
        isFalse,
      );
      await store.close();
    },
  );
}
