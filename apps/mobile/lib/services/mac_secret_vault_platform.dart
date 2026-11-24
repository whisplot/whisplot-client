import 'dart:convert';
import 'package:flutter/services.dart';

/// The native bridge exposes only this app's single vault master key and legacy
/// item names. It never accepts arbitrary Keychain service/account arguments.
class MacSecretVaultPlatform {
  static const channel = MethodChannel('nearlink/mac_secret_vault');

  static List<int> _decodeMaster(Object? value) {
    if (value is! String) throw const FormatException('密钥库主密钥格式无效');
    final bytes = base64Decode(value);
    if (bytes.length != 32) throw const FormatException('密钥库主密钥长度无效');
    return bytes;
  }

  static Future<List<int>?> readMaster() async {
    final value = await channel.invokeMethod<Object?>('readMaster');
    return value == null ? null : _decodeMaster(value);
  }

  static Future<List<int>> createMaster() async =>
      _decodeMaster(await channel.invokeMethod<Object?>('createMaster'));

  static Future<List<String>> listLegacyKeys() async {
    final result = await channel.invokeMethod<Object?>('listLegacyKeys');
    if (result is! List || result.any((key) => key is! String || key.isEmpty)) {
      throw const FormatException('无法确认原密钥项目，已停止迁移');
    }
    // Appearance has its own non-secret file. Retired aliases must not become
    // part of the new vault; the current alias budget is already in SQLite.
    const excluded = {
      'mac-vault-master-v1',
      'mac-vault-master-v2',
      'mac-vault-master-v2-initialized',
      'appearance-v1',
      'display-name',
    };
    return result
        .cast<String>()
        .where((key) => !excluded.contains(key))
        .toSet()
        .toList()
      ..sort();
  }
}
