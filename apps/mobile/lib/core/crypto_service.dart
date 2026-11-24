import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'models.dart';

class CryptoService {
  final Ed25519 _ed = Ed25519();
  final AesGcm _aes = AesGcm.with256bits();
  final X25519 _x25519 = X25519();
  final Random _random = Random.secure();
  List<int> randomBytes(int count) =>
      List.generate(count, (_) => _random.nextInt(256));
  Future<String> hash(List<int> bytes) async =>
      b64((await Sha256().hash(bytes)).bytes);
  Future<Identity> identity([List<int>? seed]) async {
    final bytes = seed ?? randomBytes(32);
    if (bytes.length != 32) throw const FormatException('身份密钥损坏');
    final pair = await _ed.newKeyPairFromSeed(bytes);
    final key = (await pair.extractPublicKey()).bytes;
    return Identity(seed: bytes, publicKey: b64(key), id: await hash(key));
  }

  Future<String> sign(Identity identity, String text) async {
    final key = await _ed.newKeyPairFromSeed(identity.seed);
    return b64((await _ed.sign(utf8.encode(text), keyPair: key)).bytes);
  }

  Future<EncryptionIdentity> encryptionIdentity([List<int>? seed]) async {
    final bytes = List<int>.from(seed ?? randomBytes(32));
    if (bytes.length != 32) throw const FormatException('密钥分发身份损坏');
    final pair = await _x25519.newKeyPairFromSeed(bytes);
    return EncryptionIdentity(
      seed: bytes,
      publicKey: b64((await pair.extractPublicKey()).bytes),
    );
  }

