import 'support/security_fixture.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/default_connection.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/core/temporary_id.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const defaults = DefaultConnection(
  server: 'https://bundled.example',
  registrationCode: 'public-test-app-code',
);

Map<String, String> afterAliasMigration(
  Map<String, String> saved,
  Map<String, String> current,
) => {
  for (final key in [
    ChatController.encryptionSeedKey,
    ChatController.encryptionEnrollmentKey,
  ])
    if (current[key] != null) key: current[key]!,
  for (final entry in saved.entries)
    if (entry.key != 'display-name') entry.key: entry.value,
  ChatController.aliasMigrationKey: '1',
};

class ConnectionStore extends LocalStore {
  ConnectionStore(Database database) : super(database: database);
  final secrets = <String, String>{};
  bool failConnectionSave = false;
  @override
  Future<String?> readSecret(String key) async => secrets[key];
  @override
  Future<void> writeSecret(String key, String value) async {
    if (key == ChatController.connectionSettingsKey && failConnectionSave) {
      throw StateError('simulated secure storage unavailable');
    }
    secrets[key] = value;
  }

  @override
  Future<void> deleteSecret(String key) async => secrets.remove(key);
  // A fixture owns the persistent SQLite handle across controller recreation.
  @override
  Future<void> close() async {}
}

class RegistrationApi extends ApiClient {
  RegistrationApi({
    required super.server,
    required super.identity,
    required super.crypto,
    required super.registrationCode,
    required this.offline,
  });
  final bool Function() offline;
  final calls = <({String method, String path, Map<String, String> headers})>[];
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    calls.add((
      method: method,
      path: path,
      headers: await signedHeaders(
        method,
        path,
        payload == null ? '' : jsonEncode(payload),
      ),
    ));
    if (offline()) throw const SocketException('test transport offline');
    if (method == 'POST' && path == '/v1/devices') return {'ok': true};
    if (method == 'GET' && path == '/v1/groups') return {'groups': []};
    throw StateError('Unexpected test request');
  }
}

