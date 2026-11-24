import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/crypto_service.dart';
import '../core/models.dart';
import 'api_client.dart';
import 'media_wav.dart';

/// Only authenticated ciphertext is persisted here. The pending queue is kept
/// separately from the evictable download cache, so offline sends survive it.
class MediaService {
  MediaService({
    CryptoService? crypto,
    Future<Directory> Function()? directoryProvider,
  }) : crypto = crypto ?? CryptoService(),
       _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final CryptoService crypto;
  final Future<Directory> Function() _directoryProvider;
  final _aes = AesGcm.with256bits();
  static const _budget = 64 * 1024 * 1024;
  Future<void> _writes = Future.value();
  final _deletedGroups = <String>{};
  final _generations = <String, int>{};
  int _generation(Group group) => _generations[group.storageId] ?? 0;
  void _checkGroup(Group group, int generation) {
    if (_deletedGroups.contains(group.storageId) ||
        _generation(group) != generation) {
      throw StateError('此聊天空间已删除，语音操作已取消');
    }
  }

  void allowGroup(Group group) => _deletedGroups.remove(group.storageId);

  Future<void> deleteGroup(Group group) {
    _deletedGroups.add(group.storageId);
    _generations[group.storageId] = _generation(group) + 1;
    return _write(() async {
      final prefix = '${await crypto.hash(utf8.encode(group.storageId))}-';
      for (final folder in ['pending', 'cache']) {
        await for (final entry in (await _folder(
          folder,
        )).list(followLinks: false)) {
          if (entry is File && p.basename(entry.path).startsWith(prefix)) {
            await entry.delete();
          }
        }
      }
    });
  }

  String _aad(Group group, String id) =>
      'hello-mentor-voice-v1\n${group.id}\n$id';

  Future<T> _write<T>(Future<T> Function() operation) {
    final pending = _writes.then((_) => operation());
    _writes = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }

  Future<Directory> _folder(String name) async {
    final root = await _directoryProvider();
    return Directory(
      p.join(root.path, 'voice-v1', name),
    ).create(recursive: true);
  }

