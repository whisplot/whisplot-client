import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A storage failure is never interpreted as permission to create a new identity.
class MacSecretVaultException implements Exception {
  const MacSecretVaultException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class MacVaultMigrationProgress {
  const MacVaultMigrationProgress({
    required this.completed,
    required this.total,
    required this.migrationComplete,
  });
  final int completed;
  final int total;
  final bool migrationComplete;
  int get remaining => total - completed;
}

/// One instance owns one vault. All keys share a single operation queue.
///
/// Only the random master key lives in Keychain. [saveEncrypted] must atomically
/// commit the encrypted snapshot and a durable initialized marker. The master
/// callbacks must distinguish item-not-found from denial, cancellation or error.
/// [createMaster] generates 32 random bytes natively, adds them without replacing
/// any existing item, verifies the stored bytes, and returns them. A duplicate
/// must throw; only an explicit [retryAccess] permits another read attempt.
///
/// Migration never deletes old items. After migration the old store is never
/// consulted, including for missing keys, so deletions cannot resurrect data.
class MacSecretVault {
  MacSecretVault({
    required this._loadEncrypted,
    required this._saveEncrypted,
    required this._readMaster,
    required this._createMaster,
    required this._listLegacyKeys,
    required this._readLegacy,
    required this._canInitialize,
    this.onProgress,
  });

  static const schemaVersion = 1;
  static const _maxEnvelopeCharacters = 16 * 1024 * 1024;
  static final _aad = utf8.encode('com.nearlink.chat/mac-secret-vault/v1');
  final Future<String?> Function() _loadEncrypted;
  final Future<void> Function(String) _saveEncrypted;
  final Future<List<int>?> Function() _readMaster;
  final Future<List<int>> Function() _createMaster;
  final Future<List<String>> Function() _listLegacyKeys;
  final Future<String?> Function(String) _readLegacy;
  final Future<bool> Function() _canInitialize;
  final void Function(MacVaultMigrationProgress)? onProgress;
  final _cipher = AesGcm.with256bits();
  Future<void> _tail = Future.value();
  SecretKeyData? _master;
  _VaultSnapshot? _snapshot;
  Object? _blocked;
  StackTrace? _blockedStack;
  bool _reloadRequired = true;
  bool _hasSeenVault = false;
  bool _closed = false;
  int _generation = 0;
  MacVaultMigrationProgress _progress = const MacVaultMigrationProgress(
    completed: 0,
    total: 0,
    migrationComplete: false,
  );

  MacVaultMigrationProgress get progress => _progress;
  bool get accessBlocked => _blocked != null;
  bool get isOpen =>
      !_closed &&
      !accessBlocked &&
      !_reloadRequired &&
      _snapshot?.migrationComplete == true;

  Future<void> open() => _enqueue(_ensureOpen);

  Future<String?> read(String key) => _enqueue((generation) async {
    await _ensureOpen(generation);
    _check(generation);
    return _snapshot!.secrets[key];
  });

  /// Enumerate only the current encrypted vault, never the legacy Keychain.
  /// Returning a copy keeps callers from changing the authoritative snapshot.
  Future<List<String>> keys() => _enqueue((generation) async {
    await _ensureOpen(generation);
    _check(generation);
    return _snapshot!.secrets.keys.toList(growable: false);
  });

  Future<void> write(String key, String value) => _enqueue((generation) async {
    _validateKey(key);
    await _ensureOpen(generation);
    _check(generation);
    if (_snapshot!.secrets[key] == value) return;
    final next = {..._snapshot!.secrets, key: value};
    await _commit(_snapshot!.withSecrets(next), generation);
  });

  Future<void> delete(String key) => _enqueue((generation) async {
    await _ensureOpen(generation);
    _check(generation);
    if (!_snapshot!.secrets.containsKey(key)) return;
    final next = {..._snapshot!.secrets}..remove(key);
    await _commit(_snapshot!.withSecrets(next), generation);
  });

  /// Clear only a latched failure, never grant OS permission or retry silently.
  void retryAccess() {
    _checkOpen();
    if (_blocked == null) return;
    _generation++;
    _blocked = null;
    _blockedStack = null;
  }

  /// Invalidate pending results, discard secrets, and wait for explicit retry.
  /// An OS prompt already in progress cannot be dismissed by this method.
  void cancelAccess() {
    _checkOpen();
    _generation++;
    _discardMemory();
    _blocked = const MacSecretVaultException('cancelled', '密钥库访问已取消，请手动重试。');
    _blockedStack = StackTrace.current;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _generation++;
    _discardMemory();
  }

  void _discardMemory() {
    _master?.destroy();
    _master = null;
    _snapshot = null;
    _reloadRequired = true;
  }

  void _checkOpen() {
    if (_closed) {
      throw const MacSecretVaultException('closed', '密钥库会话已结束。');
    }
  }

