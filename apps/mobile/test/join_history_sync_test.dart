import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/security_fixture.dart';
import 'sync_controller_test.dart' show MemorySecretsStore;

class _HistoryApi extends ApiClient {
  _HistoryApi(Identity identity, CryptoService crypto)
    : super(server: 'https://example.com', identity: identity, crypto: crypto);
  List<Map<String, dynamic>> page = [];
  int floor = 0, joinedAt = 0, cursor = 0, acks = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    if (path.contains('/messages?')) {
      return {
        'messages': page,
        'historySince': floor,
        'joinedAt': joinedAt,
        'nextCursor': cursor,
        'hasMore': false,
      };
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
  late Database db;
  late MemorySecretsStore store;
  late CryptoService crypto;
  late Identity identity;
  late Group group;
  late _HistoryApi api;
  late PermittedController controller;
  const floor = 1700000000000;
  final key = List<int>.filled(32, 7);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalStore.createSchema(db);
    store = MemorySecretsStore(db);
    crypto = CryptoService();
    identity = await crypto.identity();
    group = Group(
      id: '11111111-1111-4111-8111-111111111111',
      server: 'https://example.com',
      name: 'Synthetic',
      ownerId: identity.id,
      keyEpoch: 1,
      protocolVersion: 2,
      privacyEpoch: 2,
    );
    await store.saveGroup(group);
    await store.saveKey(group, key);
    await store.saveMembers(group, [
      Member(identity.id, identity.publicKey, 'ID'),
    ]);
    api = _HistoryApi(identity, crypto)
      ..floor = floor
      ..joinedAt = floor + 86400000;
    controller = PermittedController(store: store, crypto: crypto)
      ..server = group.server
      ..identity = identity
      ..api = api
      ..groups = [group]
      ..activeGroup = group;
  });
  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    await db.close();
  });
  Future<Map<String, dynamic>> message(int n, int storedAt) async {
    final digit = '$n';
    final envelope = await crypto.encrypt(
      identity: identity,
      groupId: group.id,
      messageId:
          '${digit * 8}-${digit * 4}-4${digit * 3}-8${digit * 3}-${digit * 12}',
      text: 'message $n',
      groupKey: key,
      keyEpoch: 1,
      createdAt: storedAt,
    );
    return {...envelope.toJson(), 'seq': n, 'storedAt': storedAt};
  }

  test(
    'authenticated admission floor filters old history, includes exact boundary and later offline messages',
    () async {
      api.page = [
        await message(1, floor - 1),
        await message(2, floor),
        await message(3, floor + 86400000 * 10),
      ];
      api.cursor = 3;
      await controller.syncActive();
      expect(controller.messages.map((m) => m.text), [
        'message 2',
        'message 3',
      ]);
      expect(await store.cursor(group), 3);
      expect(api.acks, 1);
      expect(controller.groups.single.historySince, floor);
      expect(controller.activeGroup!.historySince, floor);
      expect(
        (await store.groups(group.server)).single.joinedAt,
        floor + 86400000,
      );
      expect(await store.quarantinedCount(group), 0);
    },
  );

  test(
    'delayed page or metadata cannot lower a persisted floor; an empty filtered page still advances',
    () async {
      final admitted = group.copyWith(
        historySince: floor,
        joinedAt: floor + 86400000,
      );
      await store.saveGroup(admitted);
      controller.groups = [admitted];
      controller.activeGroup = admitted;
      api.floor = 0;
      api.joinedAt = 0;
      api.page = [await message(1, floor - 1)];
      api.cursor = 1;
      await controller.syncActive();
      await store.saveGroup(group);
      expect(await store.messages(group), isEmpty);
      expect(await store.cursor(group), 1);
      expect((await store.groups(group.server)).single.historySince, floor);
    },
  );

  test(
    'storage checks persisted floor even with stale caller and preserves already local records',
    () async {
      final local = await message(1, floor - 20);
      await store.saveP2p(group, Envelope.fromJson(local));
      await store.saveGroup(group.copyWith(historySince: floor));
      await store.ingestPage(group, [
        await message(2, floor - 1),
        await message(3, floor),
      ], 3);
      final records = await store.messages(group);
      expect(
        records.map((m) => jsonDecode(m['envelope'] as String)['messageId']),
        contains(local['messageId']),
      );
      expect(records.where((r) => r['seq'] == 3), hasLength(1));
      expect(records, hasLength(2));
    },
  );
}
