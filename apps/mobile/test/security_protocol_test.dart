import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/client_security.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/core/peer_auth.dart';
import 'security_fixtures.dart';

void main() {
  late SecurityFixtures f;
  setUp(() async {
    f = await SecurityFixtures.create();
  });
  test(
    'same group rekey keeps old history readable; old key cannot read v2',
    () async {
      final oldKey = List.filled(32, 21),
          newKey = List.filled(32, 22),
          owner = f.person('a');
      final old = await f.crypto.encrypt(
        identity: owner,
        groupId: 'group',
        messageId: 'old',
        text: 'old history',
        groupKey: oldKey,
      );
      final next = await f.crypto.encrypt(
        identity: owner,
        groupId: 'group',
        messageId: 'new',
        text: 'new private discussion',
        groupKey: newKey,
        keyEpoch: 1,
      );
      expect(next.toJson()['v'], 2);
      expect(
        (await f.crypto.decrypt(
          old,
          oldKey,
          owner.publicKey,
          expectedGroupId: 'group',
        ))['text'],
        'old history',
      );
      expect(
        (await f.crypto.decrypt(
          next,
          newKey,
          owner.publicKey,
          expectedGroupId: 'group',
        ))['text'],
        'new private discussion',
      );
      await expectLater(
        f.crypto.decrypt(
          next,
          oldKey,
          owner.publicKey,
          expectedGroupId: 'group',
        ),
        throwsA(anything),
      );
      final altered = Envelope.fromJson({...next.toJson(), 'keyEpoch': 2});
      await expectLater(
        f.crypto.decrypt(
          altered,
          newKey,
          owner.publicKey,
          expectedGroupId: 'group',
        ),
        throwsA(anything),
      );
      expect(
        () => Envelope.fromJson({...old.toJson(), 'keyEpoch': 1}),
        throwsFormatException,
      );
    },
  );
  test(
    'fresh recipient key wrap is owner authenticated and context bound',
    () async {
      final owner = f.person('a'),
          recipient = f.person('b'),
          stranger = f.person('z');
      final key = List.filled(32, 42);
      final wrapped = await f.crypto.wrapGroupKey(
        sender: owner,
        groupId: 'group',
        keyEpoch: 1,
        groupKey: key,
        recipientId: recipient.id,
        recipientPublicKey: f.encryption[recipient.id]!.publicKey,
      );
      Future<List<int>> unwrap(
        WrappedGroupKey value, {
        String group = 'group',
        Identity? who,
      }) => f.crypto.unwrapGroupKey(
        wrapped: value,
        groupId: group,
        ownerPublicKey: owner.publicKey,
        expectedOwnerId: owner.id,
        recipient: who ?? recipient,
        encryptionIdentity: f.encryption[(who ?? recipient).id]!,
      );
      expect(await unwrap(wrapped), key);
      await expectLater(
        unwrap(wrapped, group: 'another-room'),
        throwsA(anything),
      );
      await expectLater(unwrap(wrapped, who: stranger), throwsA(anything));
      final bad = WrappedGroupKey.fromJson({
        ...wrapped.toJson(),
        'keyEpoch': 2,
      });
      await expectLater(unwrap(bad), throwsA(anything));
      final second = await f.crypto.wrapGroupKey(
        sender: owner,
        groupId: 'group',
        keyEpoch: 1,
        groupKey: key,
        recipientId: recipient.id,
        recipientPublicKey: f.encryption[recipient.id]!.publicKey,
      );
      expect(second.ephemeralKey, isNot(wrapped.ephemeralKey));
      expect(second.ciphertext, isNot(wrapped.ciphertext));
    },
  );
  test(
    'signed policy rejects edits, wrong issuer, excessive lease and expiry',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      Future<SignedPolicy> verify(
        Map<String, dynamic> wire, {
        int? at,
        String? issuer,
      }) => SignedPolicy.verify(
        wire,
        crypto: f.crypto,
        now: at ?? now,
        authorityPublicKey: issuer ?? f.authority.publicKey,
      );
      final wire = await f.policyWire(now: now);
      expect((await verify(wire)).policy.supportsThisClient, isTrue);
      final raw = jsonDecode(utf8.decode(unb64(wire['payload'])));
      await expectLater(
        verify({
          ...wire,
          'payload': b64(
            utf8.encode(jsonEncode({...raw, 'minClientBuild': 1})),
          ),
        }),
        throwsFormatException,
      );
      await expectLater(
        verify(wire, issuer: f.person('a').publicKey),
        throwsFormatException,
      );
      await expectLater(verify(wire, at: now + 900000), throwsFormatException);
      await expectLater(
        verify(await f.policyWire(now: now, lifetime: 900001)),
        throwsFormatException,
      );
      await expectLater(
        verify(await f.policyWire(now: now + 31000)),
        throwsFormatException,
      );
      expect(
        (await verify(
          await f.policyWire(now: now, minBuild: AppSecurity.clientBuild + 1),
        )).policy.supportsThisClient,
        isFalse,
      );
      final expired = await SignedPolicy.verify(
        wire,
        crypto: f.crypto,
        now: now + 900000,
        authorityPublicKey: f.authority.publicKey,
        allowExpired: true,
      );
      expect(expired.policy.isFreshAt(now + 900000), isFalse);
    },
  );
  test(
    'ticket cannot cross group, epoch, recipient or signing identity',
    () async {
      final a = f.person('a'), wire = await f.ticketWire(f.person('a'));
      Future<ParticipationTicket> verify({
        String group = 'group',
        int epoch = 1,
        String? recipient,
        String? pub,
      }) => ParticipationTicket.verify(
        wire,
        crypto: f.crypto,
        expectedGroupId: group,
        expectedKeyEpoch: epoch,
        expectedDeviceId: recipient ?? a.id,
        expectedPublicKey: pub ?? a.publicKey,
        authorityPublicKey: f.authority.publicKey,
      );
      expect((await verify()).deviceId, a.id);
      await expectLater(verify(group: 'other'), throwsFormatException);
      await expectLater(verify(epoch: 2), throwsFormatException);
      await expectLater(verify(recipient: f.id('b')), throwsFormatException);
      await expectLater(
        verify(pub: f.person('b').publicKey),
        throwsFormatException,
      );
    },
  );
  Future<(PeerAuthenticator, PeerAuthenticator)> pair({
    int? now,
    int lifetime = 900000,
  }) async {
    final a = f.person('a'), b = f.person('b');
    return (
      PeerAuthenticator(
        crypto: f.crypto,
        identity: a,
        group: f.group(),
        ownTicket: await f.ticket(a, now: now, lifetime: lifetime),
        peerId: b.id,
        peerPublicKey: b.publicKey,
        now: now == null ? null : () => now,
        authorityPublicKey: f.authority.publicKey,
      ),
      PeerAuthenticator(
        crypto: f.crypto,
        identity: b,
        group: f.group(),
        ownTicket: await f.ticket(b, now: now, lifetime: lifetime),
        peerId: a.id,
        peerPublicKey: a.publicKey,
        now: now == null ? null : () => now,
        authorityPublicKey: f.authority.publicKey,
      ),
    );
  }

  test(
    'mutual nonce proof admits peers only after both directions complete',
    () async {
      final (a, b) = await pair();
      final proofA = await a.receive(b.hello()),
          proofB = await b.receive(a.hello());
      expect(a.authenticated, isFalse);
      a.markProofSent();
      b.markProofSent();
      await a.receive(proofB!);
      await b.receive(proofA!);
      expect(a.authenticated, isTrue);
      expect(b.authenticated, isTrue);
      a.invalidate();
      expect(a.authenticated, isFalse);
    },
  );
  test(
    'copied proof from a previous connection cannot authorize a new nonce',
    () async {
      final (a, b) = await pair();
      await a.receive(b.hello());
      final proof = await b.receive(a.hello());
      final (freshA, freshB) = await pair();
      await freshA.receive(freshB.hello());
      freshA.markProofSent();
      await expectLater(freshA.receive(proof!), throwsFormatException);
      expect(freshA.authenticated, isFalse);
    },
  );
  test(
    'old protocol frame and duplicate concurrent hello fail closed',
    () async {
      final (a, b) = await pair();
      await expectLater(
        a.receive({'v': 1, 'ciphertext': 'legacy'}),
        throwsFormatException,
      );
      expect(a.authenticated, isFalse);
      final (freshA, freshB) = await pair();
      final frame = freshB.hello();
      final one = expectLater(freshA.receive(frame), throwsFormatException);
      final two = expectLater(freshA.receive(frame), throwsFormatException);
      await Future.wait([one, two]);
      expect(freshA.authenticated, isFalse);
    },
  );
  test(
    'lease expiration closes already authenticated pair even with frozen wall time',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final (a, b) = await pair(now: now, lifetime: 150);
      final proofA = await a.receive(b.hello()),
          proofB = await b.receive(a.hello());
      a.markProofSent();
      b.markProofSent();
      await a.receive(proofB!);
      await b.receive(proofA!);
      expect(a.authenticated, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(a.authenticated, isFalse);
      expect(b.authenticated, isFalse);
    },
  );
  test(
    'higher signed policy notifies coordinator but cannot reuse old local ticket',
    () async {
      final a = f.person('a'), b = f.person('b');
      var revision = 0;
      final peer = PeerAuthenticator(
        crypto: f.crypto,
        identity: a,
        group: f.group(),
        ownTicket: await f.ticket(a),
        peerId: b.id,
        peerPublicKey: b.publicKey,
        authorityPublicKey: f.authority.publicKey,
        onRemotePolicy: (p) {
          revision = p.policyRevision;
        },
      );
      final wire = await f.ticketWire(b, revision: 2);
      await expectLater(
        peer.receive({
          'type': 'hello',
          'ticket': wire,
          'nonce': b64(f.crypto.randomBytes(32)),
        }),
        throwsFormatException,
      );
      expect(revision, 2);
      expect(peer.authenticated, isFalse);
    },
  );
}