  void _check(int generation) {
    _checkOpen();
    if (generation != _generation) {
      throw const MacSecretVaultException('cancelled', '密钥库操作已取消，请手动重试。');
    }
  }

  Future<T> _enqueue<T>(Future<T> Function(int) action) {
    final generation = _generation;
    final operation = _tail.then((_) async {
      _check(generation);
      final blocked = _blocked;
      if (blocked != null) {
        Error.throwWithStackTrace(blocked, _blockedStack!);
      }
      try {
        final result = await action(generation);
        _check(generation);
        return result;
      } catch (error, stack) {
        // Cancellation may also make an in-flight crypto or storage operation
        // fail. Surface the ended session, not that incidental lower-level error.
        _check(generation);
        if (_blocked == null) {
          _blocked = error;
          _blockedStack = stack;
        }
        rethrow;
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> _ensureOpen(int generation) async {
    _check(generation);
    if (_snapshot == null || _reloadRequired) {
      final encrypted = await _loadEncrypted();
      _check(generation);
      if (encrypted == null) {
        if (_hasSeenVault) {
          throw const MacSecretVaultException(
            'vaultMissing',
            '原来的密钥库文件无法读取，已停止初始化以保护原身份。',
          );
        }
        final mayInitialize = await _canInitialize();
        _check(generation);
        if (!mayInitialize) {
          throw const MacSecretVaultException(
            'vaultMissing',
            '原来的密钥库文件无法读取，已停止初始化以保护原身份。',
          );
        }
        await _loadMaster(generation, allowCreate: true);
        _check(generation);
        final keys = await _listLegacyKeys();
        _check(generation);
        if (keys.toSet().length != keys.length) {
          throw const MacSecretVaultException(
            'invalidLegacyList',
            '旧密钥列表存在重复项目，已暂停迁移。',
          );
        }
        for (final key in keys) {
          _validateKey(key);
        }
        final remaining = [...keys]..sort();
        await _commit(
          _VaultSnapshot(
            secrets: {},
            remainingLegacyKeys: remaining,
            migrationComplete: remaining.isEmpty,
            migrationTotal: remaining.length,
          ),
          generation,
        );
      } else {
        _hasSeenVault = true;
        await _loadMaster(generation, allowCreate: false);
        _check(generation);
        final restored = await _decrypt(encrypted);
        _check(generation);
        _snapshot = restored;
        _reloadRequired = false;
        _notifyProgress(restored);
      }
    }
    while (true) {
      _check(generation);
      final current = _snapshot!;
      if (current.migrationComplete) return;
      final key = current.remainingLegacyKeys.first;
      final value = await _readLegacy(key);
      _check(generation);
      if (value == null) {
        throw const MacSecretVaultException(
          'legacyItemMissing',
          '迁移中的旧密钥项目无法读取，已暂停；原身份不会被替换。',
        );
      }
      final remaining = current.remainingLegacyKeys.skip(1).toList();
      await _commit(
        _VaultSnapshot(
          secrets: {...current.secrets, key: value},
          remainingLegacyKeys: remaining,
          migrationComplete: remaining.isEmpty,
          migrationTotal: current.migrationTotal,
        ),
        generation,
      );
    }
  }

  Future<void> _loadMaster(int generation, {required bool allowCreate}) async {
    if (_master != null) return;
    var bytes = await _readMaster();
    _check(generation);
    if (bytes == null) {
      if (!allowCreate) {
        throw const MacSecretVaultException(
          'masterMissing',
          '原密钥库的解锁密钥不存在，已停止初始化以保护原身份。',
        );
      }
      bytes = await _createMaster();
      _check(generation);
    }
    if (bytes.length != 32 || bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const MacSecretVaultException(
        'invalidMaster',
        '密钥库解锁密钥格式异常，已停止初始化。',
      );
    }
    _master = SecretKeyData(
      Uint8List.fromList(bytes),
      overwriteWhenDestroyed: true,
    );
  }

  Future<void> _commit(_VaultSnapshot next, int generation) async {
    _check(generation);
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(next.toJson())),
      secretKey: _master!,
      nonce: _cipher.newNonce(),
      aad: _aad,
    );
    _check(generation);
    final encrypted = jsonEncode({
      'v': schemaVersion,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
    if (encrypted.length > _maxEnvelopeCharacters) {
      throw const MacSecretVaultException('vaultTooLarge', '密钥库超过大小限制。');
    }
    try {
      await _saveEncrypted(encrypted);
    } catch (_) {
      // A failed commit may have reached disk. Reconcile from durable storage
      // on an explicit retry, retaining the already authorized master key.
      _reloadRequired = true;
      rethrow;
    }
    _check(generation);
    _hasSeenVault = true;
    _snapshot = next;
    _reloadRequired = false;
    _notifyProgress(next);
    _check(generation);
  }

  Future<_VaultSnapshot> _decrypt(String encoded) async {
    try {
      if (encoded.length > _maxEnvelopeCharacters) {
        throw const FormatException();
      }
      final envelope = jsonDecode(encoded);
      if (envelope is! Map<String, dynamic> ||
          !_exactKeys(envelope, {'v', 'nonce', 'ciphertext', 'mac'}) ||
          envelope['v'] is! int ||
          envelope['v'] != schemaVersion ||
          envelope['nonce'] is! String ||
          envelope['ciphertext'] is! String ||
          envelope['mac'] is! String) {
        throw const FormatException();
      }
      final nonce = base64Decode(envelope['nonce'] as String);
      final mac = base64Decode(envelope['mac'] as String);
      final ciphertext = base64Decode(envelope['ciphertext'] as String);
      if (nonce.length != 12 || mac.length != 16 || ciphertext.isEmpty) {
        throw const FormatException();
      }
      final plaintext = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: _master!,
        aad: _aad,
      );
      return _VaultSnapshot.fromJson(jsonDecode(utf8.decode(plaintext)));
    } on SecretBoxAuthenticationError {
      throw const MacSecretVaultException(
        'authenticationFailed',
        '密钥库完整性校验失败，已停止初始化；不会替换原身份。',
      );
    } on FormatException {
      throw const MacSecretVaultException(
        'invalidVault',
        '密钥库格式异常，已停止初始化；不会替换原身份。',
      );
    }
  }

  void _notifyProgress(_VaultSnapshot snapshot) {
    _progress = MacVaultMigrationProgress(
      completed: snapshot.migrationTotal - snapshot.remainingLegacyKeys.length,
      total: snapshot.migrationTotal,
      migrationComplete: snapshot.migrationComplete,
    );
    // A disposed UI observer must not turn a durable commit into a retry.
    try {
      onProgress?.call(_progress);
    } catch (_) {}
  }

  static void _validateKey(String key) {
    if (key.isEmpty || key.length > 4096) {
      throw const MacSecretVaultException('invalidKey', '密钥项目名称格式异常。');
    }
  }

  static bool _exactKeys(Map<String, dynamic> value, Set<String> keys) =>
      value.length == keys.length && value.keys.every(keys.contains);
}

class _VaultSnapshot {
  _VaultSnapshot({
    required Map<String, String> secrets,
    required List<String> remainingLegacyKeys,
    required this.migrationComplete,
    required this.migrationTotal,
  }) : secrets = Map.unmodifiable(secrets),
       remainingLegacyKeys = List.unmodifiable(remainingLegacyKeys);

  factory _VaultSnapshot.fromJson(dynamic value) {
    if (value is! Map<String, dynamic> ||
        !MacSecretVault._exactKeys(value, {
          'schema',
          'secrets',
          'migrationComplete',
          'remainingLegacyKeys',
          'migrationTotal',
        }) ||
        value['schema'] is! int ||
        value['schema'] != MacSecretVault.schemaVersion ||
        value['secrets'] is! Map<String, dynamic> ||
        value['remainingLegacyKeys'] is! List ||
        value['migrationComplete'] is! bool ||
        value['migrationTotal'] is! int) {
      throw const FormatException();
    }
    final entries = value['secrets'] as Map<String, dynamic>;
    final remaining = value['remainingLegacyKeys'] as List;
    if (entries.values.any((entry) => entry is! String) ||
        entries.keys.any((key) => key.isEmpty || key.length > 4096) ||
        remaining.any(
          (key) => key is! String || key.isEmpty || key.length > 4096,
        )) {
      throw const FormatException();
    }
    final remainingKeys = remaining.cast<String>();
    final total = value['migrationTotal'] as int;
    final complete = value['migrationComplete'] as bool;
    if (total < 0 ||
        remainingKeys.toSet().length != remainingKeys.length ||
        remainingKeys.any(entries.containsKey) ||
        complete != remainingKeys.isEmpty ||
        (!complete && entries.length + remainingKeys.length != total)) {
      throw const FormatException();
    }
    return _VaultSnapshot(
      secrets: entries.cast<String, String>(),
      remainingLegacyKeys: remainingKeys,
      migrationComplete: complete,
      migrationTotal: total,
    );
  }

  final Map<String, String> secrets;
  final List<String> remainingLegacyKeys;
  final bool migrationComplete;
  final int migrationTotal;

  _VaultSnapshot withSecrets(Map<String, String> next) => _VaultSnapshot(
    secrets: next,
    remainingLegacyKeys: remainingLegacyKeys,
    migrationComplete: migrationComplete,
    migrationTotal: migrationTotal,
  );

  Map<String, dynamic> toJson() => {
    'schema': MacSecretVault.schemaVersion,
    'secrets': secrets,
    'migrationComplete': migrationComplete,
    'remainingLegacyKeys': remainingLegacyKeys,
    'migrationTotal': migrationTotal,
  };
}
