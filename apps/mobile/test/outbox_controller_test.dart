import 'support/security_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/local_store.dart';
import 'sync_controller_test.dart' show MemorySecretsStore;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class BlockingApi extends ApiClient {
  BlockingApi(Identity identity, CryptoService crypto)
    : super(server: 'https://example.com', identity: identity, crypto: crypto);
  final entered = Completer<void>(), release = Completer<void>();
  int posts = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    posts++;
    if (posts == 1) {
      entered.complete();
      await release.future;
    }
    return {'seq': posts, 'storedAt': 100, 'messageId': payload!['messageId']};
  }
}

class OtherBackend extends ApiClient {
  OtherBackend(Identity identity, CryptoService crypto)
    : super(
        server: 'https://other.example',
        identity: identity,
        crypto: crypto,
      );
  int posts = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    posts++;
    throw StateError('Must not send old ciphertext to new backend');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'Message queued during in-flight POST is drained without a reconnect',
    () async {
      final fixture = jsonDecode(
        File('../../fixtures/protocol-v1.json').readAsStringSync(),
      );
      final crypto = CryptoService(),
          identity = await CryptoService().identity(
            unb64(fixture['identitySeed']),
          );
      final old = Envelope.fromJson(fixture['envelope']);
      final clear = await crypto.decrypt(
        old,
        unb64(fixture['groupKey']),
        identity.publicKey,
        expectedGroupId: old.groupId,
      );
      final first = await crypto.encrypt(
        identity: identity,
        groupId: old.groupId,
        messageId: old.messageId,
        text: clear['text'],
        groupKey: unb64(fixture['groupKey']),
        keyEpoch: 1,
      );
      final second = await crypto.encrypt(
        keyEpoch: 1,
        identity: identity,
        groupId: first.groupId,
        messageId: '44444444-4444-4444-8444-444444444444',
        text: 'second',
        groupKey: unb64(fixture['groupKey']),
      );
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalStore.createSchema(db);
      final store = MemorySecretsStore(db),
          group = Group(
            keyEpoch: 1,
            protocolVersion: 2,
            privacyEpoch: 2,
            minClientBuild: 5,
            id: first.groupId,
            server: 'https://example.com',
            name: '群',
            ownerId: identity.id,
          );
      await store.saveGroup(group);
      await store.saveKey(group, unb64(fixture['groupKey']));
      await store.queue(group, first);
      final api = BlockingApi(identity, crypto);
      final controller = PermittedController(store: store, crypto: crypto)
        ..identity = identity
        ..api = api;
      final flushing = controller.flushOutbox(group);
      await api.entered.future;
      await store.queue(group, second);
      final secondFlush = controller.flushOutbox(group);
      api.release.complete();
      await Future.wait([flushing, secondFlush]);
      expect(await store.outbox(group), isEmpty);
      expect(api.posts, 2);
      // Allow the coalesced follow-up pass to complete before disposal.
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
    },
  );
  test(
    'Switching backend during a POST does not send remaining ciphertext to new backend',
    () async {
      final fixture = jsonDecode(
        File('../../fixtures/protocol-v1.json').readAsStringSync(),
      );
      final crypto = CryptoService(),
          identity = await CryptoService().identity(
            unb64(fixture['identitySeed']),
          );
      final old = Envelope.fromJson(fixture['envelope']);
      final clear = await crypto.decrypt(
        old,
        unb64(fixture['groupKey']),
        identity.publicKey,
        expectedGroupId: old.groupId,
      );
      final first = await crypto.encrypt(
        identity: identity,
        groupId: old.groupId,
        messageId: old.messageId,
        text: clear['text'],
        groupKey: unb64(fixture['groupKey']),
        keyEpoch: 1,
      );
      final second = await crypto.encrypt(
        keyEpoch: 1,
        identity: identity,
        groupId: first.groupId,
        messageId: '44444444-4444-4444-8444-444444444444',
        text: 'second',
        groupKey: unb64(fixture['groupKey']),
      );
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalStore.createSchema(db);
      final store = MemorySecretsStore(db),
          group = Group(
            keyEpoch: 1,
            protocolVersion: 2,
            privacyEpoch: 2,
            minClientBuild: 5,
            id: first.groupId,
            server: 'https://example.com',
            name: '群',
            ownerId: identity.id,
          );
      await store.saveGroup(group);
      await store.saveKey(group, unb64(fixture['groupKey']));
      await store.queue(group, first);
      await store.queue(group, second);
      final original = BlockingApi(identity, crypto),
          other = OtherBackend(identity, crypto);
      final controller = PermittedController(store: store, crypto: crypto)
        ..identity = identity
        ..api = original;
      final flushing = controller.flushOutbox(group);
      await original.entered.future;
      controller.api = other;
      original.release.complete();
      await flushing;
      expect(original.posts, 1);
      expect(other.posts, 0);
      expect((await store.outbox(group)).length, 2);
      original.close();
      controller.dispose();
    },
  );
}
