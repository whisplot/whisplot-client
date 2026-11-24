import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/client_security.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/default_connection.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:nearlink/services/media_service.dart';
import 'package:nearlink/services/message_notifications.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/security_fixture.dart';

class DurableTestStore extends LocalStore {
  DurableTestStore(Database superDatabase) : super(database: superDatabase);
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

  @override
  Future<List<String>> listSecretKeys() async => secrets.keys.toList();

  @override
  Future<void> close() async {}
}

class SecurityFixture {
  SecurityFixture(
    this.db,
    this.store,
    this.crypto,
    this.identity,
    this.authority,
  );
  final Database db;
  final DurableTestStore store;
  final CryptoService crypto;
  final Identity identity, authority;
  late Group group;
  late Map<String, dynamic> policy;
  late ChatController controller;
  String? encryptionKey;
  Map<String, dynamic>? ownerWrap;
  bool rejectWrites = false, loseRekeyResponse = false;
  int registrations = 0, rekeys = 0, posts = 0;
  final posted = <Map<String, dynamic>>[];
  final extraMembers = <Map<String, dynamic>>[];
  final grantedWraps = <Map<String, dynamic>>[];
  final rotatedWraps = <Map<String, dynamic>>[];
  final remoteMessages = <Map<String, dynamic>>[];
  final requests = <http.Request>[];
  Future<http.Response?> Function(http.Request)? extraHandler;
  MediaService? media;
  MessageNotificationService? notifications;
  static Future<SecurityFixture> create({
    String databasePath = inMemoryDatabasePath,
    int keyEpoch = 1,
    int? expiresAt,
    MediaService? media,
  }) async {
    final db = await databaseFactoryFfi.openDatabase(databasePath);
    await LocalStore.createSchema(db);
    final crypto = CryptoService(), store = DurableTestStore(db);
    final f = SecurityFixture(
      db,
      store,
      crypto,
      await crypto.identity(),
      await testAuthority(crypto),
    );
    f.media = media;
    f.group = Group(
      id: '11111111-1111-4111-8111-111111111111',
      server: 'https://fixture.example',
      name: 'kept group',
      ownerId: f.identity.id,
      keyEpoch: keyEpoch,
      protocolVersion: keyEpoch == 0 ? 1 : 2,
      privacyEpoch: keyEpoch == 0 ? 1 : 2,
      minClientBuild: keyEpoch == 0 ? 0 : 5,
    );
    await store.writeSecret('identity-seed', b64(f.identity.seed));
    await store.writeSecret(
      ChatController.connectionSettingsKey,
      jsonEncode({'v': 1, 'server': f.group.server, 'code': 'test-app-code'}),
    );
    await store.saveGroup(f.group);
    await store.saveKey(f.group, List.filled(32, 41));
    f.policy = await policyWire(crypto, expiresAt: expiresAt);
    addTearDown(() async {
      f.controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await db.close();
    });
    await f.start();
    return f;
  }

