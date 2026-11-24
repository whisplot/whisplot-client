import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/rtc_session.dart';
import 'rtc_session_test.dart' show SocketApi, eventually;
import 'security_fixtures.dart';

class DelayedSocketApi extends SocketApi {
  DelayedSocketApi(super.url, super.self);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<WebSocket> socket(String groupId) async {
    final socket = await super.socket(groupId);
    entered.complete();
    await release.future;
    return socket;
  }
}

void main() {
  late SecurityFixtures fixture;
  setUp(() async {
    fixture = await SecurityFixtures.create();
  });
  test(
    'native websocket ping detects a half-open route without chat traffic',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Socket? blackhole;
      var receivedFrames = 0;
      server.listen((request) async {
        final key = request.headers.value('sec-websocket-key')!;
        final hash = await Sha1().hash(
          utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'),
        );
        request.response
          ..statusCode = 101
          ..headers.set('Connection', 'Upgrade')
          ..headers.set('Upgrade', 'websocket')
          ..headers.set('Sec-WebSocket-Accept', base64Encode(hash.bytes));
        blackhole = await request.response.detachSocket(writeHeaders: true);
        // Keep TCP open and consume bytes, but deliberately never return a pong.
        blackhole!.listen((_) {
          receivedFrames++;
        }, onError: (_) {});
      });
      final api = SocketApi(
        'ws://127.0.0.1:${server.port}',
        fixture.person('a'),
      );
      var lost = 0, messages = 0;
      final reports = <ConnectionReport>[];
      late RtcSession session;
      session = RtcSession(
        api: api,
        group: fixture.group(),
        canParticipate: () => true,
        ticketProvider: () => fixture.ticket(api.identity),
        onEnvelope: (_) async {
          messages++;
        },
        onMailbox: () async {},
        onReport: reports.add,
        allowedMembers: () => {fixture.id('a')},
        onMembersChanged: () async {},
        pingInterval: const Duration(milliseconds: 40),
        onConnectionLost: () {
          lost++;
          unawaited(session.stop());
        },
      );
      addTearDown(() async {
        await session.stop();
        api.close();
        blackhole?.destroy();
        await server.close(force: true);
      });
      await session.start();
      await eventually(() => lost == 1);
      expect(receivedFrames, greaterThan(0));
      expect(messages, 0);
      expect(reports.first.socketOnline, isTrue);
      expect(reports.last.socketOnline, isFalse);
    },
  );

  test(
    'socket completing after session stop is closed and cannot report online',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final remote = Completer<WebSocket>(), remoteClosed = Completer<void>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        remote.complete(socket);
        socket.listen((_) {}, onDone: remoteClosed.complete);
      });
      final api = DelayedSocketApi(
        'ws://127.0.0.1:${server.port}',
        fixture.person('a'),
      );
      final reports = <ConnectionReport>[];
      final session = RtcSession(
        api: api,
        group: fixture.group(),
        canParticipate: () => true,
        ticketProvider: () => fixture.ticket(api.identity),
        onEnvelope: (_) async {},
        onMailbox: () async {},
        onReport: reports.add,
        allowedMembers: () => {fixture.id('a')},
        onMembersChanged: () async {},
      );
      addTearDown(() async {
        await session.stop();
        api.close();
        await (await remote.future).close();
        await server.close(force: true);
      });
      final connecting = session.start();
      await api.entered.future;
      await session.stop();
      api.release.complete();
      await connecting;
      await remoteClosed.future.timeout(const Duration(seconds: 2));
      expect(reports.where((report) => report.socketOnline), isEmpty);
    },
  );
}