class Fixture {
  Fixture(this.db) : store = ConnectionStore(db);
  final Database db;
  final ConnectionStore store;
  final controllers = <ChatController>[];
  final clients = <RegistrationApi>[];
  bool offline = false;
  static Future<Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'hello-mentor-default-test-',
    );
    final db = await databaseFactoryFfi.openDatabase(
      '${directory.path}/store.db',
    );
    await LocalStore.createSchema(db);
    final fixture = Fixture(db);
    addTearDown(() async {
      for (final controller in fixture.controllers) {
        controller.dispose();
      }
      await db.close();
      await directory.delete(recursive: true);
    });
    return fixture;
  }

  ChatController controller({DefaultConnection connection = defaults}) {
    final controller = PermittedController(
      store: store,
      defaultConnection: connection,
      apiFactory:
          ({
            required server,
            required identity,
            required crypto,
            required registrationCode,
          }) {
            final client = RegistrationApi(
              server: server,
              identity: identity,
              crypto: crypto,
              registrationCode: registrationCode,
              offline: () => offline,
            );
            clients.add(client);
            return client;
          },
    );
    controllers.add(controller);
    return controller;
  }

  void disposeController(ChatController controller) {
    controllers.remove(controller);
    controller.dispose();
  }

  Future<Identity> savedIdentity() async {
    final identity = await CryptoService().identity();
    store.secrets['identity-seed'] = b64(identity.seed);
    store.secrets['display-name'] = '临时·ABC234';
    return identity;
  }
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Controller did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('saved official endpoints switch to the new bundled service', () async {
    final f = await Fixture.create();
    final original = await f.savedIdentity();
    const current = DefaultConnection(
      server: Invite.defaultServer,
      registrationCode: 'new-test-code',
    );
    f.store.secrets[ChatController.connectionSettingsKey] = jsonEncode({
      'v': 1,
      'server': 'https://nearlink-api.nearlink-lovelyjhwsb.workers.dev',
      'code': 'previous-test-code',
    });
    await f.store.writeState(ChatController.policyStateKey, {
      'minClientBuild': 99,
    });
    final controller = f.controller(connection: current);
    await controller.initialize();
    await until(() => controller.online);
    expect(controller.identity.id, original.id);
    expect(controller.server, current.server);
    expect(controller.registrationCode, current.registrationCode);
    expect(
      f.clients.single.calls.first.headers['X-Registration-Code'],
      current.registrationCode,
    );
    expect(jsonDecode(f.store.secrets[ChatController.connectionSettingsKey]!), {
      'v': 1,
      'server': current.server,
      'code': current.registrationCode,
    });
  });

  test(
    'Fresh install persists a complete default and automatically registers',
    () async {
      final f = await Fixture.create(), c = f.controller();
      await c.initialize();
      await until(() => c.online && f.clients.single.calls.length == 2);
      expect(c.ready && c.configured && c.usingDefaultConnection, isTrue);
      expect(TemporaryId.isValid(c.displayName), isTrue);
      expect(c.server, defaults.server);
      expect(c.registrationCode, defaults.registrationCode);
      expect(f.clients.single.calls.first.path, '/v1/devices');
      expect(
        f.clients.single.calls.first.headers['X-Registration-Code'],
        defaults.registrationCode,
      );
      expect(
        jsonDecode(f.store.secrets[ChatController.connectionSettingsKey]!),
        {'v': 1, 'server': defaults.server, 'code': defaults.registrationCode},
      );
      expect(f.store.secrets.containsKey('server'), isFalse);
    },
  );

  test(
    'Saved default and identity survive controller recreation and changed build defaults',
    () async {
      final f = await Fixture.create(), c = f.controller();
      await c.initialize();
      await until(() => c.online && f.clients.single.calls.length == 2);
      final identity = c.identity.id, alias = c.displayName;
      final saved = Map<String, String>.from(f.store.secrets);
      f.disposeController(c);
      final restored = f.controller(
        connection: const DefaultConnection(
          server: 'https://new-build.example',
          registrationCode: 'different-build-code',
        ),
      );
      await restored.initialize();
      await until(() => restored.online && f.clients.last.calls.length == 2);
      expect(restored.server, defaults.server);
      expect(restored.registrationCode, defaults.registrationCode);
      expect(restored.identity.id, identity);
      expect(restored.displayName, alias);
      expect(f.store.secrets, saved);
    },
  );

  test(
    'Existing custom connection and history take priority without replacing keys',
    () async {
      final f = await Fixture.create();
      f.offline = true;
      final identity = await f.savedIdentity();
      f.store.secrets['server'] = 'https://custom.example';
      f.store.secrets['registration-code'] = '';
      final group = Group(
        id: 'retained-group',
        server: 'https://custom.example',
        name: 'retained',
        ownerId: identity.id,
      );
      final key = CryptoService().randomBytes(32);
      await f.store.saveGroup(group);
      await f.store.saveKey(group, key);
      final envelope = await CryptoService().encrypt(
        identity: identity,
        groupId: group.id,
        messageId: 'retained-message',
        text: 'retained history',
        groupKey: key,
      );
      await f.store.queue(group, envelope);
      final saved = Map<String, String>.from(f.store.secrets);
      final c = f.controller();
      await c.initialize();
      await until(() => c.error != null);
      expect(c.ready, isTrue);
      expect(c.server, group.server);
      expect(c.registrationCode, isEmpty);
      expect(c.identity.id, identity.id);
      expect(c.groups.single.id, group.id);
      expect(await f.store.groupKey(group), key);
      expect((await f.store.outbox(group)).single.toJson(), envelope.toJson());
      expect(f.store.secrets, afterAliasMigration(saved, f.store.secrets));
      expect(
        f.clients.single.calls.single.headers.containsKey(
          'X-Registration-Code',
        ),
        isFalse,
      );
    },
  );

  test(
    'Existing identity without any connection is retained during first automatic setup',
    () async {
      final f = await Fixture.create();
      final identity = await f.savedIdentity();
      final c = f.controller();
      await c.initialize();
      await until(() => c.online);
      expect(c.identity.id, identity.id);
      expect(c.displayName, '临时·ABC234');
      expect(c.usingDefaultConnection, isTrue);
    },
  );

  test(
    'Offline automatic startup remains locally ready and retries the same identity',
    () async {
      final f = await Fixture.create()
        ..offline = true;
      final c = f.controller();
      await c.initialize();
      await until(() => c.error != null);
      final identity = c.identity.id;
      final saved = Map<String, String>.from(f.store.secrets);
      expect(c.ready && c.configured, isTrue);
      expect(c.online, isFalse);
      f.offline = false;
      await c.reconnect();
      expect(c.online, isTrue);
      expect(c.identity.id, identity);
      expect(f.store.secrets, saved);
    },
  );

  test(
    'Origin boundary blocks bundled code before settings or transport changes',
    () async {
      final f = await Fixture.create(), c = f.controller();
      await c.initialize();
      await until(() => c.online && f.clients.single.calls.length == 2);
      final saved = Map<String, String>.from(f.store.secrets);
      for (final server in [
        'https://other.example',
        'https://bundled.example.evil.test',
        'https://bundled.example:444',
      ]) {
        await expectLater(
          c.configure(server, c.displayName, defaults.registrationCode),
          throwsFormatException,
        );
      }
      expect(f.store.secrets, saved);
      expect(f.clients.length, 1);
      expect(c.server, defaults.server);
      expect(c.isDefaultServer('https://BUNDLED.example:443/'), isTrue);
    },
  );

  test(
    'Switching to custom empty code sends no built-in code; returning to default can refill',
    () async {
      final f = await Fixture.create(), c = f.controller();
      await c.initialize();
      await until(() => c.online && f.clients.single.calls.length == 2);
      await c.configure('https://custom.example', c.displayName, '');
      expect(c.registrationCode, isEmpty);
      expect(
        f.clients.last.calls.first.headers.containsKey('X-Registration-Code'),
        isFalse,
      );
      f.disposeController(c);
      final reopened = f.controller();
      await reopened.initialize();
      await until(() => reopened.online && f.clients.last.calls.length == 2);
      expect(reopened.server, 'https://custom.example');
      expect(reopened.registrationCode, isEmpty);
      await reopened.configure(defaults.server, reopened.displayName, '');
      expect(reopened.usingDefaultConnection, isTrue);
      expect(
        f.clients.last.calls.first.headers['X-Registration-Code'],
        defaults.registrationCode,
      );
    },
  );

  test(
    'Corrupt atomic settings never fall back to legacy or build defaults',
    () async {
      for (final saved in [
        'not json',
        '{}',
        '{"v":2,"server":"https://old.example","code":"old"}',
        '{"v":1,"server":"https://old.example"}',
        '{"v":1,"server":"http://old.example","code":"old"}',
      ]) {
        final f = await Fixture.create();
        await f.savedIdentity();
        f.store.secrets[ChatController.connectionSettingsKey] = saved;
        f.store.secrets['server'] = 'https://legacy.example';
        final original = Map<String, String>.from(f.store.secrets);
        final c = f.controller();
        await c.initialize();
        expect(c.ready, isTrue);
        expect(c.error, contains('连接配置损坏'));
        expect(c.api, isNull);
        expect(f.clients, isEmpty);
        expect(f.store.secrets, afterAliasMigration(original, f.store.secrets));
      }
    },
  );

  test(
    'History or orphaned connection code cannot be treated as a fresh install',
    () async {
      for (final hasHistory in [true, false]) {
        final f = await Fixture.create();
        final identity = await f.savedIdentity();
        if (hasHistory) {
          await f.store.saveGroup(
            Group(
              id: 'old-group',
              server: 'https://old.example',
              name: 'old',
              ownerId: identity.id,
            ),
          );
        } else {
          f.store.secrets['registration-code'] = 'old-private-code';
        }
        final saved = Map<String, String>.from(f.store.secrets);
        final c = f.controller();
        await c.initialize();
        expect(c.ready, isTrue);
        expect(c.error, contains('设置中'));
        expect(c.api, isNull);
        expect(f.store.secrets, afterAliasMigration(saved, f.store.secrets));
      }
    },
  );

  test(
    'Missing seed with existing connection refuses to create a replacement identity',
    () async {
      for (final old in [true, false]) {
        final f = await Fixture.create();
        if (old) {
          f.store.secrets['server'] = 'https://old.example';
        } else {
          f.store.secrets[ChatController.connectionSettingsKey] = jsonEncode({
            'v': 1,
            'server': 'https://old.example',
            'code': '',
          });
        }
        final saved = Map<String, String>.from(f.store.secrets);
        final c = f.controller();
        await c.initialize();
        expect(c.ready, isFalse);
        expect(c.error, contains('设备密钥'));
        expect(f.store.secrets, saved);
        expect(f.clients, isEmpty);
      }
    },
  );

  test(
    'Saved mismatched bundled code fails before any request and keeps local data',
    () async {
      final f = await Fixture.create();
      await f.savedIdentity();
      f.store.secrets['server'] = 'https://custom.example';
      f.store.secrets['registration-code'] = defaults.registrationCode;
      final saved = Map<String, String>.from(f.store.secrets);
      final c = f.controller();
      await c.initialize();
      expect(c.ready, isTrue);
      expect(c.error, contains('内置接入码'));
      expect(f.clients, isEmpty);
      expect(f.store.secrets, afterAliasMigration(saved, f.store.secrets));
    },
  );

  test(
    'Failed atomic save makes no network request and retry retains the generated identity',
    () async {
      final f = await Fixture.create();
      f.store.failConnectionSave = true;
      final c = f.controller();
      await c.initialize();
      final identity = c.identity.id;
      expect(c.ready, isTrue);
      expect(c.error, isNotNull);
      expect(c.api, isNull);
      expect(
        f.store.secrets.containsKey(ChatController.connectionSettingsKey),
        isFalse,
      );
      f.disposeController(c);
      f.store.failConnectionSave = false;
      final next = f.controller();
      await next.initialize();
      await until(() => next.online);
      expect(next.identity.id, identity);
    },
  );

  test(
    'Incomplete or non-HTTPS build defaults cannot cause automatic connection',
    () async {
      for (final connection in [
        const DefaultConnection(server: 'https://bundled.example'),
        const DefaultConnection(registrationCode: 'test-only-code'),
        const DefaultConnection(
          server: 'http://bundled.example',
          registrationCode: 'test-only-code',
        ),
      ]) {
        final f = await Fixture.create(),
            c = f.controller(connection: connection);
        await c.initialize();
        expect(c.api, isNull);
        expect(c.configured, isFalse);
        expect(
          f.store.secrets.containsKey(ChatController.connectionSettingsKey),
          isFalse,
        );
      }
    },
  );
}