  Future<void> start() async {
    controller = ChatController(
      store: store,
      crypto: crypto,
      media: media,
      notifications: notifications,
      defaultConnection: const DefaultConnection(),
      authorityPublicKey: authority.publicKey,
      apiFactory:
          ({
            required server,
            required identity,
            required crypto,
            required registrationCode,
          }) => ApiClient(
            server: server,
            identity: identity,
            crypto: crypto,
            registrationCode: registrationCode,
            client: MockClient(handle),
          ),
    );
    await controller.initialize().timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError("initialize hung"),
    );
    await controller.reconnect().timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError(
        "reconnect hung; paths=${requests.map((r) => r.url.path).toList()} error=${controller.error}",
      ),
    );
  }

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final override = await extraHandler?.call(request);
    if (override != null) return override;
    final path = request.url.path;
    Map<String, dynamic> data = {};
    if (request.body.isNotEmpty) data = jsonDecode(request.body);
    Object result = {};
    if (path == '/client-policy') {
      result = policy;
    } else if (path == '/v1/devices') {
      registrations++;
      encryptionKey = data['encryptionPublicKey'];
      result = {'ok': true};
    } else if (path == '/v1/groups') {
      result = {
        'groups': [group.toJson()],
      };
    } else if (path.endsWith('/rekey')) {
      rekeys++;
      expect(data['expectedKeyEpoch'], group.keyEpoch);
      group = group.copyWith(
        keyEpoch: group.keyEpoch + 1,
        protocolVersion: 2,
        privacyEpoch: 2,
        minClientBuild: group.minClientBuild,
        rekeyRequired: false,
      );
      ownerWrap = Map<String, dynamic>.from(
        (data['wrappedKeys'] as List).firstWhere(
          (w) => w['recipientId'] == identity.id,
        ),
      );
      rotatedWraps.addAll(
        (data['wrappedKeys'] as List).map((w) => Map<String, dynamic>.from(w)),
      );
      for (final member in extraMembers) {
        if (rotatedWraps.any((w) => w['recipientId'] == member['deviceId'])) {
          member['grantedKeyEpoch'] = group.keyEpoch;
        }
      }
      result = {
        'rotationId': data['rotationId'],
        'keyEpoch': group.keyEpoch,
        'cutoverSeq': 0,
      };
      if (loseRekeyResponse) {
        loseRekeyResponse = false;
        throw const SocketException('response lost after commit');
      }
    } else if (path.endsWith('/keys')) {
      if (request.method == 'POST') {
        final wraps = (data['wrappedKeys'] as List)
            .map((w) => Map<String, dynamic>.from(w))
            .toList();
        grantedWraps.addAll(wraps);
        for (final member in extraMembers) {
          if (wraps.any((w) => w['recipientId'] == member['deviceId'])) {
            member['grantedKeyEpoch'] = data['keyEpoch'];
          }
        }
        result = {
          'keyEpoch': group.keyEpoch,
          'granted': wraps.map((w) => w['recipientId']).toList(),
        };
      } else {
        result = {'keyEpoch': group.keyEpoch, 'wrappedKey': ownerWrap};
      }
    } else if (path.endsWith('/messages') && request.method == 'POST') {
      if (rejectWrites) {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'client_upgrade_required',
              'policy': {
                'minClientBuild': AppSecurity.clientBuild + 1,
                'protocolVersion': 2,
                'privacyEpoch': 2,
                'policyRevision': 2,
              },
            },
          }),
          426,
        );
      }
      posted.add(data);
      posts++;
      result = {'seq': posts, 'storedAt': 100};
    } else if (path.endsWith('/messages')) {
      final after = int.parse(request.url.queryParameters['after'] ?? '0');
      result = {
        'messages': remoteMessages
            .where((m) => (m['seq'] as int) > after)
            .toList(),
        'nextCursor': remoteMessages.isEmpty
            ? after
            : remoteMessages.last['seq'],
        'hasMore': false,
      };
    } else if (path.endsWith('/ack')) {
      result = {'ok': true};
    } else {
      result = {
        ...group.toJson(),
        'members': [
          ...extraMembers,
          {
            'deviceId': identity.id,
            'publicKey': identity.publicKey,
            'displayName': '匿名成员',
            'encryptionPublicKey': encryptionKey,
            'clientBuild': AppSecurity.clientBuild,
            'protocolVersion': 2,
            'privacyEpoch': 2,
            'grantedKeyEpoch': group.keyEpoch,
          },
        ],
      };
    }
    return http.Response(
      jsonEncode(result),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  void selectGroup() {
    controller.activeGroup = group;
  }
}

