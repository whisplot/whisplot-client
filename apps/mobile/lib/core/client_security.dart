import 'dart:convert';

import 'crypto_service.dart';
import 'models.dart';

abstract final class AppSecurity {
  static const version = '0.1.0';
  static const clientBuild = 12;
  static const protocolVersion = 2;
  static const privacyEpoch = 2;
  static const updateUrl = 'https://whisplot-downloads.pages.dev/';
  static const authorityPublicKey =
      'gdBjDzfoh_0bkHNDdVzyzCOqIHqq2gSg55nnyhw7GOQ';
  static const leaseDuration = Duration(minutes: 15);
  static const refreshInterval = Duration(minutes: 5);
}

int _integer(Map<String, dynamic> json, String key, {int minimum = 1}) {
  final value = json[key];
  if (value is! int || value < minimum || value > 9007199254740991) {
    throw const FormatException('安全策略字段无效');
  }
  return value;
}

void _canonicalBytes(String value, int length) {
  final bytes = unb64(value);
  if (bytes.length != length || b64(bytes) != value) {
    throw const FormatException('安全凭证编码无效');
  }
}

void _validateTimes(int issuedAt, int expiresAt, int now, bool allowExpired) {
  if (expiresAt <= issuedAt ||
      expiresAt - issuedAt > AppSecurity.leaseDuration.inMilliseconds ||
      issuedAt > now + const Duration(seconds: 30).inMilliseconds ||
      (!allowExpired && expiresAt <= now)) {
    throw const FormatException('安全凭证已过期或时间无效，请联网校准');
  }
}

class ClientPolicy {
  const ClientPolicy({
    required this.minClientBuild,
    required this.protocolVersion,
    required this.privacyEpoch,
    required this.policyRevision,
    required this.issuedAt,
    required this.expiresAt,
  });
  final int minClientBuild, protocolVersion, privacyEpoch, policyRevision;
  final int issuedAt, expiresAt;
  factory ClientPolicy.fromJson(Map<String, dynamic> json) => ClientPolicy(
    minClientBuild: _integer(json, 'minClientBuild'),
    protocolVersion: _integer(json, 'protocolVersion'),
    privacyEpoch: _integer(json, 'privacyEpoch'),
    policyRevision: _integer(json, 'policyRevision'),
    issuedAt: _integer(json, 'issuedAt'),
    expiresAt: _integer(json, 'expiresAt'),
  );
  bool get supportsThisClient =>
      minClientBuild <= AppSecurity.clientBuild &&
      protocolVersion == AppSecurity.protocolVersion &&
      privacyEpoch == AppSecurity.privacyEpoch;
  bool isFreshAt(int now) =>
      issuedAt <= now + 30000 &&
      expiresAt > now &&
      expiresAt > issuedAt &&
      expiresAt - issuedAt <= AppSecurity.leaseDuration.inMilliseconds;
  Map<String, dynamic> toJson() => {
    'v': 1,
    'type': 'policy',
    'minClientBuild': minClientBuild,
    'protocolVersion': protocolVersion,
    'privacyEpoch': privacyEpoch,
    'policyRevision': policyRevision,
    'issuedAt': issuedAt,
    'expiresAt': expiresAt,
  };
}

Future<(String, String, Map<String, dynamic>)> _verifyWire(
  Map<String, dynamic> wire,
  String domain,
  CryptoService crypto,
  String authorityPublicKey,
) async {
  if (wire.length != 2 ||
      wire['payload'] is! String ||
      wire['signature'] is! String ||
      (wire['payload'] as String).length > 8192) {
    throw const FormatException('安全凭证格式无效');
  }
  final payload = wire['payload'] as String,
      signature = wire['signature'] as String;
  _canonicalBytes(authorityPublicKey, 32);
  _canonicalBytes(signature, 64);
  final bytes = unb64(payload);
  if (b64(bytes) != payload ||
      !await crypto.verify(
        authorityPublicKey,
        '$domain\n$payload',
        signature,
      )) {
    throw const FormatException('安全凭证签名无效');
  }
  final json = jsonDecode(utf8.decode(bytes));
  if (json is! Map<String, dynamic>) throw const FormatException('安全凭证格式无效');
  return (payload, signature, json);
}

