import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/default_connection.dart';
import 'package:nearlink/core/group_presence.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/message_notifications.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'mandatory_update_test.dart' show SecurityFixture;
import 'group_watch_test.dart' show eventually;
import 'message_notification_controller_test.dart'
    show NotificationPlatformFixture, remote;
import 'read_receipt_test.dart' show addOther;

class ControllerWatchApi extends ApiClient {
  ControllerWatchApi(SecurityFixture f, this.url)
    : super(
        server: f.group.server,
        identity: f.identity,
        crypto: f.crypto,
        registrationCode: 'test-app-code',
        client: MockClient(f.handle),
      );
  final String url;
  @override
  Future<WebSocket> watchSocket(String groupId) =>
      WebSocket.connect('$url/$groupId');
}

class WatchHarness {
  WatchHarness(this.fixture, this.server);
  final SecurityFixture fixture;
  final HttpServer server;
  final sockets = <String, WebSocket>{};
  final extras = <Group>[];
  final platform = NotificationPlatformFixture();
  int now = 1000, observed = 1000000;
  int grantEpoch = 1;
  bool serveWatches = true;
  Iterable<Group> get groups => [fixture.group, ...extras];
  Map<String, dynamic> summary(Group group) => {
    ...group.toJson(),
    'onlineCount': group.id == fixture.group.id ? 2 : 3,
    'presenceObservedAt': ++observed,
    'presenceTtlMs': 90000,
    'grantedKeyEpoch': grantEpoch,
  };

  void reply(String groupId, int id) {
    final group = groups.firstWhere((group) => group.id == groupId);
    sockets[groupId]?.add(
      jsonEncode({
        'type': 'watch_state',
        'requestId': id,
        'expiresAt': 1900000,
        'group': summary(group),
      }),
    );
  }

