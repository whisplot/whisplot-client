import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';

import 'fixtures/legacy_0_3_1/crypto_service.dart' as old_crypto;
import 'fixtures/legacy_0_3_1/models.dart' as old;

const _group = 'reaction-compat-group';
const _target = 'target-message';
const _rich = '🫠';
const _fixtureDirectory = 'test/fixtures/legacy_0_3_1';
const _sourceCommit = '60048640d8efe8d9e72fc244ca0e93ea206fbf71';

Map<String, dynamic> _payload(int counter, Map<String, dynamic> fields) => {
  'type': 'reaction',
  'targetMessageId': _target,
  'counter': counter,
  'createdAt': 1,
  ...fields,
};

class _Pair {
  const _Pair(this.current, this.legacy);
  final ReactionEvent current;
  final old.ReactionEvent legacy;
}

void main() {
  final crypto = CryptoService();
  final legacyCrypto = old_crypto.CryptoService();
  final key = List<int>.generate(32, (index) => index);
  late Identity alice;
  late Identity bob;
  late old.Identity legacyAlice;

  setUpAll(() async {
    alice = await crypto.identity(List<int>.filled(32, 11));
    bob = await crypto.identity(List<int>.filled(32, 22));
    legacyAlice = await legacyCrypto.identity(alice.seed);
    expect(legacyAlice.id, alice.id);
    expect(legacyAlice.publicKey, alice.publicKey);
  });

  Future<_Pair> decodeBoth(Envelope envelope, String publicKey) async {
    // Serialize through JSON, as network/storage frames do. Do not pass current
    // model objects to the independent released implementation.
    final json = jsonDecode(jsonEncode(envelope.toJson()));
    final currentEnvelope = Envelope.fromJson(json);
    final legacyEnvelope = old.Envelope.fromJson(json);
    final currentPayload = await crypto.decrypt(
      currentEnvelope,
      key,
      publicKey,
      expectedGroupId: _group,
    );
    final legacyPayload = await legacyCrypto.decrypt(
      legacyEnvelope,
      key,
      publicKey,
      expectedGroupId: _group,
    );
    expect(currentPayload, legacyPayload);
    return _Pair(
      ReactionEvent.fromPayload(currentEnvelope, currentPayload),
      old.ReactionEvent.fromPayload(legacyEnvelope, legacyPayload),
    );
  }

  Future<_Pair> sendCurrent(
    String messageId,
    int counter,
    String? emoji, {
    Identity? sender,
  }) async {
    final identity = sender ?? alice;
    final envelope = await crypto.encryptPayload(
      identity: identity,
      groupId: _group,
      messageId: messageId,
      groupKey: key,
      keyEpoch: 1,
      payload: _payload(counter, ReactionEmoji.payloadFields(emoji)),
    );
    return decodeBoth(envelope, identity.publicKey);
  }

  Future<Envelope> legacyEnvelope(
    String messageId,
    Map<String, dynamic> payload,
  ) async {
    final envelope = await legacyCrypto.encryptPayload(
      identity: legacyAlice,
      groupId: _group,
      messageId: messageId,
      groupKey: key,
      keyEpoch: 1,
      payload: payload,
    );
    return Envelope.fromJson(envelope.toJson());
  }

  test(
    'released protocol fixture has unchanged source bytes and provenance',
    () async {
      const expected = {
        'crypto_service.dart': (
          12245,
          '847e1c52bfcdf8a24fec9c37c9406fa7596dd1596f85af1ea857f90e21064425',
        ),
        'models.dart': (
          22583,
          '05c111840584e2683efb3795ec036f15e30019bfcce479445ca63e571017ff45',
        ),
        'temporary_id.dart': (
          3217,
          '9aafffa5ab57aa827395ad75168d71a70f68a77ab69df6991a470e720960b0bc',
        ),
      };
      final manifest =
          jsonDecode(
                await File(
                  '$_fixtureDirectory/source-manifest.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(manifest['sourceCommit'], _sourceCommit);
      expect(manifest['release'], '0.3.1');
      final files = manifest['files'] as Map<String, dynamic>;
      expect(files.keys, unorderedEquals(expected.keys));
      for (final entry in expected.entries) {
        final bytes = await File(
          '$_fixtureDirectory/${entry.key}',
        ).readAsBytes();
        final digest = (await Sha256().hash(
          bytes,
        )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        expect(bytes.length, entry.value.$1, reason: entry.key);
        expect(digest, entry.value.$2, reason: entry.key);
        expect(files[entry.key]['sha256'], digest);
        expect(files[entry.key]['bytes'], bytes.length);
        expect(
          files[entry.key]['sourcePath'],
          'apps/mobile/lib/core/${entry.key}',
        );
      }
    },
  );

  for (final emoji in old.ReactionEmoji.values) {
    test(
      'legacy $emoji uses the unchanged wire representation in both directions',
      () async {
        expect(ReactionEmoji.payloadFields(emoji), {
          'action': 'set',
          'emoji': emoji,
        });
        final currentSent = await sendCurrent('current-legacy', 1, emoji);
        final legacySent = await decodeBoth(
          await legacyEnvelope(
            'legacy-current',
            _payload(2, {'action': 'set', 'emoji': emoji}),
          ),
          alice.publicKey,
        );
        for (final pair in [currentSent, legacySent]) {
          expect(pair.current.emoji, emoji);
          expect(pair.legacy.emoji, emoji);
          expect(pair.current.counter, pair.legacy.counter);
        }
      },
    );
  }

  test(
    'rich selection is decryptable by released client and only rendered by new client',
    () async {
      expect(ReactionEmoji.payloadFields(_rich), {
        'action': 'remove',
        'reactionV2': {'v': 1, 'emoji': _rich},
      });
      final pair = await sendCurrent('rich', 1, _rich);
      expect(pair.current.emoji, _rich);
      expect(pair.legacy.emoji, isNull);
      expect(pair.legacy.counter, 1);
      expect(pair.current.envelope.toJson().containsKey('reactionV2'), isFalse);
      expect(pair.current.envelope.toJson().containsKey('emoji'), isFalse);
    },
  );

  test(
    'rich replacement, replay, cancellation and legacy replacement keep each sender independent',
    () async {
      final initial = await sendCurrent('initial', 1, '👍');
      final rich = await sendCurrent('rich', 2, _rich);
      final other = await sendCurrent('other', 1, '❤️', sender: bob);
      final remove = await sendCurrent('remove', 3, null);
      final legacyReplacement = await decodeBoth(
        await legacyEnvelope(
          'legacy-replacement',
          _payload(4, {'action': 'set', 'emoji': '😂'}),
        ),
        alice.publicKey,
      );
      expect(ReactionEmoji.payloadFields(null), {'action': 'remove'});

      void check(
        List<_Pair> events,
        int counter,
        String? visible,
        String? oldVisible,
      ) {
        final currentFold = foldReactions(
          events.map((event) => event.current),
        )[_target]!;
        final oldFold = old.foldReactions(
          events.map((event) => event.legacy),
        )[_target]!;
        expect(currentFold[alice.id]!.counter, counter);
        expect(oldFold[alice.id]!.counter, counter);
        expect(currentFold[alice.id]!.emoji, visible);
        expect(oldFold[alice.id]!.emoji, oldVisible);
        expect(currentFold[bob.id]!.emoji, '❤️');
        expect(oldFold[bob.id]!.emoji, '❤️');
        final currentSummary = summarizeReactions(currentFold, alice.id);
        final oldSummary = old.summarizeReactions(oldFold, alice.id);
        expect(
          currentSummary.map((summary) => summary.emoji),
          unorderedEquals(['❤️', ?visible]),
        );
        expect(
          oldSummary.map((summary) => summary.emoji),
          unorderedEquals(['❤️', ?oldVisible]),
        );
        expect(currentSummary.every((summary) => summary.count == 1), isTrue);
        expect(oldSummary.every((summary) => summary.count == 1), isTrue);
        expect(
          currentSummary
              .singleWhere((summary) => summary.emoji == '❤️')
              .selectedByMe,
          isFalse,
        );
        if (visible != null) {
          expect(
            currentSummary
                .singleWhere((summary) => summary.emoji == visible)
                .selectedByMe,
            isTrue,
          );
        }
      }

      check([initial, other, rich, initial], 2, _rich, null);
      check([rich, rich, other, initial], 2, _rich, null);
      check([initial, remove, rich, other, initial], 3, null, null);
      check(
        [remove, rich, other, legacyReplacement, initial, remove],
        4,
        '😂',
        '😂',
      );
      check([legacyReplacement, rich, other, remove, initial], 4, '😂', '😂');
    },
  );

  for (final extension in <Map<String, dynamic>>[
    {'v': 1, 'emoji': '\u{10ffff}\u200d\u{10fffe}'},
    {'v': 1, 'emoji': '🫠' * 32}, // Exactly 128 UTF-8 bytes, opaque and hidden.
    {
      'v': 2,
      'emoji': _rich,
      'future': {'format': 'opaque'},
    },
    {'v': 9007199254740991},
  ]) {
    test(
      'unknown extension $extension stays hidden while superseding old reactions',
      () async {
        final initial = await sendCurrent('initial', 1, '👍');
        final future = await decodeBoth(
          await legacyEnvelope(
            'future',
            _payload(2, {'action': 'remove', 'reactionV2': extension}),
          ),
          alice.publicKey,
        );
        final newer = await sendCurrent('newer', 3, '😂');
        expect(future.current.emoji, isNull);
        expect(future.legacy.emoji, isNull);
        for (final events in [
          [initial, future, initial],
          [future, initial, future],
        ]) {
          final current = foldReactions(
            events.map((event) => event.current),
          )[_target]!;
          final legacy = old.foldReactions(
            events.map((event) => event.legacy),
          )[_target]!;
          expect(current[alice.id]!.counter, 2);
          expect(legacy[alice.id]!.counter, 2);
          expect(summarizeReactions(current, alice.id), isEmpty);
          expect(old.summarizeReactions(legacy, alice.id), isEmpty);
        }
        final recovered = [newer, future, initial];
        expect(
          foldReactions(
            recovered.map((event) => event.current),
          )[_target]![alice.id]!.emoji,
          '😂',
        );
        expect(
          old
              .foldReactions(
                recovered.map((event) => event.legacy),
              )[_target]![alice.id]!
              .emoji,
          '😂',
        );
      },
    );
  }

  final malformedExtensions = <String, dynamic>{
    'null': null,
    'scalar': '🫠',
    'array': [1, _rich],
    'missing version': {'emoji': _rich},
    'boolean version': {'v': true, 'emoji': _rich},
    'zero version': {'v': 0, 'emoji': _rich},
    'unsafe integer version': {'v': 9007199254740992, 'emoji': _rich},
    'missing emoji': {'v': 1},
    'empty emoji': {'v': 1, 'emoji': ''},
    'nonstring emoji': {'v': 1, 'emoji': 1},
    'emoji exceeds UTF-8 bound': {'v': 1, 'emoji': '🫠' * 33},
    'extra v1 field': {'v': 1, 'emoji': _rich, 'extra': true},
    'oversized future extension': {'v': 2, 'data': 'a' * 512},
  };
  for (final entry in malformedExtensions.entries) {
    test('new decryptor rejects malformed extension: ${entry.key}', () async {
      // The released validator ignores unknown fields and can create these
      // authentic signed frames. The new receiver must validate the extension.
      final envelope = await legacyEnvelope(
        'malformed',
        _payload(1, {'action': 'remove', 'reactionV2': entry.value}),
      );
      await expectLater(
        crypto.decrypt(envelope, key, alice.publicKey, expectedGroupId: _group),
        throwsFormatException,
      );
    });
  }

  test(
    'contradictory legacy and rich selections cannot render different emojis',
    () async {
      final envelope = await legacyEnvelope(
        'contradictory',
        _payload(1, {
          'action': 'set',
          'emoji': '👍',
          'reactionV2': {'v': 1, 'emoji': _rich},
        }),
      );
      await expectLater(
        crypto.decrypt(envelope, key, alice.publicKey, expectedGroupId: _group),
        throwsFormatException,
      );
    },
  );

  test('outgoing unknown selections fail before encryption', () {
    expect(
      () => ReactionEmoji.payloadFields('not-an-emoji'),
      throwsFormatException,
    );
    expect(() => ReactionEmoji.payloadFields(''), throwsFormatException);
    expect(
      () => ReactionEmoji.payloadFields('\u{10ffff}'),
      throwsFormatException,
    );
  });
}
