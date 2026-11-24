import 'client_security.dart';
import 'crypto_service.dart';
import 'models.dart';

/// Application-layer authentication. DTLS alone does not establish that the
/// other endpoint is an eligible member running the current group protocol.
class PeerAuthenticator {
  PeerAuthenticator({
    required this.crypto,
    required this.identity,
    required this.group,
    required this.ownTicket,
    required this.peerId,
    required this.peerPublicKey,
    this.onRemotePolicy,
    int Function()? now,
    this.authorityPublicKey = AppSecurity.authorityPublicKey,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       ownNonce = b64(crypto.randomBytes(32)) {
    if (peerId == identity.id ||
        group.keyEpoch < 1 ||
        ownTicket.deviceId != identity.id ||
        ownTicket.publicKey != identity.publicKey ||
        ownTicket.groupId != group.id ||
        ownTicket.keyEpoch != group.keyEpoch ||
        group.protocolVersion != AppSecurity.protocolVersion ||
        group.privacyEpoch != AppSecurity.privacyEpoch ||
        ownTicket.clientBuild < group.minClientBuild ||
        ownTicket.policy.minClientBuild < group.minClientBuild ||
        !ownTicket.policy.supportsThisClient ||
        !ownTicket.isFreshAt(_now())) {
      throw const FormatException('本机群参与凭证不可用');
    }
    _leaseBudget = ownTicket.expiresAt - _now();
  }
  final CryptoService crypto;
  final Identity identity;
  final Group group;
  final ParticipationTicket ownTicket;
  final String peerId, peerPublicKey, ownNonce, authorityPublicKey;
  final void Function(ClientPolicy)? onRemotePolicy;
  final int Function() _now;
  final Stopwatch _elapsed = Stopwatch()..start();
  late int _leaseBudget;
  ParticipationTicket? _remoteTicket;
  String? _remoteNonce;
  bool _failed = false, _proofSent = false, _remoteProof = false;
  bool _helloReceived = false, _proofReceived = false;
  bool get authenticated => !_failed && _proofSent && _remoteProof && isLive;
  bool get isLive =>
      !_failed &&
      _elapsed.elapsedMilliseconds < _leaseBudget &&
      ownTicket.isFreshAt(_now()) &&
      (_remoteTicket?.isFreshAt(_now()) ?? true);
  ParticipationTicket? get remoteTicket => _remoteTicket;
  Map<String, dynamic> hello() {
    _requireLive();
    return {'type': 'hello', 'ticket': ownTicket.toJson(), 'nonce': ownNonce};
  }

  void invalidate() {
    _failed = true;
    _proofSent = false;
    _remoteProof = false;
  }

  void _requireLive() {
    if (!isLive) {
      invalidate();
      throw const FormatException('群参与凭证已过期');
    }
  }

  void markProofSent() {
    _requireLive();
    if (_remoteTicket == null) {
      invalidate();
      throw const FormatException('握手顺序无效');
    }
    _proofSent = true;
  }

  String get _transcript {
    if (_remoteNonce == null || _remoteTicket == null) {
      throw const FormatException('握手不完整');
    }
    final own = [identity.id, ownNonce, ownTicket.payload];
    final remote = [peerId, _remoteNonce!, _remoteTicket!.payload];
    final sides = identity.id.compareTo(peerId) < 0
        ? [...own, ...remote]
        : [...remote, ...own];
    return 'hello-mentor-peer-proof-v2\n${group.id}\n${group.keyEpoch}\n${sides.join('\n')}';
  }

  /// Returns an outgoing proof for hello, or null for a verified peer proof.
  /// Caller must send the returned proof successfully before markProofSent().
  Future<Map<String, dynamic>?> receive(Map<String, dynamic> frame) async {
    try {
      _requireLive();
      switch (frame['type']) {
        case 'hello':
          if (_helloReceived ||
              frame.length != 3 ||
              frame['ticket'] is! Map<String, dynamic> ||
              frame['nonce'] is! String) {
            throw const FormatException('重复或无效的群握手');
          }
          _helloReceived =
              true; // Reserve before the first cryptographic await.
          final nonce = frame['nonce'] as String;
          if (unb64(nonce).length != 32 ||
              b64(unb64(nonce)) != nonce ||
              nonce == ownNonce) {
            throw const FormatException('握手随机数无效');
          }
          final ticket = await ParticipationTicket.verify(
            frame['ticket'],
            crypto: crypto,
            expectedGroupId: group.id,
            expectedKeyEpoch: group.keyEpoch,
            expectedDeviceId: peerId,
            expectedPublicKey: peerPublicKey,
            now: _now(),
            authorityPublicKey: authorityPublicKey,
          );
          _requireLive();
          onRemotePolicy?.call(ticket.policy);
          _requireLive();
          if (!ticket.policy.supportsThisClient ||
              ticket.policy.policyRevision != ownTicket.policy.policyRevision ||
              ticket.policy.minClientBuild < ownTicket.policy.minClientBuild ||
              ticket.clientBuild < ownTicket.policy.minClientBuild) {
            throw const FormatException('对方安全策略过期或客户端需要更新');
          }
          _remoteTicket = ticket;
          _remoteNonce = nonce;
          // A wall-clock rollback after receipt cannot extend this channel.
          final remaining =
              ticket.expiresAt - _now() + _elapsed.elapsedMilliseconds;
          if (remaining < _leaseBudget) _leaseBudget = remaining;
          final signature = await crypto.sign(identity, _transcript);
          _requireLive();
          return {'type': 'proof', 'signature': signature};
        case 'proof':
          if (_remoteTicket == null ||
              _proofReceived ||
              frame.length != 2 ||
              frame['signature'] is! String ||
              unb64(frame['signature']).length != 64 ||
              b64(unb64(frame['signature'])) != frame['signature']) {
            throw const FormatException('群握手身份验证失败');
          }
          _proofReceived = true;
          if (!await crypto.verify(
            peerPublicKey,
            _transcript,
            frame['signature'],
          )) {
            throw const FormatException('群握手身份验证失败');
          }
          _requireLive();
          _remoteProof = true;
          return null;
        default:
          throw const FormatException('未经认证的旧协议消息已拒绝');
      }
    } catch (_) {
      invalidate();
      rethrow;
    }
  }
}