class SignedPolicy {
  const SignedPolicy._(this.payload, this.signature, this.policy);
  final String payload, signature;
  final ClientPolicy policy;
  Map<String, dynamic> toJson() => {'payload': payload, 'signature': signature};
  static Future<SignedPolicy> verify(
    Map<String, dynamic> wire, {
    required CryptoService crypto,
    int? now,
    bool allowExpired = false,
    String authorityPublicKey = AppSecurity.authorityPublicKey,
  }) async {
    final (payload, signature, json) = await _verifyWire(
      wire,
      'hello-mentor-policy-v1',
      crypto,
      authorityPublicKey,
    );
    const fields = [
      'v',
      'type',
      'minClientBuild',
      'protocolVersion',
      'privacyEpoch',
      'policyRevision',
      'issuedAt',
      'expiresAt',
    ];
    if (json.length != fields.length ||
        !fields.every(json.containsKey) ||
        json['v'] != 1 ||
        json['type'] != 'policy') {
      throw const FormatException('安全策略格式无效');
    }
    final policy = ClientPolicy.fromJson(json);
    _validateTimes(
      policy.issuedAt,
      policy.expiresAt,
      now ?? DateTime.now().millisecondsSinceEpoch,
      allowExpired,
    );
    return SignedPolicy._(payload, signature, policy);
  }
}

class ParticipationTicket {
  const ParticipationTicket._({
    required this.payload,
    required this.signature,
    required this.groupId,
    required this.deviceId,
    required this.publicKey,
    required this.encryptionPublicKey,
    required this.clientBuild,
    required this.keyEpoch,
    required this.policy,
  });
  final String payload,
      signature,
      groupId,
      deviceId,
      publicKey,
      encryptionPublicKey;
  final int clientBuild, keyEpoch;
  final ClientPolicy policy;
  int get issuedAt => policy.issuedAt;
  int get expiresAt => policy.expiresAt;
  bool isFreshAt(int now) => policy.isFreshAt(now);
  Map<String, dynamic> toJson() => {'payload': payload, 'signature': signature};
  static Future<ParticipationTicket> verify(
    Map<String, dynamic> wire, {
    required CryptoService crypto,
    required String expectedGroupId,
    required int expectedKeyEpoch,
    String? expectedDeviceId,
    String? expectedPublicKey,
    String? expectedEncryptionPublicKey,
    int? now,
    String authorityPublicKey = AppSecurity.authorityPublicKey,
  }) async {
    final (payload, signature, json) = await _verifyWire(
      wire,
      'hello-mentor-participation-v1',
      crypto,
      authorityPublicKey,
    );
    const fields = [
      'v',
      'type',
      'groupId',
      'deviceId',
      'publicKey',
      'encryptionPublicKey',
      'clientBuild',
      'protocolVersion',
      'privacyEpoch',
      'keyEpoch',
      'minClientBuild',
      'policyRevision',
      'issuedAt',
      'expiresAt',
    ];
    if (json.length != fields.length ||
        !fields.every(json.containsKey) ||
        json['v'] != 1 ||
        json['type'] != 'participation' ||
        json['groupId'] != expectedGroupId ||
        expectedKeyEpoch < 1 ||
        json['keyEpoch'] != expectedKeyEpoch) {
      throw const FormatException('群参与凭证或密钥代次不匹配');
    }
    for (final key in ['deviceId', 'publicKey', 'encryptionPublicKey']) {
      if (json[key] is! String) throw const FormatException('参与身份无效');
      _canonicalBytes(json[key], 32);
    }
    if ((expectedDeviceId != null && json['deviceId'] != expectedDeviceId) ||
        (expectedPublicKey != null && json['publicKey'] != expectedPublicKey) ||
        (expectedEncryptionPublicKey != null &&
            json['encryptionPublicKey'] != expectedEncryptionPublicKey) ||
        await crypto.hash(unb64(json['publicKey'])) != json['deviceId']) {
      throw const FormatException('群参与凭证身份不匹配');
    }
    final policy = ClientPolicy.fromJson(json),
        build = _integer(json, 'clientBuild');
    _validateTimes(
      policy.issuedAt,
      policy.expiresAt,
      now ?? DateTime.now().millisecondsSinceEpoch,
      false,
    );
    if (build < policy.minClientBuild) throw const FormatException('参与者版本过低');
    return ParticipationTicket._(
      payload: payload,
      signature: signature,
      groupId: json['groupId'],
      deviceId: json['deviceId'],
      publicKey: json['publicKey'],
      encryptionPublicKey: json['encryptionPublicKey'],
      clientBuild: build,
      keyEpoch: expectedKeyEpoch,
      policy: policy,
    );
  }
}
