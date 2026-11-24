import 'dart:convert';
import 'temporary_id.dart';

String b64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
List<int> unb64(String text) => base64Url.decode(base64Url.normalize(text));

class Identity {
  const Identity({
    required this.seed,
    required this.publicKey,
    required this.id,
  });
  final List<int> seed;
  final String publicKey;
  final String id;
}

class EncryptionIdentity {
  const EncryptionIdentity({required this.seed, required this.publicKey});
  final List<int> seed;
  final String publicKey;
}

class WrappedGroupKey {
  const WrappedGroupKey({
    required this.keyEpoch,
    required this.senderId,
    required this.recipientId,
    required this.recipientKey,
    required this.ephemeralKey,
    required this.nonce,
    required this.ciphertext,
    required this.signature,
  });
  final int keyEpoch;
  final String senderId, recipientId, recipientKey, ephemeralKey;
  final String nonce, ciphertext, signature;
  factory WrappedGroupKey.fromJson(Map<String, dynamic> json) {
    const fields = [
      'v',
      'keyEpoch',
      'senderId',
      'recipientId',
      'recipientKey',
      'ephemeralKey',
      'nonce',
      'ciphertext',
      'signature',
    ];
    if (json.length != fields.length ||
        !fields.every(json.containsKey) ||
        json['v'] != 1 ||
        json['keyEpoch'] is! int ||
        json['keyEpoch'] < 1 ||
        json['keyEpoch'] > 9007199254740991) {
      throw const FormatException('群密钥封装格式无效');
    }
    try {
      for (final field in fields.skip(2)) {
        if (json[field] is! String) throw const FormatException();
      }
      for (final field in [
        'senderId',
        'recipientId',
        'recipientKey',
        'ephemeralKey',
      ]) {
        if (unb64(json[field]).length != 32 ||
            b64(unb64(json[field])) != json[field]) {
          throw const FormatException();
        }
      }
      for (final entry in {
        'nonce': 12,
        'ciphertext': 48,
        'signature': 64,
      }.entries) {
        final bytes = unb64(json[entry.key]);
        if (bytes.length != entry.value || b64(bytes) != json[entry.key]) {
          throw const FormatException();
        }
      }
      return WrappedGroupKey(
        keyEpoch: json['keyEpoch'],
        senderId: json['senderId'],
        recipientId: json['recipientId'],
        recipientKey: json['recipientKey'],
        ephemeralKey: json['ephemeralKey'],
        nonce: json['nonce'],
        ciphertext: json['ciphertext'],
        signature: json['signature'],
      );
    } catch (_) {
      throw const FormatException('群密钥封装格式无效');
    }
  }
  String context(String groupId) =>
      'hello-mentor-group-key-v1\n$groupId\n$keyEpoch\n$senderId\n$recipientId\n$recipientKey\n$ephemeralKey';
  String signingText(String groupId) =>
      'hello-mentor-group-key-wrap-v1\n${context(groupId)}\n$nonce\n$ciphertext';
  Map<String, dynamic> toJson() => {
    'v': 1,
    'keyEpoch': keyEpoch,
    'senderId': senderId,
    'recipientId': recipientId,
    'recipientKey': recipientKey,
    'ephemeralKey': ephemeralKey,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'signature': signature,
  };
  WrappedGroupKey withSignature(String value) => WrappedGroupKey(
    keyEpoch: keyEpoch,
    senderId: senderId,
    recipientId: recipientId,
    recipientKey: recipientKey,
    ephemeralKey: ephemeralKey,
    nonce: nonce,
    ciphertext: ciphertext,
    signature: value,
  );
}

class Group {
  const Group({
    required this.id,
    required this.server,
    required this.name,
    required this.ownerId,
    this.createdAt = 0,
    this.lastSeq = 0,
    this.keyEpoch = 0,
    this.protocolVersion = 1,
    this.privacyEpoch = 1,
    this.minClientBuild = 0,
  });
  final String id, server, name, ownerId;
  final int createdAt, lastSeq;
  final int keyEpoch, protocolVersion, privacyEpoch, minClientBuild;
  bool get hasProtectedKeys => keyEpoch > 0 && protocolVersion == 2;
  String get storageId => '$server|$id';
  factory Group.fromJson(Map<String, dynamic> json, String server) => Group(
    id: json['groupId'] as String,
    server: server,
    name: json['name'] as String,
    ownerId: json['ownerId'] as String,
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    lastSeq: (json['lastSeq'] as num?)?.toInt() ?? 0,
    keyEpoch: (json['keyEpoch'] as num?)?.toInt() ?? 0,
    protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
    privacyEpoch: (json['privacyEpoch'] as num?)?.toInt() ?? 1,
    minClientBuild: (json['minClientBuild'] as num?)?.toInt() ?? 0,
  );
  Map<String, Object?> toJson() => {
    'groupId': id,
    'server': server,
    'name': name,
    'ownerId': ownerId,
    'createdAt': createdAt,
    'lastSeq': lastSeq,
    'keyEpoch': keyEpoch,
    'protocolVersion': protocolVersion,
    'privacyEpoch': privacyEpoch,
    'minClientBuild': minClientBuild,
  };

