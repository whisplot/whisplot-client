import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/short_invite_service.dart';

void main() {
  const server = Invite.defaultServer;
  late Invite invite;
  late ApiClient client;
  Map<String, dynamic>? uploaded;
  Map<String, dynamic>? replaceResponse;
  String? readPath;
  setUp(() async {
    final crypto = CryptoService();
    invite = Invite(
      server: server,
      groupId: '11111111-1111-4111-8111-111111111111',
      name: 'Short code test',
      inviteId: '22222222-2222-4222-8222-222222222222',
      secret: b64(List.generate(32, (i) => i)),
      groupKey: b64(List.generate(32, (i) => 255 - i)),
      expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
      keyEpoch: 2,
      protocolVersion: 2,
      privacyEpoch: 2,
      minClientBuild: 8,
    );
    uploaded = null;
    replaceResponse = null;
    readPath = null;
    client = ApiClient(
      server: server,
      identity: await crypto.identity(),
      crypto: crypto,
      client: MockClient((request) async {
        if (request.method == 'POST') {
          uploaded = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'v': 1, 'expiresAt': invite.expiresAt}),
            200,
          );
        }
        readPath = request.url.path;
        return http.Response(
          jsonEncode(
            replaceResponse ??
                {
                  'v': 1,
                  'nonce': uploaded!['nonce'],
                  'ciphertext': uploaded!['ciphertext'],
                  'expiresAt': invite.expiresAt,
                },
          ),
          200,
        );
      }),
    );
  });
  tearDown(() => client.close());

  test(
    '22-character random code resolves full original key without uploading its capability',
    () async {
      final code = await ShortInviteService.create(invite, client);
      expect(code.length, 22);
      expect(ShortInviteService.isCode(code), isTrue);
      expect(uploaded!.keys.toSet(), {
        'v',
        'lookupHash',
        'nonce',
        'ciphertext',
      });
      final body = jsonEncode(uploaded);
      expect(body.contains(code), isFalse);
      expect(body.contains(invite.groupKey), isFalse);
      expect(body.contains(invite.secret), isFalse);
      final resolved = await ShortInviteService.resolve('  $code\n', client);
      expect(resolved.encode(), invite.encode());
      expect(readPath, '/v1/invite-codes/${uploaded!['lookupHash']}');
    },
  );

  test(
    'ciphertext substitution and a wrong code cannot provide a group key',
    () async {
      final code = await ShortInviteService.create(invite, client);
      final wrong = b64(List<int>.filled(16, 19));
      await expectLater(
        ShortInviteService.resolve(wrong, client),
        throwsFormatException,
      );
      replaceResponse = {
        'v': 1,
        'nonce': uploaded!['nonce'],
        'ciphertext': b64(List<int>.filled(64, 7)),
        'expiresAt': invite.expiresAt,
      };
      await expectLater(
        ShortInviteService.resolve(code, client),
        throwsFormatException,
      );
    },
  );

  test(
    'response expiry cannot extend the encrypted invitation lifetime',
    () async {
      final code = await ShortInviteService.create(invite, client);
      replaceResponse = {
        'v': 1,
        'nonce': uploaded!['nonce'],
        'ciphertext': uploaded!['ciphertext'],
        'expiresAt': invite.expiresAt + 1000,
      };
      await expectLater(
        ShortInviteService.resolve(code, client),
        throwsFormatException,
      );
    },
  );

  test(
    'whitespace accepted but noncanonical or old full invites are not short codes',
    () {
      expect(ShortInviteService.isCode(b64(List.filled(16, 1))), isTrue);
      expect(ShortInviteService.isCode('A' * 21 + 'B'), isFalse);
      expect(ShortInviteService.isCode(invite.encodeCompact()), isFalse);
      expect(ShortInviteService.isCode('123456'), isFalse);
    },
  );
}
