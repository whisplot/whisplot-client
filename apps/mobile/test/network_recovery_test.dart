import 'support/security_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/default_connection.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:nearlink/services/network_monitor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class Paths implements NetworkMonitor {
  final events = StreamController<NetworkPathChange>.broadcast();
  @override
  Stream<NetworkPathChange> get changes => events.stream;
  void emit(bool available) =>
      events.add(NetworkPathChange(available: available));
}

class SecretsStore extends LocalStore {
  SecretsStore(Database database) : super(database: database);
  final secrets = <String, String>{};
  Completer<void>? blockedMessages;
  int messageReads = 0;
  @override
  Future<List<Map<String, Object?>>> messages(Group group) async {
    final snapshot = await super.messages(group);
    messageReads++;
    final blocked = blockedMessages;
    blockedMessages = null;
    if (blocked != null) await blocked.future;
    return snapshot;
  }

  @override
  Future<String?> readSecret(String key) async => secrets[key];
  @override
  Future<void> writeSecret(String key, String value) async =>
      secrets[key] = value;
  @override
  Future<void> deleteSecret(String key) async => secrets.remove(key);
  @override
  Future<void> close() async {} // Fixture closes after async controller cleanup.
}

class RecoveryApi extends ApiClient {
  RecoveryApi({
    required super.server,
    required super.identity,
    required super.crypto,
    required super.registrationCode,
    required this.wsUrl,
  });
  final String wsUrl;
  int resets = 0, registrations = 0, healthChecks = 0, sends = 0;
  bool healthy = true;
  String encryptionKey = "";
  List<Map<String, dynamic>> groupsReply = [];
  List<Map<String, dynamic>> page = [];
  Completer<Map<String, dynamic>>? blockedSend, blockedGroups;
  @override
  void resetTransport() {
    resets++;
    super.resetTransport();
  }

  @override
  Future<void> checkHealth() async {
    healthChecks++;
    if (!healthy) throw const SocketException('simulated changed route');
  }

