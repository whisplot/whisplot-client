import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';

void main() {
  final fixture =
      jsonDecode(File('../../fixtures/protocol-v1.json').readAsStringSync())
          as Map<String, dynamic>;
  final crypto = CryptoService();
  test(
    'Node and Dart agree on Ed25519 identity and exact request bytes',
    () async {
      final identity = await crypto.identity(unb64(fixture['identitySeed']));
      expect(identity.publicKey, fixture['publicKey']);
      expect(identity.id, fixture['deviceId']);
      final request = fixture['request'] as Map<String, dynamic>;
      final input =
          '${request['method']}\n${request['path']}\n${request['timestamp']}\n${request['nonce']}\n${await crypto.hash(utf8.encode(request['body']))}';
      expect(input, request['signingInput']);
      expect(await crypto.sign(identity, input), request['signature']);
    },
  );
  test(
    'Decrypt independently generated AES-GCM envelope and Chinese Unicode',
    () async {
      final envelope = Envelope.fromJson(fixture['envelope']);
      expect(envelope.signingText, fixture['envelopeSigningInput']);
      expect(envelope.aad, fixture['aad']);
      final clear = await crypto.decrypt(
        envelope,
        unb64(fixture['groupKey']),
        fixture['publicKey'],
        expectedGroupId: envelope.groupId,
      );
      expect(jsonEncode(clear), fixture['plaintext']);
    },
  );
  test(
    'Tampering with group, sender, nonce or ciphertext is rejected',
    () async {
      final source = Map<String, dynamic>.from(fixture['envelope']);
      for (final field in ['groupId', 'senderId', 'nonce', 'ciphertext']) {
        final modified = Map<String, dynamic>.from(source);
        final value = modified[field] as String;
        modified[field] =
            '${value.startsWith('A') ? 'B' : 'A'}${value.substring(1)}';
        final envelope = Envelope.fromJson(modified);
        await expectLater(
          crypto.decrypt(
            envelope,
            unb64(fixture['groupKey']),
            fixture['publicKey'],
            expectedGroupId: source['groupId'],
          ),
          throwsA(anything),
        );
      }
    },
  );
  test(
    'Wrong group key is rejected even with a valid sender signature',
    () async {
      final envelope = Envelope.fromJson(fixture['envelope']);
      await expectLater(
        crypto.decrypt(
          envelope,
          List.filled(32, 42),
          fixture['publicKey'],
          expectedGroupId: envelope.groupId,
        ),
        throwsA(anything),
      );
    },
  );
  test('Round trip and nonce uniqueness', () async {
    final identity = await crypto.identity();
    final key = crypto.randomBytes(32);
    final a = await crypto.encrypt(
      identity: identity,
      groupId: 'g',
      messageId: '1',
      text: '离线重试',
      groupKey: key,
      createdAt: 123,
    );
    final b = await crypto.encrypt(
      identity: identity,
      groupId: 'g',
      messageId: '2',
      text: '离线重试',
      groupKey: key,
      createdAt: 123,
    );
    expect(a.nonce, isNot(b.nonce));
    expect(
      await crypto.decrypt(a, key, identity.publicKey, expectedGroupId: 'g'),
      {'text': '离线重试', 'createdAt': 123},
    );
  });
  test('Invite round trip validates secrets, expiration and server URL', () {
    final invite = Invite(
      server: 'https://example.com',
      groupId: '11111111-1111-4111-8111-111111111111',
      name: '群',
      inviteId: '22222222-2222-4222-8222-222222222222',
      secret: b64(List.filled(32, 1)),
      groupKey: b64(List.filled(32, 2)),
      expiresAt: 1000,
    );
    final parsed = Invite.parse(
      invite.encode(),
      validateServer: normalizeServer,
      now: 999,
    );
    expect(parsed.groupKey, invite.groupKey);
    expect(parsed.server, invite.server);
    expect(
      () => Invite.parse(
        invite.encode(),
        validateServer: normalizeServer,
        now: 1000,
      ),
      throwsFormatException,
    );
    expect(() => normalizeServer('http://example.com'), throwsFormatException);
    expect(
      () => normalizeServer('https://good.example@evil.example'),
      throwsFormatException,
    );
    expect(
      () => normalizeServer('https://example.com?token=secret'),
      throwsFormatException,
    );
    expect(
      normalizeServer('http://127.0.0.1:8787/', allowLocalHttp: true),
      'http://127.0.0.1:8787',
    );
  });
}