  Group copyWith({
    String? name,
    int? lastSeq,
    int? keyEpoch,
    int? protocolVersion,
    int? privacyEpoch,
    int? minClientBuild,
  }) => Group(
    id: id,
    server: server,
    name: name ?? this.name,
    ownerId: ownerId,
    createdAt: createdAt,
    lastSeq: lastSeq ?? this.lastSeq,
    keyEpoch: keyEpoch ?? this.keyEpoch,
    protocolVersion: protocolVersion ?? this.protocolVersion,
    privacyEpoch: privacyEpoch ?? this.privacyEpoch,
    minClientBuild: minClientBuild ?? this.minClientBuild,
  );
}

class Member {
  const Member(
    this.id,
    this.publicKey,
    this.name, {
    this.encryptionPublicKey,
    this.clientBuild = 0,
    this.protocolVersion = 1,
    this.privacyEpoch = 1,
    this.grantedKeyEpoch = 0,
  });
  final String id, publicKey, name;
  final String? encryptionPublicKey;
  final int clientBuild, protocolVersion, privacyEpoch, grantedKeyEpoch;
  factory Member.fromJson(Map<String, dynamic> json) => Member(
    json['deviceId'] as String,
    json['publicKey'] as String,
    json['displayName'] as String,
    encryptionPublicKey: json['encryptionPublicKey'] as String?,
    clientBuild: (json['clientBuild'] as num?)?.toInt() ?? 0,
    protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
    privacyEpoch: (json['privacyEpoch'] as num?)?.toInt() ?? 1,
    grantedKeyEpoch: (json['grantedKeyEpoch'] as num?)?.toInt() ?? 0,
  );
}

class Envelope {
  const Envelope({
    required this.groupId,
    required this.messageId,
    required this.senderId,
    required this.nonce,
    required this.ciphertext,
    required this.signature,
    this.keyEpoch = 0,
  });
  final String groupId, messageId, senderId, nonce, ciphertext, signature;
  final int keyEpoch;
  int get version => keyEpoch == 0 ? 1 : 2;
  factory Envelope.fromJson(Map<String, dynamic> json) {
    if (json['v'] != 1 && json['v'] != 2) {
      throw const FormatException('不支持的消息版本');
    }
    if ((json['v'] == 1 && json.containsKey('keyEpoch')) ||
        (json['v'] == 2 &&
            (json['keyEpoch'] is! int ||
                json['keyEpoch'] < 1 ||
                json['keyEpoch'] > 9007199254740991))) {
      throw const FormatException('消息密钥代次无效');
    }
    for (final field in [
      'groupId',
      'messageId',
      'senderId',
      'nonce',
      'ciphertext',
      'signature',
    ]) {
      if (json[field] is! String) throw const FormatException('消息格式无效');
    }
    final envelope = Envelope(
      groupId: json['groupId'],
      messageId: json['messageId'],
      senderId: json['senderId'],
      nonce: json['nonce'],
      ciphertext: json['ciphertext'],
      signature: json['signature'],
      keyEpoch: json['v'] == 2 ? json['keyEpoch'] as int : 0,
    );
    if (unb64(envelope.nonce).length != 12 ||
        unb64(envelope.signature).length != 64 ||
        unb64(envelope.ciphertext).length < 16 ||
        envelope.ciphertext.length > 12000) {
      throw const FormatException('消息长度无效');
    }
    return envelope;
  }
  String get aad => keyEpoch == 0
      ? 'nearlink-message-v1\n$groupId\n$messageId\n$senderId'
      : 'nearlink-message-v2\n$groupId\n$keyEpoch\n$messageId\n$senderId';
  String get signingText => keyEpoch == 0
      ? 'nearlink-envelope-v1\n$groupId\n$messageId\n$senderId\n$nonce\n$ciphertext'
      : 'nearlink-envelope-v2\n$groupId\n$keyEpoch\n$messageId\n$senderId\n$nonce\n$ciphertext';
  Map<String, dynamic> toJson() => {
    'v': version,
    if (keyEpoch > 0) 'keyEpoch': keyEpoch,
    'groupId': groupId,
    'messageId': messageId,
    'senderId': senderId,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'signature': signature,
  };
  Envelope withSignature(String value) => Envelope(
    groupId: groupId,
    messageId: messageId,
    senderId: senderId,
    nonce: nonce,
    ciphertext: ciphertext,
    signature: value,
    keyEpoch: keyEpoch,
  );
}