  @override
  Future<Map<String, dynamic>> iceConfiguration() async => {
    'iceServers': [],
    'relayConfigured': false,
  };
  @override
  Future<WebSocket> socket(String groupId) => WebSocket.connect(wsUrl);
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    if (path == '/v1/devices') {
      registrations++;
      encryptionKey = payload!['encryptionPublicKey'];
      return {'ok': true};
    }
    if (path == '/v1/groups') {
      final blocked = blockedGroups;
      blockedGroups = null;
      if (blocked != null) return blocked.future;
      return {'groups': groupsReply};
    }
    if (method == 'POST' && path.endsWith('/messages')) {
      sends++;
      final blocked = blockedSend;
      blockedSend = null;
      if (blocked != null) return blocked.future;
      final result = {
        'seq': 7,
        'storedAt': 100,
        'messageId': payload!['messageId'],
      };
      page = [
        {...payload, ...result},
      ];
      return result;
    }
    if (path.contains('/messages?')) {
      final cursor = int.parse(Uri.parse(path).queryParameters['after']!);
      return {
        'messages': page.where((m) => (m['seq'] as int) > cursor).toList(),
        'nextCursor': page.isEmpty ? cursor : 7,
        'hasMore': false,
      };
    }
    if (path.endsWith('/ack')) return {'ok': true};
    if (path.endsWith('/participation')) {
      return ticketWire(crypto, identity, path.split('/')[3], encryptionKey);
    }
    return {
      ...groupsReply.firstWhere((g) => g['groupId'] == path.split('/')[3]),
      'members': [
        {
          'deviceId': identity.id,
          'publicKey': identity.publicKey,
          'displayName': '临时·AAAAAA',
          'encryptionPublicKey': encryptionKey,
          'clientBuild': 5,
          'protocolVersion': 2,
          'privacyEpoch': 2,
          'grantedKeyEpoch': 1,
        },
      ],
    };
  }
}

Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Recovery did not finish');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late SecretsStore store;
  late Paths paths;
  late ChatController controller;
  late RecoveryApi api;
  late HttpServer ws;
  final sockets = <WebSocket>[];
  final fixture = jsonDecode(
    File('../../fixtures/protocol-v1.json').readAsStringSync(),
  );
  late Group group;
  Future<void> initialize({
    bool withGroup = false,
    Duration health = const Duration(minutes: 1),
  }) async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalStore.createSchema(db);
    store = SecretsStore(db);
    store.secrets['identity-seed'] = fixture['identitySeed'];
    store.secrets['display-name'] = '临时·AAAAAA';
    await store.writeState(ChatController.policyStateKey, {
      'policyRevision': 1,
      'minClientBuild': 5,
      'protocolVersion': 2,
      'privacyEpoch': 2,
    });
    paths = Paths();
    ws = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    ws.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((_) {});
    });
    controller = PermittedController(
      authorityPublicKey: (await testAuthority(CryptoService())).publicKey,
      store: store,
      networkMonitor: paths,
      networkDebounce: const Duration(milliseconds: 20),
      healthInterval: health,
      defaultConnection: const DefaultConnection(
        server: 'https://example.com',
        registrationCode: 'fixture-code',
      ),
      apiFactory:
          ({
            required server,
            required identity,
            required crypto,
            required registrationCode,
          }) {
            api = RecoveryApi(
              server: server,
              identity: identity,
              crypto: crypto,
              registrationCode: registrationCode,
              wsUrl: 'ws://127.0.0.1:${ws.port}',
            );
            return api;
          },
    );
    await controller.initialize();
    await controller.reconnect();
    if (withGroup) {
      group = Group(
        keyEpoch: 1,
        protocolVersion: 2,
        privacyEpoch: 2,
        minClientBuild: 5,
        id: fixture['envelope']['groupId'],
        server: api.server,
        name: 'existing',
        ownerId: controller.identity.id,
      );
      final oldEnvelope = Envelope.fromJson(fixture['envelope']);
      final clear = await controller.crypto.decrypt(
        oldEnvelope,
        unb64(fixture['groupKey']),
        controller.identity.publicKey,
        expectedGroupId: group.id,
      );
      fixture['envelope'] = (await controller.crypto.encrypt(
        identity: controller.identity,
        groupId: group.id,
        messageId: oldEnvelope.messageId,
        text: clear['text'],
        groupKey: unb64(fixture['groupKey']),
        keyEpoch: 1,
      )).toJson();
      await store.saveKey(group, unb64(fixture['groupKey']));
      await store.saveGroup(group);
      api.groupsReply = [Map<String, dynamic>.from(group.toJson())];
      await controller.refreshGroups();
      await controller.openGroup(group);
      await eventually(() => controller.connection.socketOnline);
    }
    paths.emit(true); // native initial state, not a route transition
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  tearDown(() async {
    controller.dispose();
    await paths.events.close();
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    await ws.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await db.close();
  });
  test(
    'initial route is ignored and event burst restores existing group once',
    () async {
      await initialize(withGroup: true);
      final identity = controller.identity.id, alias = controller.displayName;
      final secrets = Map.of(store.secrets), before = api.registrations;
      for (var i = 0; i < 8; i++) {
        paths.emit(i.isEven);
      }
      paths.emit(true);
      await eventually(
        () =>
            api.resets == 1 &&
            api.registrations == before + 1 &&
            controller.connection.socketOnline,
      );
      expect(controller.activeGroup?.id, group.id);
      expect(controller.identity.id, identity);
      expect(controller.displayName, alias);
      expect(store.secrets, secrets);
      expect(api.sends, 0);
      expect(api.resets, 1);
    },
  );
  test(
    'old delayed POST cannot overwrite replay result after route change',
    () async {
      await initialize(withGroup: true);
      final envelope = Envelope.fromJson(fixture['envelope']);
      await store.queue(group, envelope);
      final late = Completer<Map<String, dynamic>>();
      api.blockedSend = late;
      final oldFlush = controller.flushOutbox(group);
      await eventually(() => api.sends == 1);
      paths.emit(true);
      await eventually(
        () => api.sends == 2 && controller.connection.socketOnline,
      );
      late.complete({
        'seq': 99,
        'storedAt': 999,
        'messageId': envelope.messageId,
      });
      await oldFlush;
      expect(await store.outbox(group), isEmpty);
      final records = await store.messages(group);
      expect(records.single['seq'], 7);
      expect(await store.cursor(group), 7);
      expect(controller.activeGroup?.id, group.id);
      expect(controller.messages.single.text, '你好，NearLink 🔐');
    },
  );
  test(
    'older local message snapshot cannot replace a newer compose result',
    () async {
      await initialize(withGroup: true);
      await store.saveP2p(group, Envelope.fromJson(fixture['envelope']));
      final late = Completer<void>();
      store.blockedMessages = late;
      final before = store.messageReads;
      final oldSync = controller.syncActive();
      await eventually(() => store.messageReads > before);
      await controller.send('new local text');
      await controller.flushOutbox(group);
      expect(
        controller.messages.any((m) => m.text == 'new local text'),
        isTrue,
      );
      late.complete();
      await oldSync;
      expect(
        controller.messages.any((m) => m.text == 'new local text'),
        isTrue,
      );
    },
  );

  test(
    'manual retry replaces transport without path event and preserves local chat',
    () async {
      await initialize(withGroup: true);
      await store.saveP2p(group, Envelope.fromJson(fixture['envelope']));
      await controller.syncActive();
      final identity = controller.identity.id, alias = controller.displayName;
      final generation = api.transportGeneration;
      final secrets = Map.of(store.secrets);
      final cursor = await store.cursor(group);
      expect(controller.messages.single.text, '你好，NearLink 🔐');
      await controller.retryConnection();
      await eventually(() => controller.connection.socketOnline);
      expect(api.transportGeneration, generation + 1);
      expect(api.resets, 1);
      expect(controller.identity.id, identity);
      expect(controller.displayName, alias);
      expect(store.secrets, secrets);
      expect(controller.activeGroup?.id, group.id);
      expect(controller.groups.single.id, group.id);
      expect(controller.messages.single.text, '你好，NearLink 🔐');
      expect(await store.cursor(group), cursor);
      expect(api.sends, 0);
    },
  );

  test(
    'concurrent reconnects coalesce and obsolete group response is discarded',
    () async {
      await initialize();
      final late = Completer<Map<String, dynamic>>();
      api.blockedGroups = late;
      final before = api.registrations;
      final first = controller.reconnect();
      await eventually(() => api.registrations == before + 1);
      final second = controller.reconnect();
      paths.emit(true);
      await eventually(() => api.resets == 1);
      late.complete({
        'groups': [
          {'groupId': 'stale-group', 'name': 'stale', 'ownerId': 'stale'},
        ],
      });
      await Future.wait([first, second]);
      expect(api.registrations, before + 2);
      expect(controller.groups, isEmpty);
      expect(await store.groups(api.server), isEmpty);
      expect(controller.online, isTrue);
    },
  );
  test(
    'watchdog recovers without path events and never polls chat history',
    () async {
      await initialize(health: const Duration(milliseconds: 30));
      final before = api.registrations;
      api.healthy = false;
      await eventually(() => api.resets > 0 && !controller.online);
      api.healthy = true;
      await eventually(() => controller.online && api.registrations > before);
      expect(api.healthChecks, greaterThan(0));
      expect(api.sends, 0);
      expect(controller.groups, isEmpty);
    },
  );
}
