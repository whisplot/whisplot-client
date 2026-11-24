import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/models.dart';
import '../core/client_security.dart';
import '../core/peer_auth.dart';
import 'api_client.dart';

class ConnectionReport {
  const ConnectionReport({
    this.socketOnline = false,
    this.direct = 0,
    this.relay = 0,
    this.connecting = 0,
    this.lastConnectMs,
    this.note = '尚未连接',
  });
  final bool socketOnline;
  final int direct, relay, connecting;
  final int? lastConnectMs;
  final String note;
}

class _Peer {
  _Peer(this.pc, this.id);
  final RTCPeerConnection pc;
  final String id;
  RTCDataChannel? channel;
  PeerAuthenticator? auth;
  Future<void> frames = Future.value();
  bool helloSent = false;
  int queuedFrames = 0;
  Timer? handshakeTimeout;
  final candidates = <RTCIceCandidate>[];
  bool hasRemote = false;
  String route = 'connecting';
  Timer? recovery;
  final started = Stopwatch()..start();
}

class RtcSession {
  static const _dataOnlySdp = <String, dynamic>{
    'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
    'optional': <dynamic>[],
  };
  RtcSession({
    required this.api,
    required this.group,
    required this.onEnvelope,
    required this.onMailbox,
    required this.onReport,
    required this.allowedMembers,
    required this.onMembersChanged,
    Future<RTCPeerConnection> Function(Map<String, dynamic>)? peerFactory,
    this.recoveryDelay = const Duration(seconds: 2),
    this.pingInterval = const Duration(seconds: 20),
    this.onConnectionLost,
    this.ticketProvider,
    this.memberPublicKey,
    this.canParticipate,
    this.onPeerPolicy,
    this.participationAuthorityKey = AppSecurity.authorityPublicKey,
  }) : _peerFactory =
           peerFactory ??
           ((configuration) => createPeerConnection(configuration));
  final Future<RTCPeerConnection> Function(Map<String, dynamic>) _peerFactory;
  final Duration recoveryDelay, pingInterval;
  final void Function()? onConnectionLost;
  final Future<ParticipationTicket> Function()? ticketProvider;
  final String? Function(String)? memberPublicKey;
  final bool Function()? canParticipate;
  final void Function(ClientPolicy)? onPeerPolicy;
  final String participationAuthorityKey;
  final ApiClient api;
  final Group group;
  final Set<String> Function() allowedMembers;
  final Future<void> Function() onMembersChanged;
  Set<String> _latestPeers = {};
  Future<int>? _memberRefresh;
  int _membershipRevision = 0, _verifiedMembershipRevision = 0;
  Future<void> _peerUpdates = Future.value();
  final Map<String, int> _peerBackoff = {};
  final Future<void> Function(Envelope) onEnvelope;
  final Future<void> Function() onMailbox;
  final void Function(ConnectionReport) onReport;
  final _peers = <String, _Peer>{};
  final _creating = <String, Future<_Peer>>{};
  final _signalQueues = <String, Future<void>>{};
  WebSocket? _socket;
  Timer? _retry;
  Timer? _credentialRenewal;
  Timer? _participationExpiry;
  Timer? _participationRenewal;
  ParticipationTicket? _ticket;
  Stopwatch? _ticketElapsed;
  int _ticketBudget = 0;
  List<dynamic> _iceServers = [];
  bool _stopped = false, _starting = false;
  int _backoff = 1, _generation = 0;
  Future<void> _retiringPeers = Future.value();
  Future<void>? _stopping;
  int? _lastConnectMs;
  String _note = '正在连接';

  bool get _credentialsValid =>
      !_stopped &&
      canParticipate?.call() == true &&
      group.hasProtectedKeys &&
      group.privacyEpoch == AppSecurity.privacyEpoch &&
      group.minClientBuild <= AppSecurity.clientBuild &&
      _ticket != null &&
      _ticket!.isFreshAt(DateTime.now().millisecondsSinceEpoch) &&
      (_ticketElapsed?.elapsedMilliseconds ?? _ticketBudget) < _ticketBudget;

  bool get _admitted =>
      _credentialsValid && _verifiedMembershipRevision == _membershipRevision;

