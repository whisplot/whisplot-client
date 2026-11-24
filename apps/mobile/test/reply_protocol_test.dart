import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';

import 'fixtures/legacy_0_3_1/crypto_service.dart' as old_crypto;
import 'fixtures/legacy_0_3_1/models.dart' as old;

const _group = '11111111-1111-4111-8111-111111111111';
const _message = '22222222-2222-4222-8222-222222222222';
const _target = '33333333-3333-4333-8333-333333333333';
const _alias = '临时·ABC234';

Map<String, dynamic> _text() => {
  'text': '引用后的新消息',
  'createdAt': 1,
  'senderName': _alias,
};

Map<String, dynamic> _reply() => {'v': 1, 'messageId': _target};

Map<String, dynamic> _voice() => {
  'type': 'voice',
  'createdAt': 1,
  'senderName': _alias,
  'voice': VoiceAttachment(
    mediaId: '44444444-4444-4444-8444-444444444444',
    key: b64(List<int>.filled(32, 1)),
    nonce: b64(List<int>.filled(12, 2)),
    sha256: b64(List<int>.filled(32, 3)),
    byteLength: 100,
    durationMs: 1000,
  ).toJson(),
};

void main() {
  final crypto = CryptoService();
  final legacyCrypto = old_crypto.CryptoService();
  final key = List<int>.generate(32, (index) => index);
  late Identity sender;
  late old.Identity legacySender;

  setUpAll(() async {
    sender = await crypto.identity(List<int>.filled(32, 19));
    legacySender = await legacyCrypto.identity(sender.seed);
    expect(legacySender.id, sender.id);
  });

  Future<Envelope> encrypt(Map<String, dynamic> payload, {int keyEpoch = 1}) =>
      crypto.encryptPayload(
        identity: sender,
        groupId: _group,
        messageId: _message,
        groupKey: key,
        keyEpoch: keyEpoch,
        payload: payload,
      );

  Future<Map<String, dynamic>> decrypt(Envelope envelope) =>
      crypto.decrypt(envelope, key, sender.publicKey, expectedGroupId: _group);

  test('ChatMessage reference is optional and stores only its message ID', () {
    const envelope = Envelope(
      groupId: _group,
      messageId: _message,
      senderId: '',
      nonce: '',
      ciphertext: '',
      signature: '',
    );
    const ordinary = ChatMessage(
      envelope: envelope,
      text: '旧消息',
      createdAt: 1,
      state: 'stored',
    );
    const reply = ChatMessage(
      envelope: envelope,
      text: '新消息',
      createdAt: 2,
      state: 'stored',
      expiredOwnId: true,
      replyToMessageId: _target,
    );
    expect(ordinary.replyToMessageId, isNull);
    expect(reply.replyToMessageId, _target);
    expect(reply.temporarySenderId, '已过期 ID');
  });

  test(
    'text convenience API omits absent references and encrypts present ones',
    () async {
      for (final target in <String?>[null, _target]) {
        final envelope = await crypto.encrypt(
          identity: sender,
          groupId: _group,
          messageId: _message,
          groupKey: key,
          text: '引用后的新消息',
          senderName: _alias,
          createdAt: 1,
          keyEpoch: 3,
          replyToMessageId: target,
        );
        expect(await decrypt(envelope), {
          ..._text(),
          if (target != null) 'replyTo': _reply(),
        });
        expect(envelope.version, 2);
        expect(envelope.keyEpoch, 3);
        expect(envelope.toJson().containsKey('replyTo'), isFalse);
        expect(jsonEncode(envelope.toJson()), isNot(contains(_target)));
      }
    },
  );

  for (final epoch in [0, 3]) {
    for (final type in ['text', 'voice']) {
      test(
        '$type reference stays readable by released 0.3.1 at epoch $epoch',
        () async {
          final payload = {
            ...(type == 'text' ? _text() : _voice()),
            'replyTo': _reply(),
          };
          final envelope = await encrypt(payload, keyEpoch: epoch);
          final wire = jsonDecode(jsonEncode(envelope.toJson()));
          final current = await decrypt(Envelope.fromJson(wire));
          // This is the byte-for-byte released implementation, not a mock of
          // its permissiveness. The existing fixture provenance test hashes it.
          final released = await legacyCrypto.decrypt(
            old.Envelope.fromJson(wire),
            key,
            sender.publicKey,
            expectedGroupId: _group,
          );
          expect(current, payload);
          expect(released, payload);
          expect(wire['v'], epoch == 0 ? 1 : 2);
          if (type == 'voice') {
            expect(
              old.VoiceAttachment.fromJson(released['voice']).toJson(),
              payload['voice'],
            );
            expect(released.containsKey('text'), isFalse);
          } else {
            expect(released['text'], '引用后的新消息');
          }
          expect(released['senderName'], _alias);
          expect(
            (current['replyTo'] as Map).keys,
            unorderedEquals(['v', 'messageId']),
          );
        },
      );
    }
  }

  test('reply UUID validation accepts standard case and UUID versions', () {
    for (final target in [
      _target,
      'ABCD1234-ABCD-4ABC-ABCD-ABCDEF123456',
      '019350b8-7345-7ccc-8e53-cf90dcf2af09',
    ]) {
      expect(
        () => crypto.validatePayload({
          ..._text(),
          'replyTo': {'v': 1, 'messageId': target},
        }),
        returnsNormally,
      );
    }
  });

  test(
    'malformed or identifying reply extensions fail send and receive',
    () async {
      final invalidReplies = <Object?>[
        null,
        _target,
        [],
        1,
        {},
        {'v': 1},
        {'messageId': _target},
        {'v': '1', 'messageId': _target},
        {'v': 1.0, 'messageId': _target},
        {'v': true, 'messageId': _target},
        {'v': 0, 'messageId': _target},
        {'v': 2, 'messageId': _target},
        {'v': 1, 'messageId': null},
        {'v': 1, 'messageId': 1},
        {'v': 1, 'messageId': ''},
        {'v': 1, 'messageId': 'message-1'},
        {'v': 1, 'messageId': _target.replaceAll('-', '')},
        {'v': 1, 'messageId': 'urn:uuid:$_target'},
        {'v': 1, 'messageId': '$_target\n'},
        {'v': 1, 'messageId': '00000000-0000-0000-0000-000000000000'},
        {'v': 1, 'messageId': '33333333-3333-9333-8333-333333333333'},
        {'v': 1, 'messageId': '33333333-3333-4333-7333-333333333333'},
        {'v': 1, 'messageId': 'g3333333-3333-4333-8333-333333333333'},
        {'v': 1, 'messageId': 'x' * 10000},
        {..._reply(), 'deviceId': sender.id},
        {..._reply(), 'senderName': _alias},
        {..._reply(), 'text': '已丢弃的原文'},
        {..._reply(), 'groupId': _group},
        {..._reply(), 'unknown': null},
      ];
      for (final reply in invalidReplies) {
        for (final body in [_text(), _voice()]) {
          final payload = {...body, 'replyTo': reply};
          await expectLater(encrypt(payload), throwsFormatException);
          // The old service can produce authenticated unknown extensions. The
          // current decryptor must reject them even with a valid sender signature.
          final incoming = await legacyCrypto.encryptPayload(
            identity: legacySender,
            groupId: _group,
            messageId: _message,
            groupKey: key,
            keyEpoch: 1,
            payload: payload,
          );
          await expectLater(
            () => decrypt(Envelope.fromJson(incoming.toJson())),
            throwsFormatException,
          );
        }
      }
    },
  );

  test('reaction events cannot carry a reference extension', () async {
    final payload = <String, dynamic>{
      'type': 'reaction',
      'targetMessageId': _target,
      'action': 'set',
      'emoji': '👍',
      'counter': 1,
      'createdAt': 1,
    };
    await encrypt(payload);
    await expectLater(
      encrypt({...payload, 'replyTo': _reply()}),
      throwsFormatException,
    );
    final incoming = await legacyCrypto.encryptPayload(
      identity: legacySender,
      groupId: _group,
      messageId: _message,
      groupKey: key,
      keyEpoch: 1,
      payload: {...payload, 'replyTo': _reply()},
    );
    await expectLater(
      decrypt(Envelope.fromJson(incoming.toJson())),
      throwsFormatException,
    );
  });

  test('a reference cannot replace the body or change legacy text limits', () {
    for (final body in <Object?>[null, '', ' \t\n', 1]) {
      expect(
        () => crypto.validatePayload({
          ..._text(),
          'text': body,
          'replyTo': _reply(),
        }),
        throwsFormatException,
      );
    }
    expect(
      () => crypto.validatePayload({'createdAt': 1, 'replyTo': _reply()}),
      throwsFormatException,
    );
    for (final body in ['x' * 1001, '😀' * 1000, 'x' * 4000]) {
      expect(
        () => crypto.validatePayload({
          ..._text(),
          'text': body,
          'replyTo': _reply(),
        }),
        returnsNormally,
      );
    }
    expect(
      () => crypto.validatePayload({
        ..._text(),
        'text': 'x' * 4001,
        'replyTo': _reply(),
      }),
      throwsFormatException,
    );
  });

  test('reference scope is bound to the authenticated outer group', () async {
    final envelope = await encrypt({..._text(), 'replyTo': _reply()});
    const otherGroup = '55555555-5555-4555-8555-555555555555';
    await expectLater(
      crypto.decrypt(
        envelope,
        key,
        sender.publicKey,
        expectedGroupId: otherGroup,
      ),
      throwsFormatException,
    );
    final moved = Envelope.fromJson({
      ...envelope.toJson(),
      'groupId': otherGroup,
    });
    // Even a valid sender signature for the relabelled envelope cannot move
    // its reference into another group: the AEAD context still binds the group.
    final resigned = moved.withSignature(
      await crypto.sign(sender, moved.signingText),
    );
    await expectLater(
      crypto.decrypt(
        resigned,
        key,
        sender.publicKey,
        expectedGroupId: otherGroup,
      ),
      throwsA(anything),
    );
  });
}