  Future<SecretKey> _wrapKey(
    SimpleKeyPair pair,
    String remote,
    String context,
  ) async {
    final remoteBytes = unb64(remote);
    if (remoteBytes.length != 32 || b64(remoteBytes) != remote) {
      throw const FormatException('密钥接收身份无效');
    }
    final shared = await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(remoteBytes, type: KeyPairType.x25519),
    );
    final secret = await shared.extractBytes();
    if (secret.length != 32 || secret.every((b) => b == 0)) {
      throw const FormatException('密钥协商失败');
    }
    return Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: shared, nonce: const [], info: utf8.encode(context));
  }

  Future<WrappedGroupKey> wrapGroupKey({
    required Identity sender,
    required String groupId,
    required int keyEpoch,
    required List<int> groupKey,
    required String recipientId,
    required String recipientPublicKey,
  }) async {
    if (groupKey.length != 32 ||
        keyEpoch < 1 ||
        keyEpoch > 9007199254740991 ||
        unb64(recipientId).length != 32) {
      throw const FormatException('群密钥参数无效');
    }
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralKey = b64((await ephemeral.extractPublicKey()).bytes);
    final draft = WrappedGroupKey(
      keyEpoch: keyEpoch,
      senderId: sender.id,
      recipientId: recipientId,
      recipientKey: recipientPublicKey,
      ephemeralKey: ephemeralKey,
      nonce: '',
      ciphertext: '',
      signature: '',
    );
    final context = draft.context(groupId);
    final box = await _aes.encrypt(
      groupKey,
      secretKey: await _wrapKey(ephemeral, recipientPublicKey, context),
      nonce: randomBytes(12),
      aad: utf8.encode(context),
    );
    final wrapped = WrappedGroupKey(
      keyEpoch: keyEpoch,
      senderId: sender.id,
      recipientId: recipientId,
      recipientKey: recipientPublicKey,
      ephemeralKey: ephemeralKey,
      nonce: b64(box.nonce),
      ciphertext: b64([...box.cipherText, ...box.mac.bytes]),
      signature: '',
    );
    return wrapped.withSignature(
      await sign(sender, wrapped.signingText(groupId)),
    );
  }

  Future<List<int>> unwrapGroupKey({
    required WrappedGroupKey wrapped,
    required String groupId,
    required String ownerPublicKey,
    required String expectedOwnerId,
    required Identity recipient,
    required EncryptionIdentity encryptionIdentity,
  }) async {
    // Revalidate even callers constructing the object directly, before ECDH.
    WrappedGroupKey.fromJson(wrapped.toJson());
    if (wrapped.senderId != expectedOwnerId ||
        await hash(unb64(ownerPublicKey)) != expectedOwnerId ||
        wrapped.recipientId != recipient.id ||
        wrapped.recipientKey != encryptionIdentity.publicKey ||
        !await verify(
          ownerPublicKey,
          wrapped.signingText(groupId),
          wrapped.signature,
        )) {
      throw const FormatException('群密钥签名或接收身份无效');
    }
    final pair = await _x25519.newKeyPairFromSeed(encryptionIdentity.seed);
    if (b64((await pair.extractPublicKey()).bytes) !=
        encryptionIdentity.publicKey) {
      throw const FormatException('本机密钥分发身份不一致');
    }
    final bytes = unb64(wrapped.ciphertext);
    final context = wrapped.context(groupId);
    final key = await _aes.decrypt(
      SecretBox(
        bytes.sublist(0, 32),
        nonce: unb64(wrapped.nonce),
        mac: Mac(bytes.sublist(32)),
      ),
      secretKey: await _wrapKey(pair, wrapped.ephemeralKey, context),
      aad: utf8.encode(context),
    );
    if (key.length != 32) throw const FormatException('群密钥长度无效');
    return key;
  }

  Future<bool> verify(String publicKey, String text, String signature) async =>
      _ed.verify(
        utf8.encode(text),
        signature: Signature(
          unb64(signature),
          publicKey: SimplePublicKey(
            unb64(publicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
  Future<Envelope> encrypt({
    required Identity identity,
    required String groupId,
    required String messageId,
    required String text,
    required List<int> groupKey,
    String? senderName,
    String? replyToMessageId,
    int? createdAt,
    int keyEpoch = 0,
  }) async {
    return encryptPayload(
      identity: identity,
      groupId: groupId,
      messageId: messageId,
      groupKey: groupKey,
      keyEpoch: keyEpoch,
      payload: {
        'text': text,
        'createdAt': createdAt ?? DateTime.now().millisecondsSinceEpoch,
        'senderName': ?senderName,
        if (replyToMessageId != null)
          'replyTo': {'v': 1, 'messageId': replyToMessageId},
      },
    );
  }

  /// Legacy v1 is retained for history. New network messages use a positive
  /// key epoch, cryptographically bound into both encryption and signature.
  Future<Envelope> encryptPayload({
    required Identity identity,
    required String groupId,
    required String messageId,
    required List<int> groupKey,
    required Map<String, dynamic> payload,
    int keyEpoch = 0,
  }) async {
    validatePayload(payload);
    _validateReceiptBinding(payload, messageId);
    if (keyEpoch < 0 || keyEpoch > 9007199254740991 || groupKey.length != 32) {
      throw const FormatException('群密钥代次无效');
    }
    final nonce = randomBytes(12);
    final aad = keyEpoch == 0
        ? 'nearlink-message-v1\n$groupId\n$messageId\n${identity.id}'
        : 'nearlink-message-v2\n$groupId\n$keyEpoch\n$messageId\n${identity.id}';
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: SecretKey(groupKey),
      nonce: nonce,
      aad: utf8.encode(aad),
    );
    final envelope = Envelope(
      groupId: groupId,
      messageId: messageId,
      senderId: identity.id,
      nonce: b64(nonce),
      ciphertext: b64([...box.cipherText, ...box.mac.bytes]),
      signature: '',
      keyEpoch: keyEpoch,
    );
    return envelope.withSignature(await sign(identity, envelope.signingText));
  }

  Future<Map<String, dynamic>> decrypt(
    Envelope envelope,
    List<int> key,
    String publicKey, {
    required String expectedGroupId,
  }) async {
    if (envelope.groupId != expectedGroupId ||
        await hash(unb64(publicKey)) != envelope.senderId ||
        !await verify(publicKey, envelope.signingText, envelope.signature)) {
      throw const FormatException('消息身份验证失败');
    }
    final data = unb64(envelope.ciphertext);
    if (data.length < 16) throw const FormatException('密文损坏');
    final clear = await _aes.decrypt(
      SecretBox(
        data.sublist(0, data.length - 16),
        nonce: unb64(envelope.nonce),
        mac: Mac(data.sublist(data.length - 16)),
      ),
      secretKey: SecretKey(key),
      aad: utf8.encode(envelope.aad),
    );
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map<String, dynamic>) throw const FormatException('消息正文无效');
    validatePayload(decoded);
    _validateReceiptBinding(decoded, envelope.messageId);
    return decoded;
  }

  void _validateReceiptBinding(Map<String, dynamic> payload, String messageId) {
    if (ReadReceiptEvent.isPayload(payload) &&
        payload['targetMessageId'] != messageId) {
      throw const FormatException('已读回执绑定无效');
    }
  }

  void validatePayload(Map<String, dynamic> payload) {
    final created = payload['createdAt'];
    if (created is! int || created < 0 || created > 8640000000000000) {
      throw const FormatException('消息时间无效');
    }
    final type = payload['type'] ?? 'text';
    if (ReadReceiptEvent.isPayload(payload)) {
      final receipt = payload['readReceiptV1'];
      final ids = receipt is Map<String, dynamic>
          ? receipt['messageIds']
          : null;
      if (type != 'reaction' ||
          payload.length != 6 ||
          payload['action'] != 'remove' ||
          payload['counter'] != 1 ||
          receipt is! Map<String, dynamic> ||
          receipt.length != 2 ||
          receipt['v'] is! int ||
          receipt['v'] != 1 ||
          ids is! List ||
          ids.isEmpty ||
          ids.length > ReadReceiptEvent.maxBatchSize ||
          ids.any(
            (id) =>
                id is! String ||
                !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id),
          ) ||
          ids.toSet().length != ids.length) {
        throw const FormatException('已读回执格式无效');
      }
    }
    if (payload.containsKey('replyTo')) {
      final replyTo = payload['replyTo'];
      if ((type != 'text' && type != 'voice') ||
          replyTo is! Map<String, dynamic> ||
          replyTo.length != 2 ||
          !replyTo.containsKey('v') ||
          !replyTo.containsKey('messageId') ||
          replyTo['v'] is! int ||
          replyTo['v'] != 1 ||
          replyTo['messageId'] is! String ||
          (replyTo['messageId'] as String).length != 36 ||
          !_replyMessageId.hasMatch(replyTo['messageId'] as String)) {
        throw const FormatException('引用消息格式无效');
      }
    }
    switch (type) {
      case 'text':
        final text = payload['text'];
        if (text is! String ||
            text.trim().isEmpty ||
            utf8.encode(text).length > 4000) {
          throw const FormatException('每条消息请限制在4000字节以内');
        }
        if (payload.containsKey('senderName') &&
            (payload['senderName'] is! String ||
                !_validSenderName(payload['senderName'] as String))) {
          throw const FormatException('消息临时ID无效');
        }
      case 'voice':
        if (payload.containsKey('text') ||
            payload['voice'] is! Map<String, dynamic> ||
            payload['senderName'] is! String ||
            !_validSenderName(payload['senderName'])) {
          throw const FormatException('语音消息格式无效');
        }
        VoiceAttachment.fromJson(payload['voice'] as Map<String, dynamic>);
      case 'reaction':
        final target = payload['targetMessageId'],
            action = payload['action'],
            counter = payload['counter'];
        if (target is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(target) ||
            counter is! int ||
            counter < 1 ||
            counter > 9007199254740991 ||
            (action != 'set' && action != 'remove') ||
            (action == 'set' &&
                !ReactionEmoji.legacyValues.contains(payload['emoji'])) ||
            (action == 'remove' && payload['emoji'] != null) ||
            payload.containsKey('senderName')) {
          throw const FormatException('表情事件无效');
        }
        if (payload.containsKey('reactionV2')) {
          final extension = payload['reactionV2'];
          if (action != 'remove' ||
              extension is! Map<String, dynamic> ||
              extension['v'] is! int ||
              extension['v'] < 1 ||
              extension['v'] > 9007199254740991 ||
              utf8.encode(jsonEncode(extension)).length > 512) {
            throw const FormatException('扩展表情事件无效');
          }
          if (extension['v'] == 1 &&
              (extension.length != 2 ||
                  extension['emoji'] is! String ||
                  (extension['emoji'] as String).isEmpty ||
                  utf8.encode(extension['emoji'] as String).length > 128)) {
            throw const FormatException('扩展表情事件无效');
          }
        }
      default:
        throw const FormatException('此版本不支持该消息类型，请升级客户端');
    }
  }

  static final _replyMessageId = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  static const _localStateContext = 'hello-mentor-alias-state-v1';
  Future<SecretKey> _stateKey(Identity identity) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(identity.seed),
        info: utf8.encode(_localStateContext),
        nonce: const [],
      );

  Future<String> sealAliasState(
    Identity identity,
    Map<String, dynamic> value,
  ) async {
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(value)),
      secretKey: await _stateKey(identity),
      nonce: randomBytes(12),
      aad: utf8.encode(_localStateContext),
    );
    return jsonEncode({
      'v': 1,
      'nonce': b64(box.nonce),
      'ciphertext': b64([...box.cipherText, ...box.mac.bytes]),
    });
  }

  Future<Map<String, dynamic>> openAliasState(
    Identity identity,
    String value,
  ) async {
    try {
      final encoded = jsonDecode(value) as Map<String, dynamic>;
      final nonce = unb64(encoded['nonce'] as String),
          data = unb64(encoded['ciphertext'] as String);
      if (encoded['v'] != 1 || nonce.length != 12 || data.length < 16) {
        throw const FormatException();
      }
      final bytes = await _aes.decrypt(
        SecretBox(
          data.sublist(0, data.length - 16),
          nonce: nonce,
          mac: Mac(data.sublist(data.length - 16)),
        ),
        secretKey: await _stateKey(identity),
        aad: utf8.encode(_localStateContext),
      );
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('临时ID计数无法解密，已保留原数据并停止发送');
    }
  }

  bool _validSenderName(String value) =>
      value.trim().isNotEmpty &&
      utf8.encode(value).length <= 80 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
}