  Future<void> start() async {
    if (_stopped || _starting || _socket?.readyState == WebSocket.open) return;
    _starting = true;
    final generation = _generation;
    try {
      await _retiringPeers;
      if (_stopped || generation != _generation) return;
      if (canParticipate?.call() != true ||
          !group.hasProtectedKeys ||
          ticketProvider == null) {
        _note = '此群需要完成安全更新和密钥迁移';
        _report();
        return;
      }
      await _verifyMembership(generation);
      if (_stopped || generation != _generation) return;
      final ticket = await ticketProvider!();
      if (_stopped ||
          generation != _generation ||
          canParticipate?.call() != true) {
        return;
      }
      if (ticket.groupId != group.id ||
          ticket.keyEpoch != group.keyEpoch ||
          ticket.deviceId != api.identity.id ||
          ticket.publicKey != api.identity.publicKey ||
          !ticket.policy.supportsThisClient ||
          !ticket.isFreshAt(DateTime.now().millisecondsSinceEpoch)) {
        throw const FormatException('群参与凭证不可用');
      }
      _ticket = ticket;
      _ticketBudget = ticket.expiresAt - DateTime.now().millisecondsSinceEpoch;
      _ticketElapsed = Stopwatch()..start();
      _participationExpiry?.cancel();
      _participationExpiry = Timer(
        Duration(milliseconds: _ticketBudget.clamp(0, 900000)),
        () {
          _ticket =
              null; // Fence synchronous sends before any asynchronous close.
          _note = '安全通行证已到期，正在重新验证';
          unawaited(_renewCredentials());
        },
      );
      _participationRenewal?.cancel();
      _participationRenewal = Timer(AppSecurity.refreshInterval, () {
        unawaited(_renewCredentials());
      });
      Map<String, dynamic> ice;
      try {
        ice = await api.iceConfiguration();
      } catch (_) {
        if (!_admitted) rethrow;
        ice = {
          'iceServers': [
            {'urls': 'stun:stun.cloudflare.com:3478'},
          ],
          'relayConfigured': false,
        };
      }
      if (!_admitted || generation != _generation) return;
      _iceServers = ice['iceServers'] as List<dynamic>;
      _note = ice['relayConfigured'] == true
          ? '已启用中继后备'
          : '未配置中继；部分网络需要通过离线消息同步收发';
      final socket = await api.socket(group.id);
      if (!_admitted || generation != _generation) {
        await _closeSocket(socket);
        return;
      }
      socket.pingInterval = pingInterval;
      _socket = socket;
      _credentialRenewal?.cancel();
      final expiry = ice['expiresAt'];
      if (expiry is num) {
        final renewAt = DateTime.fromMillisecondsSinceEpoch(
          expiry.toInt(),
        ).subtract(const Duration(minutes: 4));
        final delay = renewAt.difference(DateTime.now());
        _credentialRenewal = Timer(
          delay.isNegative ? const Duration(minutes: 1) : delay,
          () {
            unawaited(_renewCredentials());
          },
        );
      }
      _backoff = 1;
      socket.listen(
        (event) {
          if (identical(_socket, socket) && generation == _generation) {
            _event(event);
          }
        },
        onDone: () => _disconnected(socket),
        onError: (_) => _disconnected(socket),
        cancelOnError: true,
      );
      _report();
      await onMailbox();
    } catch (_) {
      if (_stopped ||
          generation != _generation ||
          canParticipate?.call() != true) {
        return;
      }
      _note = '连接暂时中断，正在自动重试';
      _scheduleRetry();
      _report();
    } finally {
      _starting = false;
    }
  }