  Future<void> start() async {
    final f = fixture;
    f.controller.dispose();
    await Future<void>.delayed(Duration.zero);
    server.listen((request) async {
      if (!serveWatches) {
        request.response.statusCode = 503;
        await request.response.close();
        return;
      }
      final groupId = request.uri.pathSegments.single;
      final socket = await WebSocketTransformer.upgrade(request);
      sockets[groupId] = socket;
      reply(groupId, 0);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String);
        if (frame['type'] == 'watch_poll') {
          reply(groupId, frame['requestId'] as int);
        }
      });
    });
    f.extraHandler = (request) async => request.url.path == '/v1/groups'
        ? http.Response(
            jsonEncode({
              'watchVersion': 1,
              'groups': groups.map(summary).toList(),
            }),
            200,
          )
        : request.url.path == '/health'
        ? http.Response('{"ok":true}', 200)
        : null;
    f.controller = ChatController(
      store: f.store,
      crypto: f.crypto,
      defaultConnection: const DefaultConnection(),
      authorityPublicKey: f.authority.publicKey,
      presence: GroupPresence(elapsedMilliseconds: () => now),
      notifications: MessageNotificationService(platform: platform),
      healthInterval: const Duration(milliseconds: 80),
      apiFactory:
          ({
            required server,
            required identity,
            required crypto,
            required registrationCode,
          }) => ControllerWatchApi(f, 'ws://127.0.0.1:${this.server.port}'),
    );
    await f.controller.initialize();
    await f.controller.reconnect();
    await eventually(() => groups.every((g) => sockets.containsKey(g.id)));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  Future<void> stop() async {
    for (final socket in sockets.values) {
      unawaited(socket.close());
    }
    await server.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'healthy background watches avoid HTTP polling and health probes but receive messages',
    () async {
      final f = await SecurityFixture.create();
      final other = await addOther(f);
      final harness = WatchHarness(
        f,
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      );
      addTearDown(harness.stop);
      await harness.start();
      final before = f.requests.length;
      for (var i = 0; i < 5; i++) {
        await f.controller.pollMessageNotifications();
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        f.requests
            .skip(before)
            .where(
              (r) => r.url.path == '/v1/groups' || r.url.path == '/health',
            ),
        isEmpty,
      );
      f.remoteMessages.add(
        await remote(f, other, '11111111-1111-4111-8111-111111111110', 1),
      );
      f.group = f.group.copyWith(lastSeq: 1);
      harness.now += 4000;
      harness.sockets[f.group.id]!.add('{"type":"watch_changed"}');
      await eventually(() => harness.platform.shown.isNotEmpty);
      expect(await f.store.cursor(f.group), 1);
      expect(harness.platform.shown.length, 1);
      expect(
        f.requests.skip(before).where((r) => r.url.path == '/v1/groups'),
        isEmpty,
      );
      expect(f.controller.onlineCountForGroup(f.group), 2);
    },
  );

  test(
    'single-room watch updates preserve other room presence; missing watches use HTTP fallback',
    () async {
      final f = await SecurityFixture.create();
      final harness = WatchHarness(
        f,
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      );
      final other = Group(
        id: '22222222-2222-4222-8222-222222222222',
        server: f.group.server,
        name: 'other',
        ownerId: f.identity.id,
        keyEpoch: 1,
        protocolVersion: 2,
        privacyEpoch: 2,
        minClientBuild: 5,
      );
      harness.extras.add(other);
      await f.store.saveGroup(other);
      await f.store.saveKey(other, List.filled(32, 41));
      addTearDown(harness.stop);
      await harness.start();
      harness.now += 4000;
      harness.sockets[f.group.id]!.add('{"type":"watch_changed"}');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(f.controller.onlineCountForGroup(f.group), 2);
      expect(f.controller.onlineCountForGroup(other), 3);
      final before = f.requests.length;
      harness.serveWatches = false;
      await harness.sockets[other.id]!.close();
      harness.now += 16000;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await f.controller.pollMessageNotifications();
      expect(
        f.requests.skip(before).where((r) => r.url.path == '/v1/groups').length,
        1,
      );
      expect(f.controller.onlineCountForGroup(other), 3);
    },
  );

  test(
    'storage quota preserves the identical pending envelope through sleep until reset',
    () async {
      final f = await SecurityFixture.create();
      var wall = DateTime.utc(2000), rejects = true;
      f.controller.api!.close();
      f.controller.api = ApiClient(
        server: f.group.server,
        identity: f.identity,
        crypto: f.crypto,
        registrationCode: 'test-app-code',
        elapsedMilliseconds: () => 0,
        wallClock: () => wall,
        client: MockClient(f.handle),
      );
      f.extraHandler = (request) async =>
          rejects &&
              request.method == 'POST' &&
              request.url.path.endsWith('/messages')
          ? http.Response(
              '{"error":{"code":"storage_quota_exceeded","retryAfterSeconds":60}}',
              503,
            )
          : null;
      final envelope = await f.crypto.encryptPayload(
        identity: f.identity,
        groupId: f.group.id,
        messageId: '77777777-7777-4777-8777-777777777777',
        keyEpoch: 1,
        groupKey: List.filled(32, 41),
        payload: {'text': 'pending', 'createdAt': 100},
      );
      await f.store.queue(f.group, envelope);
      await f.controller.flushOutbox(f.group);
      expect(
        (await f.store.outbox(f.group)).single.toJson(),
        envelope.toJson(),
      );
      final before = f.requests.length;
      await f.controller.flushOutbox(f.group);
      expect(f.requests.length, before);
      rejects = false;
      wall = wall.add(const Duration(seconds: 61));
      await f.controller.flushOutbox(f.group);
      expect(await f.store.outbox(f.group), isEmpty);
      final sent = f.requests.lastWhere(
        (request) =>
            request.method == 'POST' && request.url.path.endsWith('/messages'),
      );
      expect(jsonDecode(sent.body), envelope.toJson());
    },
  );

  test('manual reconnect rechecks quota and throttles repeated clicks', () async {
    final f = await SecurityFixture.create();
    var wall = DateTime.utc(2000);
    f.controller.api!.close();
    f.controller.api = ApiClient(
      server: f.group.server,
      identity: f.identity,
      crypto: f.crypto,
      registrationCode: 'test-app-code',
      elapsedMilliseconds: () => 0,
      wallClock: () => wall,
      client: MockClient(f.handle),
    );
    f.extraHandler = (request) async =>
        request.method == 'POST' && request.url.path == '/v1/devices'
        ? http.Response(
            '{"error":{"code":"storage_quota_exceeded","retryAfterSeconds":86400}}',
            503,
          )
        : null;
    int probes() => f.requests
        .where(
          (request) =>
              request.method == 'POST' && request.url.path == '/v1/devices',
        )
        .length;
    final before = probes();
    await f.controller.retryConnection();
    expect(probes(), before + 1);
    expect(f.controller.online, isFalse);
    await f.controller.retryConnection();
    expect(probes(), before + 2);
    await f.controller.retryConnection();
    expect(probes(), before + 2);
    wall = wall.add(const Duration(seconds: 30));
    await f.controller.retryConnection();
    expect(probes(), before + 3);
  });

  test(
    'a new key grant in the same epoch fetches and verifies the wrapped key',
    () async {
      final f = await SecurityFixture.create();
      final harness = WatchHarness(
        f,
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      )..grantEpoch = 0;
      addTearDown(harness.stop);
      await harness.start();
      await f.store.deleteGroupKeys(f.group);
      expect(await f.store.groupKey(f.group), isNull);
      final replacement = List.filled(32, 73);
      f.ownerWrap = (await f.crypto.wrapGroupKey(
        sender: f.identity,
        groupId: f.group.id,
        keyEpoch: f.group.keyEpoch,
        groupKey: replacement,
        recipientId: f.identity.id,
        recipientPublicKey: f.controller.encryptionIdentity!.publicKey,
      )).toJson();
      final before = f.requests.length;
      harness.grantEpoch = 1;
      harness.now += 4000;
      harness.sockets[f.group.id]!.add('{"type":"watch_changed"}');
      await eventually(
        () => f.requests
            .skip(before)
            .any((request) => request.url.path.endsWith('/keys')),
      );
      for (var i = 0; i < 100 && await f.store.groupKey(f.group) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await f.store.groupKey(f.group), replacement);
      expect(
        f.requests.skip(before).where((r) => r.url.path == '/v1/groups'),
        isEmpty,
      );
    },
  );
}
