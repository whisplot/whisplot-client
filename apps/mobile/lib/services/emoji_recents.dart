import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/emoji_catalog.dart';

/// Only a small ordered list of emoji is stored locally: no timestamps, group
/// IDs, sender IDs or search terms. This cosmetic preference never uses Keychain.
class EmojiRecents {
  EmojiRecents({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? _readFile,
       _write = write ?? _writeFile;

  static final instance = EmojiRecents();
  static const limit = 24;
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  List<String> _values = const [];
  List<String> get values => List.unmodifiable(_values);
  Future<void>? _loading;
  Future<void> _writes = Future.value();

  static Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}/emoji-recents-v1.json',
  );

  static Future<String?> _readFile() async {
    final file = await _file();
    if (!await file.exists() || await file.length() > 16384) return null;
    return file.readAsString();
  }

  static Future<void> _writeFile(String value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    await temporary.rename(file.path);
  }

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await _read();
      if (raw == null || raw.length > 16384) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _values = decoded
          .whereType<String>()
          .where(EmojiCatalog.contains)
          .toSet()
          .take(limit)
          .toList(growable: false);
    } catch (_) {
      // A missing or malformed preference must never block the picker.
    }
  }

  Future<void> remember(String emoji) {
    if (!EmojiCatalog.contains(emoji)) return Future.value();
    final operation = _writes.then((_) async {
      await load();
      _values = [
        emoji,
        ..._values.where((value) => value != emoji),
      ].take(limit).toList(growable: false);
      try {
        await _write(jsonEncode(_values));
      } catch (_) {
        // Retain the in-memory list when storage is temporarily unavailable.
      }
    });
    _writes = operation;
    return operation;
  }
}