  void _event(dynamic raw) {
    // Revocation notices must still be handled while a roster refresh has
    // temporarily paused discussion traffic.
    if (!_credentialsValid || raw is! String || raw.length > 65536) return;
    try {
      final event = jsonDecode(raw) as Map<String, dynamic>;
      switch (event['type']) {
        case 'client_upgrade_required':
          _ticket = null;
          const block = UpgradeRequiredException();
          api.blockParticipation(block);
          api.onUpgradeRequired?.call(block);
          unawaited(stop());
          return;
        case 'keys_changed':
        case 'participation_expired':
        case 'group_left':
        case 'group_client_upgrade_required':
          _ticket = null;
          final socket = _socket;
          if (socket != null) _disconnected(socket);
          return;
        case 'peers':
          _latestPeers = (event['peers'] as List).whereType<String>().toSet();
          unawaited(
            _refreshAndSetPeers().catchError((Object _) {
              _note = '成员状态暂未同步，消息通过离线同步补齐';
              _report();
            }),
          );
        case 'members_changed':
          // Fence sends and queued incoming frames synchronously. An old
          // cached roster is not sufficient after a membership change notice.
          _membershipRevision++;
          final generation = _generation;
          unawaited(
            _refreshAndSetPeers(force: true).catchError((Object _) {
              if (_stopped || generation != _generation) return;
              _ticket = null;
              final socket = _socket;
              if (socket != null) _disconnected(socket);
            }),
          );
        case 'signal':
          final generation = _generation;
          final from = event['from'];
          final signal = event['signal'];
          if (from is String && signal is Map<String, dynamic>) {
            final previous = _signalQueues[from] ?? Future.value();
            final next = previous
                .then((_) async {
                  if (_stopped || generation != _generation) return;
                  if (!allowedMembers().contains(from)) await _refreshMembers();
                  if (!_stopped &&
                      generation == _generation &&
                      allowedMembers().contains(from)) {
                    await _signal(from, signal);
                  }
                })
                .catchError((Object _) {
                  _note = '部分点对点连接失败，离线消息仍可同步';
                  _report();
                });
            _signalQueues[from] = next;
          }
        case 'message_available':
          unawaited(onMailbox().catchError((Object _) {}));
      }
    } catch (_) {
      /* Invalid signalling never reaches the message decoder. */
    }
  }

  Future<int> _refreshMembers() {
    final revision = _membershipRevision;
    return _memberRefresh ??= onMembersChanged()
        .then((_) => revision)
        .whenComplete(() {
          _memberRefresh = null;
        });
  }

  Future<void> _verifyMembership(int generation) async {
    while (!_stopped &&
        generation == _generation &&
        _verifiedMembershipRevision != _membershipRevision) {
      final revision = await _refreshMembers();
      if (_stopped || generation != _generation) return;
      _verifiedMembershipRevision = max(_verifiedMembershipRevision, revision);
      // If another notice arrived during the request, its change may not be
      // present in that response. Fetch again before reopening any channel.
    }
  }

  Future<void> _refreshAndSetPeers({bool force = false}) async {
    final generation = _generation;
    if (force) {
      await _verifyMembership(generation);
    } else if (_latestPeers.any(
      (id) => id != api.identity.id && !allowedMembers().contains(id),
    )) {
      await _refreshMembers();
    }
    if (!_stopped &&
        generation == _generation &&
        _socket?.readyState == WebSocket.open) {
      _peerUpdates = _peerUpdates
          .catchError((Object _) {})
          .then((_) => _setPeers(_latestPeers));
      await _peerUpdates;
    }
  }

  Future<void> _setPeers(Set<String> peers) async {
    final generation = _generation;
    if (!_admitted || _socket?.readyState != WebSocket.open) return;
    peers = peers.intersection(allowedMembers());
    peers.remove(api.identity.id);
    for (final id in _peers.keys.toList()) {
      if (!peers.contains(id)) await _remove(id);
    }
    final all = [...peers, api.identity.id]..sort();
    final index = all.indexOf(api.identity.id);
    final desired = <String>{};
    for (var n = 1; n <= 4 && n < all.length; n++) {
      desired.add(all[(index + n) % all.length]);
      desired.add(all[(index - n + all.length) % all.length]);
    }
    desired.remove(api.identity.id);
    for (final id in desired) {
      if (_stopped || generation != _generation) break;
      if (api.identity.id.compareTo(id) < 0 &&
          !_peers.containsKey(id) &&
          _peers.length < 8) {
        try {
          final peer = await _peer(id);
          final channel = await peer.pc.createDataChannel(
            'hello-mentor-v2',
            RTCDataChannelInit()..ordered = true,
          );
          _attachChannel(peer, channel);
          final offer = await peer.pc.createOffer(_dataOnlySdp);
          await peer.pc.setLocalDescription(offer);
          _sendSignal(id, {
            'kind': 'offer',
            'sdp': offer.sdp,
          }, generation: generation);
        } catch (_) {
          _note = '部分连接未建立，消息通过离线同步补齐';
        }
      }
    }
    _report();
  }