class ChatMessage {
  const ChatMessage({
    required this.envelope,
    required this.text,
    required this.createdAt,
    required this.state,
    this.senderName,
    this.seq,
    this.reactions = const [],
    this.voice,
    this.expiredOwnId = false,
  });
  final List<ReactionSummary> reactions;
  final VoiceAttachment? voice;
  final bool expiredOwnId;
  final Envelope envelope;
  final String text;
  final String? senderName;
  String get temporarySenderId => expiredOwnId
      ? '已过期 ID'
      : senderName ?? TemporaryId.legacy(envelope.senderId);
  final int createdAt;
  final String
  state; // pending, stored, p2p (received over an authenticated data channel)
  final int? seq;
}

class VoiceAttachment {
  const VoiceAttachment({
    required this.mediaId,
    required this.key,
    required this.nonce,
    required this.sha256,
    required this.byteLength,
    required this.durationMs,
  });
  static const format = 'wav_pcm16_16000_mono';
  final String mediaId, key, nonce, sha256;
  final int byteLength, durationMs;
  Map<String, dynamic> toJson() => {
    'v': 1,
    'format': format,
    'mediaId': mediaId,
    'key': key,
    'nonce': nonce,
    'sha256': sha256,
    'byteLength': byteLength,
    'durationMs': durationMs,
  };
  factory VoiceAttachment.fromJson(Map<String, dynamic> json) {
    try {
      if (json['v'] != 1 ||
          json['format'] != format ||
          json['mediaId'] is! String ||
          !RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
          ).hasMatch(json['mediaId']) ||
          unb64(json['key'] as String).length != 32 ||
          unb64(json['nonce'] as String).length != 12 ||
          unb64(json['sha256'] as String).length != 32 ||
          json['byteLength'] is! int ||
          json['byteLength'] < 17 ||
          json['byteLength'] > 1048576 ||
          json['durationMs'] is! int ||
          json['durationMs'] < 1 ||
          json['durationMs'] > 30000) {
        throw const FormatException();
      }
      return VoiceAttachment(
        mediaId: json['mediaId'],
        key: json['key'],
        nonce: json['nonce'],
        sha256: json['sha256'],
        byteLength: json['byteLength'],
        durationMs: json['durationMs'],
      );
    } catch (_) {
      throw const FormatException('语音附件描述无效');
    }
  }
}

abstract final class ReactionEmoji {
  static const values = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
}

class ReactionSummary {
  const ReactionSummary({
    required this.emoji,
    required this.count,
    required this.selectedByMe,
  });
  final String emoji;
  final int count;
  final bool selectedByMe;
}

/// A signed sender may replace only their own reaction. This ordering is stable
/// across mailbox/P2P arrival order, replay and clock skew (no wall clock LWW).
class ReactionEvent {
  const ReactionEvent({
    required this.envelope,
    required this.targetMessageId,
    required this.counter,
    required this.emoji,
  });
  final Envelope envelope;
  final String targetMessageId;
  final int counter;
  final String? emoji;
  factory ReactionEvent.fromPayload(
    Envelope envelope,
    Map<String, dynamic> payload,
  ) => ReactionEvent(
    envelope: envelope,
    targetMessageId: payload['targetMessageId'],
    counter: payload['counter'],
    emoji: payload['action'] == 'set' ? payload['emoji'] : null,
  );
  bool supersedes(ReactionEvent other) =>
      counter > other.counter ||
      (counter == other.counter &&
          (envelope.messageId.compareTo(other.envelope.messageId) > 0 ||
              (envelope.messageId == other.envelope.messageId &&
                  envelope.signature.compareTo(other.envelope.signature) > 0)));
}

Map<String, Map<String, ReactionEvent>> foldReactions(
  Iterable<ReactionEvent> events,
) {
  final result = <String, Map<String, ReactionEvent>>{};
  for (final event in events) {
    final senders = result.putIfAbsent(event.targetMessageId, () => {});
    final previous = senders[event.envelope.senderId];
    if (previous == null || event.supersedes(previous)) {
      senders[event.envelope.senderId] = event;
    }
  }
  return result;
}

