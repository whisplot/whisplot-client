import 'dart:convert';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';

// Only non-policy regression fixtures use this controller. Mandatory admission
// tests below exercise the real controller and a verifiable test authority.
class PermittedController extends ChatController {
  PermittedController({
    super.store,
    super.crypto,
    super.defaultConnection,
    super.apiFactory,
    super.media,
    super.networkMonitor,
    super.networkDebounce,
    super.healthInterval,
    super.mediaRetryDelay,
    super.authorityPublicKey,
  });
  @override
  bool get participationAllowed => true;
  @override
  bool canSendToGroup(Group group) => group.keyEpoch >= 1;
}

Future<Identity> testAuthority(CryptoService crypto) =>
    crypto.identity(List.filled(32, 73));

Future<Map<String, dynamic>> policyWire(
  CryptoService crypto, {
  int revision = 1,
  int minBuild = 5,
  int? expiresAt,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final payload = b64(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'type': 'policy',
        'minClientBuild': minBuild,
        'protocolVersion': 2,
        'privacyEpoch': 2,
        'policyRevision': revision,
        'issuedAt': now - 1000,
        'expiresAt': expiresAt ?? now + 14 * 60 * 1000,
      }),
    ),
  );
  return {
    'payload': payload,
    'signature': await crypto.sign(
      await testAuthority(crypto),
      'hello-mentor-policy-v1\n$payload',
    ),
  };
}

Future<Map<String, dynamic>> ticketWire(
  CryptoService crypto,
  Identity identity,
  String groupId,
  String encryptionPublicKey, {
  int keyEpoch = 1,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final payload = b64(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'type': 'participation',
        'groupId': groupId,
        'deviceId': identity.id,
        'publicKey': identity.publicKey,
        'encryptionPublicKey': encryptionPublicKey,
        'clientBuild': 5,
        'protocolVersion': 2,
        'privacyEpoch': 2,
        'keyEpoch': keyEpoch,
        'minClientBuild': 5,
        'policyRevision': 1,
        'issuedAt': now - 1000,
        'expiresAt': now + 14 * 60 * 1000,
      }),
    ),
  );
  return {
    'payload': payload,
    'signature': await crypto.sign(
      await testAuthority(crypto),
      'hello-mentor-participation-v1\n$payload',
    ),
  };
}