  Future<File> _file(String folder, Group group, String id) async {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(id)) {
      throw const FormatException('语音标识无效');
    }
    final namespace = await crypto.hash(utf8.encode(group.storageId));
    return File(p.join((await _folder(folder)).path, '$namespace-$id.bin'));
  }

  Future<void> _atomic(File file, Uint8List data) async {
    final part = File('${file.path}.${const Uuid().v4()}.part');
    try {
      await part.writeAsBytes(data, flush: true);
      await part.rename(file.path);
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  Future<VoiceAttachment> prepareVoice(Group group, Uint8List wav) async {
    final generation = _generation(group);
    _checkGroup(group, generation);
    final duration = MediaWav.durationMs(wav);
    final id = const Uuid().v4(), key = crypto.randomBytes(32);
    final nonce = crypto.randomBytes(12);
    final box = await _aes.encrypt(
      wav,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode(_aad(group, id)),
    );
    final ciphertext = Uint8List.fromList([
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    final attachment = VoiceAttachment(
      mediaId: id,
      key: b64(key),
      nonce: b64(nonce),
      sha256: await crypto.hash(ciphertext),
      byteLength: ciphertext.length,
      durationMs: duration,
    );
    await _write(() async {
      _checkGroup(group, generation);
      var size = 0;
      await for (final entry in (await _folder('pending')).list()) {
        if (entry is File) size += await entry.length();
      }
      if (size + ciphertext.length > _budget) {
        throw const FormatException('本机待发送语音已满，请联网发送现有语音后重试');
      }
      await _atomic(await _file('pending', group, id), ciphertext);
    });
    return attachment;
  }

  Future<Uint8List?> _local(Group group, VoiceAttachment voice) async {
    for (final folder in ['pending', 'cache']) {
      final file = await _file(folder, group, voice.mediaId);
      if (await file.exists()) {
        final data = await file.readAsBytes();
        await _checkCiphertext(data, voice);
        return data;
      }
    }
    return null;
  }

  Future<void> _checkCiphertext(Uint8List data, VoiceAttachment voice) async {
    if (data.length != voice.byteLength ||
        data.length < 17 ||
        data.length > MediaWav.maxEncryptedBytes ||
        await crypto.hash(data) != voice.sha256) {
      throw const FormatException('语音校验失败，文件可能已损坏');
    }
  }

  Future<void> ensureUploaded(
    ApiClient client,
    Group group,
    VoiceAttachment voice, {
    void Function()? checkCurrent,
  }) async {
    if (client.server != group.server) {
      throw const FormatException('语音与当前服务不匹配');
    }
    final data = await _local(group, voice);
    if (data == null) throw const FormatException('找不到本机待发送语音，请重新录制');
    checkCurrent?.call();
    final result = await client.request(
      'PUT',
      '/v1/groups/${group.id}/media/${voice.mediaId}',
      {'v': 1, 'ciphertext': b64(data), 'sha256': voice.sha256},
    );
    if (result['v'] != 1 ||
        result['mediaId'] != voice.mediaId ||
        result['size'] != data.length ||
        result['sha256'] != voice.sha256) {
      throw const FormatException('服务返回了无效的语音上传结果');
    }
  }

  Future<Uint8List> loadVoice(
    ApiClient client,
    Group group,
    VoiceAttachment voice,
  ) async {
    final generation = _generation(group);
    _checkGroup(group, generation);
    if (client.server != group.server) {
      throw const FormatException('语音与当前服务不匹配');
    }
    var data = await _local(group, voice);
    final downloaded = data == null;
    if (data == null) {
      final result = await client.request(
        'GET',
        '/v1/groups/${group.id}/media/${voice.mediaId}',
      );
      if (result['v'] != 1 ||
          result['mediaId'] != voice.mediaId ||
          result['sha256'] != voice.sha256 ||
          result['size'] != voice.byteLength ||
          result['ciphertext'] is! String ||
          (result['ciphertext'] as String).length > 1398102) {
        throw const FormatException('服务返回了无效的语音文件');
      }
      data = Uint8List.fromList(unb64(result['ciphertext'] as String));
      await _checkCiphertext(data, voice);
    }
    final clear = Uint8List.fromList(
      await _aes.decrypt(
        SecretBox(
          data.sublist(0, data.length - 16),
          nonce: unb64(voice.nonce),
          mac: Mac(data.sublist(data.length - 16)),
        ),
        secretKey: SecretKey(unb64(voice.key)),
        aad: utf8.encode(_aad(group, voice.mediaId)),
      ),
    );
    if (MediaWav.durationMs(clear) != voice.durationMs) {
      throw const FormatException('语音时长校验失败');
    }
    if (downloaded) {
      final verified = data;
      await _write(() async {
        _checkGroup(group, generation);
        await _atomic(await _file('cache', group, voice.mediaId), verified);
        await _trimCache();
      });
    }
    _checkGroup(group, generation);
    return clear;
  }

  /// Call only when a prepared attachment failed to enter the durable outbox.
  Future<void> discardPrepared(Group group, VoiceAttachment voice) =>
      _write(() async {
        final file = await _file('pending', group, voice.mediaId);
        if (await file.exists()) await file.delete();
      });

  /// Cleanup failure must not undo the already-stored chat message.
  Future<void> markMessageStored(Group group, VoiceAttachment voice) =>
      _write(() async {
        if (_deletedGroups.contains(group.storageId)) return;
        final file = await _file('pending', group, voice.mediaId);
        if (await file.exists()) {
          await file.rename((await _file('cache', group, voice.mediaId)).path);
        }
        await _trimCache();
      });

  Future<void> _trimCache() async {
    final files = <(File, FileStat)>[];
    var total = 0;
    await for (final file in (await _folder('cache')).list()) {
      if (file is File) {
        final stat = await file.stat();
        files.add((file, stat));
        total += stat.size;
      }
    }
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final entry in files) {
      if (total <= _budget) break;
      await entry.$1.delete();
      total -= entry.$2.size;
    }
  }
}