List<ReactionSummary> summarizeReactions(
  Map<String, ReactionEvent>? events,
  String selfId,
) {
  if (events == null) return const [];
  return [
    for (final emoji in ReactionEmoji.values)
      if (events.values.any((e) => e.emoji == emoji))
        ReactionSummary(
          emoji: emoji,
          count: events.values.where((e) => e.emoji == emoji).length,
          selectedByMe: events[selfId]?.emoji == emoji,
        ),
  ];
}

class Invite {
  static const defaultServer =
      'https://nearlink-api.nearlink-lovelyjhwsb.workers.dev';
  const Invite({
    required this.server,
    required this.groupId,
    required this.name,
    required this.inviteId,
    required this.secret,
    required this.groupKey,
    required this.expiresAt,
    this.keyEpoch = 0,
    this.protocolVersion = 1,
    this.privacyEpoch = 1,
    this.minClientBuild = 0,
  });
  final String server, groupId, name, inviteId, secret, groupKey;
  final int expiresAt;
  final int keyEpoch, protocolVersion, privacyEpoch, minClientBuild;
  String encode() =>
      'nearlink://join#${b64(utf8.encode(jsonEncode({
        'v': keyEpoch > 0 ? 2 : 1,
        'server': server,
        'groupId': groupId,
        'name': name,
        'inviteId': inviteId,
        'secret': secret,
        'groupKey': groupKey,
        'expiresAt': expiresAt,
        if (keyEpoch > 0) ...{'keyEpoch': keyEpoch, 'protocolVersion': protocolVersion, 'privacyEpoch': privacyEpoch, 'minClientBuild': minClientBuild},
      })))}';

  /// Compact, self-contained sharing format. Secrets retain their full length;
  /// only JSON field names, the official origin and the display name are omitted.
  /// The real group name is supplied by the authenticated join response.
  String encodeCompact() {
    // Legacy/custom services may use case-sensitive UUID text as their storage
    // key. Binary UUIDs normalize casing, so retain the original payload then.
    if (keyEpoch < 1 ||
        groupId != groupId.toLowerCase() ||
        inviteId != inviteId.toLowerCase()) {
      return encode().split('#').last;
    }
    final customServer = server != defaultServer;
    final bytes = <int>[3, customServer ? 1 : 0];
    for (final number in [
      protocolVersion,
      privacyEpoch,
      minClientBuild,
      keyEpoch,
      expiresAt,
    ]) {
      _inviteWriteInt(bytes, number);
    }
    for (final id in [groupId, inviteId]) {
      if (!_inviteUuid.hasMatch(id)) {
        throw const FormatException('邀请码标识无效');
      }
      final hex = id.replaceAll('-', '');
      bytes.addAll([
        for (var i = 0; i < 32; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    }
    for (final key in [secret, groupKey]) {
      final decoded = unb64(key);
      if (decoded.length != 32) throw const FormatException('邀请码密钥无效');
      bytes.addAll(decoded);
    }
    if (customServer) {
      final origin = utf8.encode(server);
      if (origin.length > 2048) throw const FormatException('服务地址过长');
      _inviteWriteInt(bytes, origin.length);
      bytes.addAll(origin);
    }
    final checksum = _inviteChecksum(bytes);
    bytes.addAll([
      for (final shift in [24, 16, 8, 0]) (checksum >> shift) & 255,
    ]);
    return b64(bytes);
  }

  static Invite parse(
    String value, {
    required String Function(String) validateServer,
    int? now,
  }) {
    if (value.length > 8192) throw const FormatException('邀请码过长');
    var payload = value.trim();
    if (payload.contains('://')) {
      final uri = Uri.parse(payload);
      if (uri.scheme != 'nearlink' ||
          uri.host != 'join' ||
          uri.fragment.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.path.isNotEmpty) {
        throw const FormatException('请粘贴有效的邀请码');
      }
      payload = Uri.decodeComponent(uri.fragment);
    }
    // Messaging apps may wrap a long clipboard token across multiple lines.
    payload = payload.replaceAll(RegExp(r'\s'), '');
    if (payload.isEmpty) throw const FormatException('请粘贴邀请码');
    final decoded = unb64(payload);
    final json = decoded.isNotEmpty && decoded.first == 3
        ? _inviteDecodeCompact(decoded)
        : jsonDecode(utf8.decode(decoded));
    if (json is! Map<String, dynamic> || (json['v'] != 1 && json['v'] != 2)) {
      throw const FormatException('邀请码版本无效');
    }
    if (json['v'] == 2 &&
        (json['keyEpoch'] is! int ||
            json['keyEpoch'] < 1 ||
            json['keyEpoch'] > 9007199254740991 ||
            json['protocolVersion'] != 2 ||
            json['privacyEpoch'] is! int ||
            json['privacyEpoch'] < 2 ||
            json['minClientBuild'] is! int ||
            json['minClientBuild'] < 1)) {
      throw const FormatException('邀请码安全版本无效');
    }
    if (json['v'] == 1 &&
        [
          'keyEpoch',
          'protocolVersion',
          'privacyEpoch',
          'minClientBuild',
        ].any(json.containsKey)) {
      throw const FormatException('邀请码安全版本无效');
    }
    for (final key in [
      'server',
      'groupId',
      'name',
      'inviteId',
      'secret',
      'groupKey',
    ]) {
      if (json[key] is! String || (json[key] as String).isEmpty) {
        throw const FormatException('邀请码不完整');
      }
    }
    if (json['expiresAt'] is! int ||
        unb64(json['secret']).length != 32 ||
        unb64(json['groupKey']).length != 32) {
      throw const FormatException('邀请码密钥无效');
    }
    if (json['expiresAt'] <= (now ?? DateTime.now().millisecondsSinceEpoch)) {
      throw const FormatException('邀请码已过期');
    }
    if (!_inviteUuid.hasMatch(json['groupId']) ||
        !_inviteUuid.hasMatch(json['inviteId'])) {
      throw const FormatException('邀请码标识无效');
    }
    return Invite(
      server: validateServer(json['server']),
      groupId: json['groupId'],
      name: json['name'],
      inviteId: json['inviteId'],
      secret: json['secret'],
      groupKey: json['groupKey'],
      expiresAt: json['expiresAt'],
      keyEpoch: json['v'] == 2 ? json['keyEpoch'] : 0,
      protocolVersion: json['v'] == 2 ? json['protocolVersion'] : 1,
      privacyEpoch: json['v'] == 2 ? json['privacyEpoch'] : 1,
      minClientBuild: json['v'] == 2 ? json['minClientBuild'] : 0,
    );
  }
}

final _inviteUuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

void _inviteWriteInt(List<int> bytes, int value) {
  if (value < 0 || value > 9007199254740991) {
    throw const FormatException('邀请码数值无效');
  }
  do {
    final next = value & 127;
    value >>= 7;
    bytes.add(next | (value == 0 ? 0 : 128));
  } while (value != 0);
}

// CRC catches copy/typing mistakes before a join can stage the wrong key. It is
// not authentication; existing invitation secrets and AEAD remain authoritative.
int _inviteChecksum(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

Map<String, dynamic> _inviteDecodeCompact(List<int> bytes) {
  if (bytes.length < 107) throw const FormatException('邀请码不完整');
  final body = bytes.sublist(0, bytes.length - 4);
  var expected = 0;
  for (final byte in bytes.sublist(bytes.length - 4)) {
    expected = (expected << 8) | byte;
  }
  if (_inviteChecksum(body) != expected) {
    throw const FormatException('邀请码校验失败，请重新复制');
  }
  var offset = 2;
  if (body[1] > 1) throw const FormatException('邀请码版本无效');
  List<int> take(int length) {
    if (length < 0 || offset + length > body.length) {
      throw const FormatException('邀请码不完整');
    }
    final value = body.sublist(offset, offset + length);
    offset += length;
    return value;
  }

  int number() {
    var value = 0;
    for (var index = 0; index < 8; index++) {
      final byte = take(1).single;
      value |= (byte & 127) << (index * 7);
      if ((byte & 128) == 0) {
        if ((index > 0 && byte == 0) || value > 9007199254740991) {
          throw const FormatException('邀请码数值无效');
        }
        return value;
      }
    }
    throw const FormatException('邀请码数值无效');
  }

  String uuid() {
    final hex = take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  final json = <String, dynamic>{
    'v': 2,
    'protocolVersion': number(),
    'privacyEpoch': number(),
    'minClientBuild': number(),
    'keyEpoch': number(),
    'expiresAt': number(),
    'groupId': uuid(),
    'inviteId': uuid(),
    'secret': b64(take(32)),
    'groupKey': b64(take(32)),
    'name': '邀请的群聊',
  };
  if (body[1] == 1) {
    final length = number();
    if (length == 0 || length > 2048) {
      throw const FormatException('服务地址无效');
    }
    json['server'] = utf8.decode(take(length));
  } else {
    json['server'] = Invite.defaultServer;
  }
  if (offset != body.length) throw const FormatException('邀请码包含多余内容');
  return json;
}
