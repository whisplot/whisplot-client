import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/group_watch.dart';

class WatchApi extends ApiClient {
  WatchApi(this.url, Identity self)
    : super(
        server: 'https://example.test',
        identity: self,
        crypto: CryptoService(),
      );
  final String url;
  int connections = 0;
  Completer<void>? delay;
  final entered = Completer<void>();
  @override
  Future<WebSocket> watchSocket(String groupId) async {
    connections++;
    final socket = await WebSocket.connect('$url/$groupId');
    if (!entered.isCompleted) entered.complete();
    await delay?.future;
    return socket;
  }
}

Future<void> eventually(bool Function() test) async {
  for (var i = 0; i < 200 && !test(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(test(), isTrue);
}

Map<String, dynamic> state(
  int id, {
  String groupId = 'room',
  int ttl = 900000,
}) => {
  'type': 'watch_state',
  'requestId': id,
  'expiresAt': 1000000 + ttl,
  'group': {'groupId': groupId, 'presenceObservedAt': 1000000},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(HttpServer, WatchApi)> fixture() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = WatchApi(
      'ws://127.0.0.1:${server.port}',
      await CryptoService().identity(),
    );
    addTearDown(() async {
      api.close();
      await server.close(force: true);
    });
    return (server, api);
  }

  test(
    'pulses use one socket; wrong group and stale replies cannot update state',
    () async {
      final (server, api) = await fixture();
      final polls = <int>[];
      late WebSocket remote;
      server.listen((request) async {
        remote = await WebSocketTransformer.upgrade(request);
        remote.add(jsonEncode(state(0)));
        remote.listen((raw) {
          final id = jsonDecode(raw as String)['requestId'] as int;
          polls.add(id);
          remote.add(jsonEncode(state(id - 1)));
          remote.add(jsonEncode(state(id, groupId: 'different')));
          remote.add(jsonEncode(state(id)));
        });
      });
      var now = 0;
      final accepted = <int>[];
      final watch = GroupWatch(
        api: api,
        groupId: 'room',
        allowed: () => true,
        now: () => now,
        onState: (_, sentAt) async {
          accepted.add(sentAt);
        },
        onUnavailable: (_) {},
        interval: const Duration(hours: 1),
      );
      addTearDown(watch.stop);
      await watch.start();
      await eventually(() => accepted.length == 1);
      now = 4000;
      watch.poll();
      await eventually(() => accepted.length == 2);
      expect(accepted, [0, 4000]);
      expect(polls, [1]);
      expect(api.connections, 1);
      expect(watch.healthy, isTrue);
    },
  );

  test(
    'a missed application reply makes the socket unhealthy and retries',
    () async {
      final (server, api) = await fixture();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((_) {}); // TCP can remain alive while app frames stall.
      });
      var unavailable = 0;
      final watch = GroupWatch(
        api: api,
        groupId: 'room',
        allowed: () => true,
        now: () => 0,
        onState: (_, _) async {},
        onUnavailable: (_) {
          unavailable++;
        },
        responseTimeout: const Duration(milliseconds: 40),
        retryBase: const Duration(milliseconds: 20),
      );
      addTearDown(watch.stop);
      await watch.start();
      await eventually(() => api.connections >= 2);
      expect(unavailable, greaterThanOrEqualTo(1));
      expect(watch.healthy, isFalse);
    },
  );

  test('busy-room hints share a three-second minimum pulse interval', () async {
    final (server, api) = await fixture();
    late WebSocket remote;
    var polls = 0, accepted = 0, now = 0;
    server.listen((request) async {
      remote = await WebSocketTransformer.upgrade(request);
      remote.add(jsonEncode(state(0)));
      remote.listen((raw) {
        polls++;
        remote.add(
          jsonEncode(state(jsonDecode(raw as String)['requestId'] as int)),
        );
      });
    });
    final watch = GroupWatch(
      api: api,
      groupId: 'room',
      allowed: () => true,
      now: () => now,
      onState: (_, _) async {
        accepted++;
      },
      onUnavailable: (_) {},
      interval: const Duration(hours: 1),
    );
    addTearDown(watch.stop);
    await watch.start();
    await eventually(() => accepted == 1);
    now = 4000;
    for (var i = 0; i < 100; i++) {
      remote.add('{"type":"watch_changed"}');
    }
    await eventually(() => accepted == 2);
    now = 4200;
    for (var i = 0; i < 100; i++) {
      remote.add('{"type":"watch_changed"}');
    }
    watch.poll();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(polls, 1);
    expect(api.connections, 1);
  });

  test('authorization expiry requires another signed handshake', () async {
    final (server, api) = await fixture();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(jsonEncode(state(0, ttl: 5100)));
      socket.listen((_) {});
    });
    final watch = GroupWatch(
      api: api,
      groupId: 'room',
      allowed: () => true,
      now: () => 0,
      onState: (_, _) async {},
      onUnavailable: (_) {},
    );
    addTearDown(watch.stop);
    await watch.start();
    await eventually(() => api.connections >= 2 && watch.healthy);
    expect(watch.healthy, isTrue);
  });

  test(
    'stopping during handshake closes its late socket and ignores all frames',
    () async {
      final (server, api) = await fixture();
      api.delay = Completer<void>();
      final closed = Completer<void>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(jsonEncode(state(0)));
        socket.listen((_) {}, onDone: closed.complete);
      });
      var accepted = 0;
      final watch = GroupWatch(
        api: api,
        groupId: 'room',
        allowed: () => true,
        now: () => 0,
        onState: (_, _) async {
          accepted++;
        },
        onUnavailable: (_) {},
      );
      final starting = watch.start();
      await api.entered.future;
      await watch.stop();
      api.delay!.complete();
      await starting;
      await closed.future.timeout(const Duration(seconds: 2));
      expect(accepted, 0);
      expect(watch.healthy, isFalse);
    },
  );

  test(
    'invalidated membership stops state delivery before later frames',
    () async {
      final (server, api) = await fixture();
      late WebSocket remote;
      server.listen((request) async {
        remote = await WebSocketTransformer.upgrade(request);
        remote.add(jsonEncode(state(0)));
        remote.listen((_) {});
      });
      var allowed = true, accepted = 0;
      final reasons = <String?>[];
      final watch = GroupWatch(
        api: api,
        groupId: 'room',
        allowed: () => allowed,
        now: () => 0,
        onState: (_, _) async {
          accepted++;
        },
        onUnavailable: (reason) {
          reasons.add(reason);
          allowed = false;
        },
      );
      addTearDown(watch.stop);
      await watch.start();
      await eventually(() => accepted == 1);
      remote.add(jsonEncode({'type': 'watch_removed'}));
      remote.add(jsonEncode(state(1)));
      await eventually(() => reasons.isNotEmpty);
      expect(reasons, ['watch_removed']);
      expect(accepted, 1);
      expect(watch.healthy, isFalse);
    },
  );
}
