import 'dart:convert';
import 'package:nearlink/core/client_security.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';

/// Deliberately public, test-only issuer. Never uses production signing keys.
class SecurityFixtures {
  SecurityFixtures._(this.crypto, this.authority, this.people, this.encryption);
  final CryptoService crypto;
  final Identity authority;
  final Map<String, Identity> people;
  final Map<String, EncryptionIdentity> encryption;
  Identity person(String name) => people[name]!;
  String id(String name) => person(name).id;
  static Future<SecurityFixtures> create() async {
    final crypto = CryptoService();
    final authority = await crypto.identity(List.filled(32, 91));
    final list = [
      for (var n = 1; n <= 3; n++) await crypto.identity(List.filled(32, n)),
    ]..sort((a, b) => a.id.compareTo(b.id));
    final people = {
      for (var n = 0; n < 3; n++) ['a', 'b', 'z'][n]: list[n],
    };
    final encryption = <String, EncryptionIdentity>{};
    for (var n = 0; n < 3; n++) {
      encryption[list[n].id] = await crypto.encryptionIdentity(
        List.filled(32, n + 11),
      );
    }
    return SecurityFixtures._(crypto, authority, people, encryption);
  }

  Group group({int epoch = 1}) => Group(
    id: 'group',
    server: 'https://example.com',
    name: 'Test',
    ownerId: id('a'),
    keyEpoch: epoch,
    protocolVersion: 2,
    privacyEpoch: 2,
    minClientBuild: 5,
  );
  Future<Map<String, dynamic>> sign(
    String domain,
    Map<String, dynamic> value,
  ) async {
    final payload = b64(utf8.encode(jsonEncode(value)));
    return {
      'payload': payload,
      'signature': await crypto.sign(authority, '$domain\n$payload'),
    };
  }

  Future<Map<String, dynamic>> policyWire({
    int? now,
    int minBuild = 5,
    int revision = 1,
    int lifetime = 900000,
    int protocol = 2,
    int privacy = 2,
  }) {
    final issued = now ?? DateTime.now().millisecondsSinceEpoch;
    return sign('hello-mentor-policy-v1', {
      'v': 1,
      'type': 'policy',
      'minClientBuild': minBuild,
      'protocolVersion': protocol,
      'privacyEpoch': privacy,
      'policyRevision': revision,
      'issuedAt': issued,
      'expiresAt': issued + lifetime,
    });
  }

  Future<Map<String, dynamic>> ticketWire(
    Identity who, {
    String groupId = 'group',
    int epoch = 1,
    int? now,
    int minBuild = 5,
    int build = 5,
    int revision = 1,
    int lifetime = 900000,
  }) {
    final issued = now ?? DateTime.now().millisecondsSinceEpoch;
    return sign('hello-mentor-participation-v1', {
      'v': 1,
      'type': 'participation',
      'groupId': groupId,
      'deviceId': who.id,
      'publicKey': who.publicKey,
      'encryptionPublicKey': encryption[who.id]!.publicKey,
      'clientBuild': build,
      'protocolVersion': 2,
      'privacyEpoch': 2,
      'keyEpoch': epoch,
      'minClientBuild': minBuild,
      'policyRevision': revision,
      'issuedAt': issued,
      'expiresAt': issued + lifetime,
    });
  }

  Future<ParticipationTicket> ticket(
    Identity who, {
    String groupId = 'group',
    int epoch = 1,
    int? now,
    int revision = 1,
    int lifetime = 900000,
  }) async => ParticipationTicket.verify(
    await ticketWire(
      who,
      groupId: groupId,
      epoch: epoch,
      now: now,
      revision: revision,
      lifetime: lifetime,
    ),
    crypto: crypto,
    expectedGroupId: groupId,
    expectedKeyEpoch: epoch,
    expectedDeviceId: who.id,
    now: now,
    authorityPublicKey: authority.publicKey,
  );
}
