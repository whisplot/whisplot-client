import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import '../core/models.dart';
import 'api_client.dart';

/// A 128-bit capability unlocks an opaque invitation stored by the relay.
/// Neither the capability nor its derived encryption key is sent to the relay.
/// The full group key remains 256 bits and old self-contained invites still work.
class ShortInviteService {
  static const _context = 'hello-mentor-short-invite-v1';
  static final _aes = AesGcm.with256bits();
  static final _random = Random.secure();

  static Future<Map<String, dynamic>> _request(
    ApiClient client,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    try {
      return await client.request(method, path, body);
    } on ApiException catch (error) {
      final message = switch (error.code) {
        'invite_unavailable' => '邀请码已失效，请重新获取',
        'not_found' => method == 'GET' ? '邀请码无效，请确认连接的服务或重新获取' : '当前服务尚未支持短邀请码',
        'rate_limited' => '操作过于频繁，请稍后重试',
        'invite_code_conflict' => '请重新生成邀请码',
        _ => null,
      };
      if (message != null) throw FormatException(message);
      rethrow;
    }
  }

  static String _clean(String value) =>
      value.trim().replaceAll(RegExp(r'\s'), '');
  static bool isCode(String value) {
    final code = _clean(value);
    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(code)) return false;
    try {
      final bytes = unb64(code);
      return bytes.length == 16 && b64(bytes) == code;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _lookup(List<int> capability) async {
    final digest = await Sha256().hash([
      ...utf8.encode('$_context:lookup\n'),
      ...capability,
    ]);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<SecretKey> _key(List<int> capability) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(capability),
        nonce: const [],
        info: utf8.encode('$_context:encryption'),
      );

  static List<int> _aad(String server, String lookup) =>
      utf8.encode('$_context\n$server\n$lookup');

  static Future<String> create(Invite invite, ApiClient client) async {
    if (invite.server != client.server) {
      throw const FormatException('邀请码与当前服务不一致');
    }
    final capability = List<int>.generate(16, (_) => _random.nextInt(256));
    final code = b64(capability), lookup = await _lookup(capability);
    final box = await _aes.encrypt(
      utf8.encode(invite.encode()),
      secretKey: await _key(capability),
      aad: _aad(client.server, lookup),
    );
    final response = await _request(
      client,
      'POST',
      '/v1/groups/${invite.groupId}/invites/${invite.inviteId}/short',
      {
        'v': 1,
        'lookupHash': lookup,
        'nonce': b64(box.nonce),
        'ciphertext': b64([...box.cipherText, ...box.mac.bytes]),
      },
    );
    if (response['v'] != 1 || response['expiresAt'] != invite.expiresAt) {
      throw const FormatException('无法确认短邀请码，请重试');
    }
    return code;
  }

  static Future<Invite> resolve(String value, ApiClient client) async {
    final code = _clean(value);
    if (!isCode(code)) throw const FormatException('请输入有效的邀请码');
    final capability = unb64(code), lookup = await _lookup(capability);
    final response = await _request(client, 'GET', '/v1/invite-codes/$lookup');
    try {
      if (response['v'] != 1 ||
          response['nonce'] is! String ||
          response['ciphertext'] is! String ||
          response['expiresAt'] is! int ||
          (response['ciphertext'] as String).length > 8192) {
        throw const FormatException('邀请码内容无效');
      }
      final nonce = unb64(response['nonce'] as String);
      final bytes = unb64(response['ciphertext'] as String);
      if (nonce.length != 12 || bytes.length < 17 || bytes.length > 6144) {
        throw const FormatException('邀请码内容无效');
      }
      final clear = await _aes.decrypt(
        SecretBox(
          bytes.sublist(0, bytes.length - 16),
          nonce: nonce,
          mac: Mac(bytes.sublist(bytes.length - 16)),
        ),
        secretKey: await _key(capability),
        aad: _aad(client.server, lookup),
      );
      final invite = Invite.parse(
        utf8.decode(clear),
        validateServer: (server) =>
            normalizeServer(server, allowLocalHttp: ApiClient.allowsLocalHttp),
      );
      if (invite.server != client.server ||
          invite.expiresAt != response['expiresAt']) {
        throw const FormatException('邀请码与当前服务不一致');
      }
      return invite;
    } catch (_) {
      throw const FormatException('邀请码无效或已过期，请重新获取');
    }
  }
}
