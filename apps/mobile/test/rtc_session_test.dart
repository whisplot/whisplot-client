import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/core/peer_auth.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/rtc_session.dart';
import 'security_fixtures.dart';

class TestChannel extends RTCDataChannel {
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  String get label => 'hello-mentor-v2';
  @override
  RTCDataChannelState get state => RTCDataChannelState.RTCDataChannelOpen;
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    sent.add(jsonDecode(message.text) as Map<String, dynamic>);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestPeer extends RTCPeerConnection {
  final log = <String>[];
  bool closed = false;
  TestChannel? channel;
  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit dataChannelDict,
  ) async => channel = TestChannel();
  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async {
    expect(constraints?['mandatory'], {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    });
    return RTCSessionDescription('test-offer', 'offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async {
    expect(constraints?['mandatory'], {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    });
    return RTCSessionDescription('test-answer', 'answer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    log.add('local');
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    log.add('remote');
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    log.add('candidate');
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SocketApi extends ApiClient {
  SocketApi(this.url, Identity self)
    : super(
        server: 'https://example.com',
        identity: self,
        crypto: CryptoService(),
      );
  final String url;
  @override
  Future<Map<String, dynamic>> iceConfiguration() async => {
    'iceServers': [],
    'relayConfigured': false,
  };
  @override
  Future<WebSocket> socket(String groupId) => WebSocket.connect(url);
}

Future<void> eventually(bool Function() condition) async {
  for (var n = 0; n < 200; n++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the signalling operation');
}

void main() {
  late HttpServer server;
  late Completer<WebSocket> connected;
  late WebSocket remote;
  late RtcSession session;
  late SecurityFixtures fixture;
  final peers = <TestPeer>[];
  final signals = <Map<String, dynamic>>[];
  final received = <Envelope>[];
  var admitted = true;
  setUp(() async {
    fixture = await SecurityFixtures.create();
    peers.clear();
    signals.clear();
    received.clear();
    admitted = true;
    connected = Completer<WebSocket>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen(
        (data) =>
            signals.add(jsonDecode(data as String) as Map<String, dynamic>),
      );
      connected.complete(ws);
    });
  });
  tearDown(() async {
    await session.stop();
    await remote.close();
    await server.close(force: true);
  });
  Future<void> start(
    String self,
    Set<String> allowed,
    Future<void> Function() refresh,
  ) async {
    final api = SocketApi(
      'ws://127.0.0.1:${server.port}',
      fixture.person(self),
    );
    session = RtcSession(
      api: api,
      group: fixture.group(),
      onEnvelope: (value) async {
        received.add(value);
      },
      onMailbox: () async {},
      onReport: (_) {},
      allowedMembers: () => allowed.map(fixture.id).toSet(),
      memberPublicKey: (id) =>
          fixture.people.values.where((p) => p.id == id).firstOrNull?.publicKey,
      canParticipate: () => admitted,
      ticketProvider: () => fixture.ticket(api.identity),
      participationAuthorityKey: fixture.authority.publicKey,
      onMembersChanged: refresh,
      recoveryDelay: const Duration(milliseconds: 10),
      peerFactory: (_) async {
        final peer = TestPeer();
        peers.add(peer);
        return peer;
      },
    );
    await session.start();
    remote = await connected.future;
  }

  Future<TestChannel> openPeer({
    Set<String>? allowed,
    Future<void> Function()? refresh,
  }) async {
    await start('a', allowed ?? {'a', 'b'}, refresh ?? () async {});
    remote.add(
      jsonEncode({
        'type': 'peers',
        'peers': [fixture.id('b')],
      }),
    );
    await eventually(
      () => peers.isNotEmpty && peers.first.channel?.sent.isNotEmpty == true,
    );
    return peers.first.channel!;
  }

  Future<void> authenticatePeer(TestChannel channel) async {
    final remoteAuth = PeerAuthenticator(
      crypto: fixture.crypto,
      identity: fixture.person('b'),
      group: fixture.group(),
      ownTicket: await fixture.ticket(fixture.person('b')),
      peerId: fixture.id('a'),
      peerPublicKey: fixture.person('a').publicKey,
      authorityPublicKey: fixture.authority.publicKey,
    );
    final proofB = await remoteAuth.receive(
      channel.sent.firstWhere((m) => m['type'] == 'hello'),
    );
    channel.onMessage?.call(
      RTCDataChannelMessage(jsonEncode(remoteAuth.hello())),
    );
    await eventually(() => channel.sent.any((m) => m['type'] == 'proof'));
    await remoteAuth.receive(
      channel.sent.firstWhere((m) => m['type'] == 'proof'),
    );
    remoteAuth.markProofSent();
    channel.onMessage?.call(RTCDataChannelMessage(jsonEncode(proofB)));
    final probe = await fixture.crypto.encrypt(
      identity: fixture.person('a'),
      groupId: 'group',
      messageId: 'probe',
      text: 'authenticated probe',
      groupKey: List.filled(32, 31),
      keyEpoch: 1,
    );
    for (var n = 0; n < 200; n++) {
      await session.broadcast(probe);
      if (channel.sent.any((m) => m['type'] == 'message')) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Mutual proof did not authorize the channel');
  }

  test(
    'open data channel sends no discussion before mutual proof, then authenticates',
    () async {
      final channel = await openPeer();
      final message = await fixture.crypto.encrypt(
        identity: fixture.person('a'),
        groupId: 'group',
        messageId: 'not-yet',
        text: 'must stay local',
        groupKey: List.filled(32, 31),
        keyEpoch: 1,
      );
      await session.broadcast(message);
      expect(channel.sent.where((m) => m['type'] == 'message'), isEmpty);
      await authenticatePeer(channel);
      expect(channel.sent.where((m) => m['type'] == 'message'), hasLength(1));
    },
  );
  test(
    'legacy raw envelope is rejected on an open data channel without delivery',
    () async {
      final channel = await openPeer();
      final old = await fixture.crypto.encrypt(
        identity: fixture.person('b'),
        groupId: 'group',
        messageId: 'legacy',
        text: 'old',
        groupKey: List.filled(32, 31),
      );
      channel.onMessage?.call(RTCDataChannelMessage(jsonEncode(old.toJson())));
      await eventually(() => peers.first.closed);
      expect(received, isEmpty);
      expect(channel.sent.where((m) => m['type'] == 'message'), isEmpty);
    },
  );
  test(
    'gate invalidation fences existing P2P send and receive before REST',
    () async {
      final channel = await openPeer();
      await authenticatePeer(channel);
      final before = channel.sent.length;
      admitted = false;
      final outgoing = await fixture.crypto.encrypt(
        identity: fixture.person('a'),
        groupId: 'group',
        messageId: 'blocked-out',
        text: 'blocked',
        groupKey: List.filled(32, 31),
        keyEpoch: 1,
      );
      await session.broadcast(outgoing);
      final incoming = await fixture.crypto.encrypt(
        identity: fixture.person('b'),
        groupId: 'group',
        messageId: 'blocked-in',
        text: 'blocked',
        groupKey: List.filled(32, 31),
        keyEpoch: 1,
      );
      channel.onMessage?.call(
        RTCDataChannelMessage(
          jsonEncode({'type': 'message', 'envelope': incoming.toJson()}),
        ),
      );
      expect(channel.sent.length, before);
      expect(received, isEmpty);
    },
  );
  test(
    'current peer proof does not authorize retired-epoch messages',
    () async {
      final channel = await openPeer();
      await authenticatePeer(channel);
      final retired = await fixture.crypto.encrypt(
        identity: fixture.person('b'),
        groupId: 'group',
        messageId: 'retired',
        text: 'old epoch',
        groupKey: List.filled(32, 31),
      );
      channel.onMessage?.call(
        RTCDataChannelMessage(
          jsonEncode({'type': 'message', 'envelope': retired.toJson()}),
        ),
      );
      await eventually(() => peers.first.closed);
      expect(received, isEmpty);
    },
  );
  test('keys_changed immediately retires an authenticated channel', () async {
    final channel = await openPeer();
    await authenticatePeer(channel);
    remote.add(jsonEncode({'type': 'keys_changed', 'keyEpoch': 2}));
    await eventually(() => peers.first.closed);
    expect(channel.closed, isTrue);
  });

  for (final event in ['group_left', 'group_client_upgrade_required']) {
    test('$event retires existing authenticated P2P channels', () async {
      final channel = await openPeer();
      await authenticatePeer(channel);
      remote.add(jsonEncode({'type': event, 'keyEpoch': 2}));
      await eventually(() => peers.first.closed);
      expect(channel.closed, isTrue);
    });
  }

  Future<Envelope> discussion(String sender, String messageId) =>
      fixture.crypto.encrypt(
        identity: fixture.person(sender),
        groupId: 'group',
        messageId: messageId,
        text: 'membership change probe',
        groupKey: List.filled(32, 31),
        keyEpoch: 1,
      );

  test(
    'membership notice blocks sends and receives until the removed peer is retired',
    () async {
      final allowed = {'a', 'b'};
      final entered = Completer<void>(), refreshed = Completer<void>();
      final channel = await openPeer(
        allowed: allowed,
        refresh: () async {
          entered.complete();
          await refreshed.future;
          allowed.remove('b');
        },
      );
      await authenticatePeer(channel);
      final before = channel.sent.length;
      remote.add(jsonEncode({'type': 'members_changed'}));
      await entered.future;
      await session.broadcast(await discussion('a', 'pending-roster-out'));
      final incoming = await discussion('b', 'pending-roster-in');
      channel.onMessage?.call(
        RTCDataChannelMessage(
          jsonEncode({'type': 'message', 'envelope': incoming.toJson()}),
        ),
      );
      expect(channel.sent.length, before);
      expect(received, isEmpty);
      refreshed.complete();
      await eventually(() => peers.first.closed);
      await session.broadcast(await discussion('a', 'removed-peer-out'));
      expect(channel.sent.length, before);
      expect(channel.closed, isTrue);
    },
  );

  test('roster refresh failure revokes the cached P2P session', () async {
    final channel = await openPeer(
      refresh: () async => throw const SocketException('roster unavailable'),
    );
    await authenticatePeer(channel);
    final before = channel.sent.length;
    remote.add(jsonEncode({'type': 'members_changed'}));
    await eventually(() => peers.first.closed);
    await session.broadcast(await discussion('a', 'failed-refresh-out'));
    expect(channel.sent.length, before);
    expect(channel.closed, isTrue);
  });

  for (final firstEvent in ['members_changed', 'peers']) {
    test(
      'membership notice during $firstEvent refresh needs a later roster response',
      () async {
        final first = Completer<void>(), second = Completer<void>();
        var refreshes = 0;
        final channel = await openPeer(
          refresh: () async {
            refreshes++;
            await (refreshes == 1 ? first.future : second.future);
          },
        );
        await authenticatePeer(channel);
        final before = channel.sent.length;
        remote.add(
          jsonEncode({
            'type': firstEvent,
            if (firstEvent == 'peers')
              'peers': [fixture.id('b'), fixture.id('z')],
          }),
        );
        await eventually(() => refreshes == 1);
        remote.add(jsonEncode({'type': 'members_changed'}));
        // The second notice must reach the socket while the first response is
        // still pending; its change need not exist in that earlier snapshot.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        first.complete();
        await eventually(() => refreshes == 2);
        await session.broadcast(await discussion('a', 'stale-roster-out'));
        expect(channel.sent.length, before);
        second.complete();
        final outgoing = await discussion('a', 'verified-roster-out');
        for (var n = 0; n < 200 && channel.sent.length == before; n++) {
          await session.broadcast(outgoing);
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(channel.sent.length, greaterThan(before));
        expect(peers, hasLength(1));
        expect(channel.closed, isFalse);
      },
    );
  }

  test('key revocation interrupts an outstanding roster refresh', () async {
    final entered = Completer<void>(), refreshed = Completer<void>();
    final channel = await openPeer(
      refresh: () async {
        entered.complete();
        await refreshed.future;
      },
    );
    await authenticatePeer(channel);
    final before = channel.sent.length;
    remote.add(jsonEncode({'type': 'members_changed'}));
    await entered.future;
    remote.add(jsonEncode({'type': 'keys_changed', 'keyEpoch': 2}));
    await eventually(() => peers.first.closed);
    refreshed.complete();
    await session.broadcast(await discussion('a', 'revoked-refresh-out'));
    expect(channel.sent.length, before);
    expect(channel.closed, isTrue);
  });

  test(
    'Newly joined peer refreshes roster and negotiates without reopening the group',
    () async {
      final allowed = {'a'};
      var refreshes = 0;
      await start('a', allowed, () async {
        refreshes++;
        allowed.add('b');
      });
      remote.add(
        jsonEncode({
          'type': 'peers',
          'peers': [fixture.id('b')],
        }),
      );
      await eventually(
        () => signals.any((s) => (s['signal'] as Map)['kind'] == 'offer'),
      );
      expect(refreshes, 1);
      expect(peers.length, 1);
      expect(signals.first['to'], fixture.id('b'));
    },
  );
  test(
    'Failed ICE connection is removed and renegotiated automatically',
    () async {
      await start('a', {'a', 'b'}, () async {});
      remote.add(
        jsonEncode({
          'type': 'peers',
          'peers': [fixture.id('b')],
        }),
      );
      await eventually(() => signals.length == 1);
      peers.first.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
      );
      await eventually(() => signals.length == 2);
      expect(peers.length, 2);
      expect(peers.first.closed, isTrue);
    },
  );
  test(
    'Early ICE candidate is buffered until offer installs remote SDP',
    () async {
      final allowed = {'z'};
      await start('z', allowed, () async {
        allowed.add('a');
      });
      remote.add(
        jsonEncode({
          'type': 'signal',
          'from': fixture.id('a'),
          'signal': {
            'kind': 'candidate',
            'candidate': 'test',
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          },
        }),
      );
      remote.add(
        jsonEncode({
          'type': 'signal',
          'from': fixture.id('a'),
          'signal': {'kind': 'offer', 'sdp': 'test-offer'},
        }),
      );
      await eventually(() => signals.isNotEmpty);
      expect(peers.single.log, ['remote', 'candidate', 'local']);
      expect((signals.single['signal'] as Map)['kind'], 'answer');
    },
  );
}
