import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';

const now = 1795140000000;
Invite invitation({
  String server = Invite.defaultServer,
  String groupId = '12345678-1234-4567-89ab-123456789abc',
  int epoch = 1,
  int expires = now + 86400000,
  int protocol = 2,
  int privacy = 2,
  int build = 5,
}) => Invite(
  server: server,
  groupId: groupId,
  name: '这是一个很长的中文群名称',
  inviteId: 'abcdef01-2345-4678-9abc-0123456789ab',
  secret: b64(List.generate(32, (i) => i)),
  groupKey: b64(List.generate(32, (i) => 255 - i)),
  expiresAt: expires,
  keyEpoch: epoch,
  protocolVersion: protocol,
  privacyEpoch: privacy,
  minClientBuild: build,
);
Invite decode(String code) =>
    Invite.parse(code, validateServer: normalizeServer, now: now);

void sameAccess(Invite parsed, Invite source) {
  expect(parsed.server, source.server);
  expect(parsed.groupId, source.groupId);
  expect(parsed.inviteId, source.inviteId);
  expect(parsed.secret, source.secret);
  expect(parsed.groupKey, source.groupKey);
  expect(parsed.expiresAt, source.expiresAt);
  expect(parsed.keyEpoch, source.keyEpoch);
  expect(parsed.protocolVersion, source.protocolVersion);
  expect(parsed.privacyEpoch, source.privacyEpoch);
  expect(parsed.minClientBuild, source.minClientBuild);
}

// Independent IEEE CRC32 fixture, used to test valid checksums with malformed
// structure. Recomputing this check must not make invalid fields acceptable.
String checked(List<int> body) {
  var crc = 0xffffffff;
  for (final b in body) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  crc ^= 0xffffffff;
  return b64([
    ...body,
    for (final s in [24, 16, 8, 0]) (crc >> s) & 255,
  ]);
}

void main() {
  test('default invitation is 150 characters without reducing either key', () {
    final source = invitation(), compact = source.encodeCompact();
    expect(compact.length, 150);
    expect(compact.length, lessThan(source.encode().length ~/ 3));
    expect(compact, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(compact.contains('://'), isFalse);
    sameAccess(decode(compact), source);
    expect(decode(compact).name, '邀请的群聊');
  });

  test('custom origin is explicit, including non-default port', () {
    final source = invitation(server: 'https://private.example:8443');
    sameAccess(decode(source.encodeCompact()), source);
    expect(
      () =>
          decode(invitation(server: 'http://private.example').encodeCompact()),
      throwsFormatException,
    );
  });

  test(
    'case-sensitive custom group identifiers are not silently rewritten',
    () {
      final source = invitation(
        groupId: '12345678-1234-4567-89AB-123456789ABC',
      );
      final code = source.encodeCompact();
      expect(code.contains('://'), isFalse);
      sameAccess(decode(code), source);
    },
  );

  test('full old link and bare old payload keep all invitation fields', () {
    final source = invitation();
    for (final code in [source.encode(), source.encode().split('#').last]) {
      sameAccess(decode(code), source);
      expect(decode(code).name, source.name);
    }
  });

  test('wrapped clipboard codes and automatic prefix completion work', () {
    final source = invitation(), code = source.encodeCompact();
    final wrapped = '${code.substring(0, 50)}\r\n ${code.substring(50)}';
    sameAccess(decode('  $wrapped\n'), source);
    sameAccess(decode('nearlink://join#$wrapped'), source);
    expect(() => decode('https://join#$code'), throwsFormatException);
    expect(() => decode('nearlink://join/other#$code'), throwsFormatException);
  });

  test('every single-byte corruption or truncation is rejected', () {
    final raw = unb64(invitation().encodeCompact());
    for (var i = 0; i < raw.length; i++) {
      final damaged = [...raw];
      damaged[i] ^= 1;
      expect(() => decode(b64(damaged)), throwsFormatException);
      expect(() => decode(b64(raw.sublist(0, i))), throwsFormatException);
    }
  });

  test('expiry, protocol and security metadata checks survive compression', () {
    for (final source in [
      invitation(expires: now),
      invitation(protocol: 1),
      invitation(privacy: 1),
      invitation(build: 0),
    ]) {
      expect(() => decode(source.encodeCompact()), throwsFormatException);
    }
    // Retain future policy values for the controller's admission check; never
    // silently rewrite them to the installed client's supported policy.
    final future = invitation(epoch: 9007199254740991, privacy: 3, build: 999);
    sameAccess(decode(future.encodeCompact()), future);
    expect(
      () => invitation(epoch: 9007199254740992).encodeCompact(),
      throwsFormatException,
    );
  });

  test('trailing data, unknown flags and noncanonical varints fail closed', () {
    final raw = unb64(invitation().encodeCompact());
    final body = raw.sublist(0, raw.length - 4);
    expect(() => decode(checked([...body, 0])), throwsFormatException);
    expect(
      () => decode(checked([3, 2, ...body.sublist(2)])),
      throwsFormatException,
    );
    expect(
      () => decode(checked([3, 0, 0x82, 0, ...body.sublist(3)])),
      throwsFormatException,
    );
    expect(
      () => decode(checked([3, 0, ...List.filled(9, 255), ...body.sublist(3)])),
      throwsFormatException,
    );
    expect(() => decode('A' * 8193), throwsFormatException);
  });
}