  Future<_Peer> _peer(String id) {
    final existing = _peers[id];
    if (existing != null) return Future.value(existing);
    final generation = _generation, creationKey = '$_generation:$id';
    if (!_admitted) return Future.error(StateError('Session not authorized'));
    return _creating
        .putIfAbsent(creationKey, () async {
          if (_peers.length + _creating.length >= 8) {
            throw StateError('Connection cap');
          }
          final pc = await _peerFactory({
            'iceServers': _iceServers,
            'sdpSemantics': 'unified-plan',
          });
          final peer = _Peer(pc, id);
          if (!_admitted || generation != _generation) {
            await pc.close();
            throw StateError('Session closed');
          }
          _peers[id] = peer;
          pc.onIceCandidate = (candidate) {
            if (!_stopped &&
                generation == _generation &&
                identical(_peers[id], peer) &&
                (candidate.candidate?.isNotEmpty ?? false)) {
              _sendSignal(id, {
                'kind': 'candidate',
                'candidate': candidate.candidate,
                'sdpMid': candidate.sdpMid,
                'sdpMLineIndex': candidate.sdpMLineIndex,
              }, generation: generation);
            }
          };
          pc.onDataChannel = (channel) => _attachChannel(peer, channel);
          pc.onConnectionState = (state) {
            if (!identical(_peers[id], peer) || _stopped) return;
            if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
              peer.recovery?.cancel();
              _peerBackoff.remove(id);
              _lastConnectMs = peer.started.elapsedMilliseconds;
              unawaited(_inspectRoute(peer));
            } else if (state ==
                    RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
                state ==
                    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
              peer.route = 'connecting';
              _note = '点对点连接变化，消息可通过离线同步补齐';
              if (peer.recovery?.isActive != true) {
                final attempt = _peerBackoff[id] ?? 1;
                final delay =
                    state == RTCPeerConnectionState.RTCPeerConnectionStateFailed
                    ? recoveryDelay * attempt
                    : const Duration(seconds: 8);
                _peerBackoff[id] = (attempt * 2).clamp(1, 16);
                peer.recovery = Timer(delay, () {
                  unawaited(_recoverPeer(id, peer));
                });
              }
              _report();
            }
          };
          return peer;
        })
        .whenComplete(() => _creating.remove(creationKey));
  }

  Future<void> _recoverPeer(String id, _Peer peer) async {
    if (_stopped || !identical(_peers[id], peer)) return;
    await _remove(id);
    try {
      await _refreshAndSetPeers();
    } catch (_) {
      _note = '点对点恢复暂未成功，离线消息仍可同步';
      _report();
    }
  }

  void _attachChannel(_Peer peer, RTCDataChannel channel) {
    final publicKey = memberPublicKey?.call(peer.id);
    if (!_admitted ||
        !_peers.containsValue(peer) ||
        peer.channel != null ||
        channel.label != 'hello-mentor-v2' ||
        publicKey == null) {
      unawaited(channel.close());
      return;
    }
    peer.channel = channel;
    try {
      peer.auth = PeerAuthenticator(
        crypto: api.crypto,
        identity: api.identity,
        group: group,
        ownTicket: _ticket!,
        peerId: peer.id,
        peerPublicKey: publicKey,
        onRemotePolicy: onPeerPolicy,
        authorityPublicKey: participationAuthorityKey,
      );
    } catch (_) {
      unawaited(_remove(peer.id));
      return;
    }
    peer.handshakeTimeout = Timer(const Duration(seconds: 12), () {
      if (identical(_peers[peer.id], peer) &&
          peer.auth?.authenticated != true) {
        peer.auth?.invalidate();
        unawaited(_remove(peer.id));
      }
    });
    void enqueue(Future<void> Function() operation) {
      if (peer.queuedFrames >= 64) {
        peer.auth?.invalidate();
        unawaited(_remove(peer.id));
        return;
      }
      peer.queuedFrames++;
      peer.frames = peer.frames
          .then((_) async {
            if (!_admitted ||
                !identical(_peers[peer.id], peer) ||
                peer.auth?.isLive != true) {
              return;
            }
            await operation();
          })
          .catchError((Object _) {
            peer.auth?.invalidate();
            _note = '已拒绝旧版或无法认证的点对点连接';
            unawaited(_remove(peer.id));
            _report();
          })
          .whenComplete(() {
            peer.queuedFrames--;
          });
    }

    Future<void> sendHello() async {
      if (peer.helloSent) return;
      peer.helloSent = true;
      await channel.send(RTCDataChannelMessage(jsonEncode(peer.auth!.hello())));
    }

    channel.onDataChannelState = (state) {
      if (!_admitted || !_peers.containsValue(peer)) return;
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        enqueue(sendHello);
        unawaited(_inspectRoute(peer));
      }
      _report();
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      enqueue(sendHello);
    }
    channel.onMessage = (message) {
      if (!_admitted ||
          !_peers.containsValue(peer) ||
          message.isBinary ||
          message.text.length > 16384) {
        return;
      }
      enqueue(() async {
        await sendHello();
        final frame = jsonDecode(message.text);
        if (frame is! Map<String, dynamic>) {
          throw const FormatException('点对点数据无效');
        }
        if (frame['type'] == 'hello' || frame['type'] == 'proof') {
          final reply = await peer.auth!.receive(frame);
          if (!_admitted || !identical(_peers[peer.id], peer)) return;
          if (reply != null) {
            await channel.send(RTCDataChannelMessage(jsonEncode(reply)));
            if (!_admitted || !identical(_peers[peer.id], peer)) return;
            peer.auth!.markProofSent();
          }
          if (peer.auth!.authenticated) peer.handshakeTimeout?.cancel();
          _report();
          return;
        }
        if (frame['type'] != 'message' ||
            frame.length != 2 ||
            frame['envelope'] is! Map<String, dynamic> ||
            !peer.auth!.authenticated) {
          throw const FormatException('未认证或旧协议消息已拒绝');
        }
        final envelope = Envelope.fromJson(frame['envelope']);
        if (!_admitted ||
            !peer.auth!.authenticated ||
            envelope.version != 2 ||
            envelope.keyEpoch != group.keyEpoch ||
            envelope.groupId != group.id ||
            envelope.senderId != peer.id ||
            !allowedMembers().contains(peer.id)) {
          throw const FormatException('消息身份或密钥代次不匹配');
        }
        await onEnvelope(envelope);
      });
    };
  }

  Future<void> _inspectRoute(_Peer peer) async {
    try {
      final stats = await peer.pc.getStats();
      if (_stopped || !_peers.containsValue(peer)) return;
      String? selected;
      for (final stat in stats) {
        if (stat.type == 'transport') {
          selected = stat.values['selectedCandidatePairId']?.toString();
        }
      }
      for (final pair in stats) {
        if (pair.type != 'candidate-pair') continue;
        if (pair.id != selected &&
            !(pair.values['state'] == 'succeeded' &&
                pair.values['nominated'] == true)) {
          continue;
        }
        final ids = [
          pair.values['localCandidateId'],
          pair.values['remoteCandidateId'],
        ];
        peer.route =
            stats.any(
              (s) => ids.contains(s.id) && s.values['candidateType'] == 'relay',
            )
            ? 'relay'
            : 'direct';
        break;
      }
      _report();
    } catch (_) {
      /* An unknown route is not mislabeled as direct. */
    }
  }

  Future<void> _signal(String from, Map<String, dynamic> signal) async {
    final generation = _generation;
    final peer = await _peer(from);
    if (!_admitted || generation != _generation) return;
    switch (signal['kind']) {
      case 'offer':
        if (api.identity.id.compareTo(from) < 0) {
          return; // deterministic offerer; reject glare
        }
        await peer.pc.setRemoteDescription(
          RTCSessionDescription(signal['sdp'] as String, 'offer'),
        );
        peer.hasRemote = true;
        await _flushCandidates(peer);
        final answer = await peer.pc.createAnswer(_dataOnlySdp);
        await peer.pc.setLocalDescription(answer);
        _sendSignal(from, {
          'kind': 'answer',
          'sdp': answer.sdp,
        }, generation: generation);
      case 'answer':
        await peer.pc.setRemoteDescription(
          RTCSessionDescription(signal['sdp'] as String, 'answer'),
        );
        peer.hasRemote = true;
        await _flushCandidates(peer);
      case 'candidate':
        final candidate = RTCIceCandidate(
          signal['candidate'] as String?,
          signal['sdpMid'] as String?,
          signal['sdpMLineIndex'] as int?,
        );
        if (peer.hasRemote) {
          await peer.pc.addCandidate(candidate);
        } else if (peer.candidates.length < 128) {
          peer.candidates.add(candidate);
        }
    }
  }

  Future<void> _flushCandidates(_Peer peer) async {
    for (final candidate in peer.candidates) {
      await peer.pc.addCandidate(candidate);
    }
    peer.candidates.clear();
  }

  void _sendSignal(
    String to,
    Map<String, dynamic> signal, {
    required int generation,
  }) {
    if (!_admitted || generation != _generation) return;
    if (_socket?.readyState == WebSocket.open) {
      _socket!.add(jsonEncode({'type': 'signal', 'to': to, 'signal': signal}));
    }
  }

  Future<void> broadcast(Envelope envelope) async {
    if (!_admitted ||
        envelope.version != 2 ||
        envelope.keyEpoch != group.keyEpoch ||
        envelope.groupId != group.id ||
        envelope.senderId != api.identity.id) {
      return;
    }
    final encoded = jsonEncode({
      'type': 'message',
      'envelope': envelope.toJson(),
    });
    for (final peer in _peers.values.toList()) {
      if (!_admitted) return;
      if (peer.auth?.authenticated == true &&
          allowedMembers().contains(peer.id) &&
          identical(_peers[peer.id], peer) &&
          peer.channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
        try {
          await peer.channel!.send(RTCDataChannelMessage(encoded));
        } catch (_) {}
      }
    }
  }

  void _disconnected(WebSocket socket) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    _generation++;
    _credentialRenewal?.cancel();
    _participationExpiry?.cancel();
    _participationRenewal?.cancel();
    _ticket = null;
    _latestPeers = {};
    _retiringPeers = _closePeers();
    unawaited(_closeSocket(socket));
    _note = '信令已断开，正在重连';
    _report();
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_stopped || _retry?.isActive == true) return;
    if (onConnectionLost != null) {
      onConnectionLost!();
      return;
    }
    _retry = Timer(
      Duration(milliseconds: _backoff * 1000 + Random().nextInt(700)),
      () {
        unawaited(start());
      },
    );
    _backoff = (_backoff * 2).clamp(1, 30);
  }

  Future<void> _renewCredentials() async {
    if (_stopped) return;
    _credentialRenewal?.cancel();
    _participationExpiry?.cancel();
    _participationRenewal?.cancel();
    _ticket = null;
    _generation++;
    final socket = _socket;
    _socket = null;
    _retiringPeers = _closePeers();
    await _closeSocket(socket);
    await _retiringPeers;
    _note = '正在更新中继凭证';
    await start();
  }

  void _report() {
    if (_stopped) return;
    onReport(
      ConnectionReport(
        socketOnline: _socket?.readyState == WebSocket.open,
        direct: _peers.values
            .where((p) => p.route == 'direct' && p.auth?.authenticated == true)
            .length,
        relay: _peers.values
            .where((p) => p.route == 'relay' && p.auth?.authenticated == true)
            .length,
        connecting: _peers.values
            .where(
              (p) => p.route == 'connecting' || p.auth?.authenticated != true,
            )
            .length,
        lastConnectMs: _lastConnectMs,
        note: _note,
      ),
    );
  }

  static Future<void> _boundedClose(Future<void>? closing) async {
    try {
      await closing?.timeout(const Duration(seconds: 2));
    } catch (_) {
      // A lost native route must not hold up replacing every other connection.
    }
  }

  static Future<void> _closeSocket(WebSocket? socket) =>
      _boundedClose(socket?.close());

  Future<void> _remove(String id) async {
    final peer = _peers.remove(id);
    peer?.recovery?.cancel();
    peer?.handshakeTimeout?.cancel();
    peer?.auth?.invalidate();
    await Future.wait([
      _boundedClose(peer?.channel?.close()),
      _boundedClose(peer?.pc.close()),
    ]);
  }

  Future<void> _closePeers() => Future.wait(_peers.keys.toList().map(_remove));

  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    _stopped = true;
    _generation++;
    _retry?.cancel();
    _credentialRenewal?.cancel();
    _participationExpiry?.cancel();
    _participationRenewal?.cancel();
    _ticket = null;
    final socket = _socket;
    _socket = null;
    _stopping = Future.wait([
      _closeSocket(socket),
      _closePeers(),
      _retiringPeers,
    ]);
    return _stopping!;
  }
}
