import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/core/temporary_id.dart';

void main() {
  final crypto = CryptoService();
  test(
    'reaction content is encrypted and rejects unsupported actions or emoji',
    () async {
      final identity = await crypto.identity(), key = crypto.randomBytes(32);
      final payload = <String, dynamic>{
        'type': 'reaction',
        'targetMessageId': 'target',
        'action': 'set',
        'emoji': '👍',
        'counter': 1,
        'createdAt': 1,
      };
      final envelope = await crypto.encryptPayload(
        identity: identity,
        groupId: 'group',
        messageId: 'reaction',
        groupKey: key,
        payload: payload,
      );
      final clear = await crypto.decrypt(
        envelope,
        key,
        identity.publicKey,
        expectedGroupId: 'group',
      );
      expect(clear, payload);
      expect(clear.containsKey('text'), isFalse);
      expect(envelope.toJson().containsKey('emoji'), isFalse);
      for (final invalid in [
        {...payload, 'emoji': 'not allowed'},
        {...payload, 'counter': 0},
        {...payload, 'counter': 9007199254740992},
        {...payload, 'action': 'remove'},
        {...payload, 'senderName': '临时·ABC234'},
        {...payload, 'targetMessageId': '../outside'},
      ]) {
        await expectLater(
          crypto.encryptPayload(
            identity: identity,
            groupId: 'group',
            messageId: 'invalid',
            groupKey: key,
            payload: invalid,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'typed voice has no legacy text field and enforces descriptor bounds',
    () async {
      final identity = await crypto.identity(), key = crypto.randomBytes(32);
      final voice = VoiceAttachment(
        mediaId: '11111111-1111-4111-8111-111111111111',
        key: b64(crypto.randomBytes(32)),
        nonce: b64(crypto.randomBytes(12)),
        sha256: b64(crypto.randomBytes(32)),
        byteLength: 100,
        durationMs: 1000,
      );
      final payload = <String, dynamic>{
        'type': 'voice',
        'voice': voice.toJson(),
        'senderName': '临时·ABC234',
        'createdAt': 1,
      };
      final envelope = await crypto.encryptPayload(
        identity: identity,
        groupId: 'group',
        messageId: 'voice',
        groupKey: key,
        payload: payload,
      );
      final clear = await crypto.decrypt(
        envelope,
        key,
        identity.publicKey,
        expectedGroupId: 'group',
      );
      expect(clear.containsKey('text'), isFalse);
      expect(VoiceAttachment.fromJson(clear['voice']).toJson(), voice.toJson());
      await expectLater(
        crypto.encryptPayload(
          identity: identity,
          groupId: 'group',
          messageId: 'invalid',
          groupKey: key,
          payload: {...payload, 'text': ''},
        ),
        throwsFormatException,
      );
      for (final changes in [
        {'durationMs': 30001},
        {'durationMs': 0},
        {'byteLength': 1048577},
        {'byteLength': 16},
        {'key': b64(List.filled(31, 1))},
        {'nonce': b64(List.filled(11, 1))},
        {'sha256': b64(List.filled(31, 1))},
        {'mediaId': '11111111-1111-1111-8111-111111111111'},
        {'mediaId': '11111111-1111-4111-7111-111111111111'},
      ]) {
        expect(
          () => VoiceAttachment.fromJson({...voice.toJson(), ...changes}),
          throwsFormatException,
        );
      }
    },
  );
  test('all allowed thresholds enforce the exact maximum uses', () {
    for (final limit in AliasRotationState.limits) {
      var state = AliasRotationState(
        alias: '临时·ABC234',
        limit: limit,
        budget: limit,
      );
      for (var i = 0; i < limit; i++) {
        final consumed = state.consume();
        expect(consumed.senderName, '临时·ABC234');
        state = consumed.next;
      }
      expect(state.alias, isNot('临时·ABC234'));
      expect(state.used, 0);
      expect(state.limit, limit);
    }
  });
}