Future<void> settleUntil(bool Function() check) async {
  for (var i = 0; i < 100; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(check(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'v2 HTTP signs claims; public policy carries no device or access headers',
    () async {
      final f = await SecurityFixture.create();
      expect(f.controller.participationAllowed, isTrue);
      final policyRequest = f.requests.firstWhere(
        (r) => r.url.path == '/client-policy',
      );
      expect(
        policyRequest.headers.keys.any((k) => k.toLowerCase().startsWith('x-')),
        isFalse,
      );
      final request = f.requests.firstWhere((r) => r.url.path == '/v1/devices');
      final h = request.headers;
      final preimage =
          'nearlink-request-v2\nPOST\n/v1/devices\n${h['X-Timestamp']}\n${h['X-Nonce']}\n${await f.crypto.hash(utf8.encode(request.body))}\n${AppSecurity.clientBuild}\n2\n2';
      expect(
        await f.crypto.verify(
          f.identity.publicKey,
          preimage,
          h['X-Signature']!,
        ),
        isTrue,
      );
      expect(h['X-Client-Build'], '${AppSecurity.clientBuild}');
      expect(f.store.secrets[ChatController.encryptionSeedKey], isNotNull);
      expect(f.encryptionKey, isNot(f.identity.publicKey));
    },
  );
  test(
    '426 blocks every later send, preserves outbox and persists signed floor across restart',
    () async {
      final f = await SecurityFixture.create();
      f.selectGroup();
      f.rejectWrites = true;
      f.policy = await policyWire(
        f.crypto,
        revision: 2,
        minBuild: AppSecurity.clientBuild + 1,
      );
      await f.controller.send('retained locally');
      await settleUntil(
        () =>
            f.controller.participationBlock != null &&
            !f.controller.checkingPolicy,
      );
      expect(await f.store.outbox(f.group), hasLength(1));
      final used = await f.store.readAliasState(), calls = f.requests.length;
      await expectLater(
        f.controller.send('blocked'),
        throwsA(isA<UpgradeRequiredException>()),
      );
      await expectLater(
        f.controller.toggleReaction('none', '👍'),
        throwsA(isA<UpgradeRequiredException>()),
      );
      expect(await f.store.readAliasState(), used);
      expect(f.requests.length, calls);
      await settleUntil(
        () => (f.controller.participationBlock?.expired) == false,
      );
      f.controller.dispose();
      await Future<void>.delayed(Duration.zero);
      f.policy = await policyWire(f.crypto);
      final before = f.registrations;
      await f.start();
      expect(f.controller.participationAllowed, isFalse);
      expect(f.registrations, before);
      await f.controller.openGroup(f.group);
      expect(f.controller.messages.single.text, 'retained locally');
    },
  );
  test(
    'expired signed policy stops admission without discarding identity or messages',
    () async {
      final f = await SecurityFixture.create();
      f.policy = await policyWire(
        f.crypto,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 700,
      );
      await f.controller.refreshPolicy();
      expect(f.controller.participationAllowed, isTrue);
      f.selectGroup();
      final seed = f.store.secrets['identity-seed'];
      await settleUntil(() => !f.controller.participationAllowed);
      await expectLater(
        f.controller.send('late'),
        throwsA(isA<UpgradeRequiredException>()),
      );
      expect(f.store.secrets['identity-seed'], seed);
      expect(await f.store.outbox(f.group), isEmpty);
    },
  );
  test(
    'a cached older signed policy cannot undo an explicit server 426',
    () async {
      final f = await SecurityFixture.create();
      f.selectGroup();
      f.rejectWrites = true;
      await f.controller.send('held');
      await settleUntil(
        () =>
            f.controller.participationBlock != null &&
            !f.controller.checkingPolicy,
      );
      final registrations = f.registrations;
      f.controller.clearError();
      f.controller.viewLocalHistory();
      await f.controller.retryConnection();
      expect(f.controller.participationAllowed, isFalse);
      expect(f.registrations, registrations);
      expect(await f.store.outbox(f.group), hasLength(1));
    },
  );
  test(
    'in-place rekey lost-response recovery retains old key and never sends retired outbox',
    () async {
      final f = await SecurityFixture.create(keyEpoch: 0);
      f.selectGroup();
      final old = f.group, oldKey = await f.store.groupKey(old);
      final envelope = await f.crypto.encrypt(
        identity: f.identity,
        groupId: old.id,
        messageId: '22222222-2222-4222-8222-222222222222',
        text: 'legacy pending',
        groupKey: oldKey!,
      );
      await f.store.queue(old, envelope);
      await expectLater(
        f.controller.send('before migration'),
        throwsA(isA<ApiException>()),
      );
      f.loseRekeyResponse = true;
      await expectLater(
        f.controller.rekeyActiveGroup(),
        throwsA(isA<SocketException>()),
      );
      expect(
        await f.store.readState('pending-rekey:${old.storageId}'),
        isNotNull,
      );
      await f.controller.rekeyActiveGroup();
      expect(f.rekeys, 1);
      expect(f.group.id, old.id);
      expect(f.controller.activeGroup!.keyEpoch, 1);
      expect(await f.store.groupKey(f.group, epoch: 0), oldKey);
      expect(await f.store.groupKey(f.group), isNot(oldKey));
      expect(f.controller.messages.single.text, 'legacy pending');
      await f.controller.flushOutbox(f.group);
      expect(f.posts, 0);
      expect(await f.store.outbox(f.group), isEmpty);
      expect((await f.store.messages(f.group)).single['state'], 'retired');
    },
  );
  test(
    'newer owner grants and rotates for compatible build 5 but excludes build 4',
    () async {
      final f = await SecurityFixture.create();
      expect(AppSecurity.clientBuild, greaterThan(5));
      final compatible = await f.crypto.identity(),
          obsolete = await f.crypto.identity();
      final compatibleEncryption = await f.crypto.encryptionIdentity(),
          obsoleteEncryption = await f.crypto.encryptionIdentity();
      f.extraMembers.addAll([
        {
          'deviceId': compatible.id,
          'publicKey': compatible.publicKey,
          'displayName': 'compatible',
          'encryptionPublicKey': compatibleEncryption.publicKey,
          'clientBuild': 5,
          'protocolVersion': 2,
          'privacyEpoch': 2,
          'grantedKeyEpoch': 0,
        },
        {
          'deviceId': obsolete.id,
          'publicKey': obsolete.publicKey,
          'displayName': 'obsolete',
          'encryptionPublicKey': obsoleteEncryption.publicKey,
          'clientBuild': 4,
          'protocolVersion': 2,
          'privacyEpoch': 2,
          'grantedKeyEpoch': 0,
        },
      ]);
      f.selectGroup();
      await f.controller.grantPendingKeys();
      expect(f.grantedWraps.map((w) => w['recipientId']), [compatible.id]);
      final granted = await f.crypto.unwrapGroupKey(
        wrapped: WrappedGroupKey.fromJson(f.grantedWraps.single),
        groupId: f.group.id,
        ownerPublicKey: f.identity.publicKey,
        expectedOwnerId: f.identity.id,
        recipient: compatible,
        encryptionIdentity: compatibleEncryption,
      );
      expect(granted, await f.store.groupKey(f.group));
      f.loseRekeyResponse = true;
      await expectLater(
        f.controller.rekeyActiveGroup(),
        throwsA(isA<SocketException>()),
      );
      expect(f.rotatedWraps.map((w) => w['recipientId']).toSet(), {
        f.identity.id,
        compatible.id,
      });
      await f.controller.rekeyActiveGroup();
      final rotated = await f.crypto.unwrapGroupKey(
        wrapped: WrappedGroupKey.fromJson(
          f.rotatedWraps.firstWhere((w) => w['recipientId'] == compatible.id),
        ),
        groupId: f.group.id,
        ownerPublicKey: f.identity.publicKey,
        expectedOwnerId: f.identity.id,
        recipient: compatible,
        encryptionIdentity: compatibleEncryption,
      );
      expect(rotated, await f.store.groupKey(f.group));
      expect(rotated, isNot(granted));
    },
  );
  test(
    'upgraded existing member waits without global gate and later unwraps owner grant',
    () async {
      final f = await SecurityFixture.create();
      final owner = await f.crypto.identity(),
          ownerEncryption = await f.crypto.encryptionIdentity();
      final original = f.group;
      f.group = Group(
        id: original.id,
        server: original.server,
        name: original.name,
        ownerId: owner.id,
        keyEpoch: 1,
        protocolVersion: 2,
        privacyEpoch: 2,
        minClientBuild: 5,
      );
      f.extraMembers.add({
        'deviceId': owner.id,
        'publicKey': owner.publicKey,
        'displayName': '群主',
        'encryptionPublicKey': ownerEncryption.publicKey,
        'clientBuild': 5,
        'protocolVersion': 2,
        'privacyEpoch': 2,
        'grantedKeyEpoch': 1,
      });
      await f.store.saveGroup(f.group);
      await f.store.deleteSecret(
        'group-key:${b64(utf8.encode(f.group.storageId))}:epoch:1',
      );
      final seed = f.store.secrets['identity-seed'],
          encryption = f.encryptionKey!;
      f.controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await f.start();
      f.selectGroup();
      expect(f.controller.participationAllowed, isTrue);
      expect(f.controller.canSendToGroup(f.group), isFalse);
      expect(await f.store.groupKey(f.group), isNull);
      final newKey = List<int>.filled(32, 99);
      final valid = await f.crypto.encrypt(
        identity: owner,
        groupId: f.group.id,
        keyEpoch: 1,
        messageId: '33333333-3333-4333-8333-333333333333',
        text: 'recover after grant',
        groupKey: newKey,
      );
      final poison = await f.crypto.encrypt(
        identity: owner,
        groupId: f.group.id,
        keyEpoch: 1,
        messageId: '44444444-4444-4444-8444-444444444444',
        text: 'invalid AEAD under current key',
        groupKey: List.filled(32, 98),
      );
      f.remoteMessages.addAll([
        {...valid.toJson(), 'seq': 1, 'storedAt': 100},
        {...poison.toJson(), 'seq': 2, 'storedAt': 101},
      ]);
      await f.controller.syncActive();
      expect(
        (await f.store.messages(f.group)).map((m) => m['state']),
        everyElement('locked'),
      );
      expect(f.controller.messages, isEmpty);
      final fetches = f.requests
          .where((r) => r.url.path.endsWith('/messages'))
          .length;
      f.ownerWrap = (await f.crypto.wrapGroupKey(
        sender: owner,
        groupId: f.group.id,
        keyEpoch: 1,
        groupKey: newKey,
        recipientId: f.identity.id,
        recipientPublicKey: encryption,
      )).toJson();
      await f.controller.grantPendingKeys();
      expect(await f.store.groupKey(f.group), newKey);
      expect(f.controller.canSendToGroup(f.group), isTrue);
      expect(f.store.secrets['identity-seed'], seed);
      expect(f.controller.messages.single.text, 'recover after grant');
      expect(await f.store.quarantinedCount(f.group), 1);
      expect(await f.store.cursor(f.group), 2);
      expect(
        f.requests.where((r) => r.url.path.endsWith('/messages')).length,
        fetches,
      );
    },
  );
}
