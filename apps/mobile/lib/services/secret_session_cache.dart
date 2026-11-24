import 'package:flutter/services.dart';

/// An authorization failure pauses new Keychain requests until an explicit retry.
/// This is never interpreted as a missing secret or permission to replace one.
class SecretAccessBlockedException implements Exception {
  const SecretAccessBlockedException(this.status);
  final int status;
  @override
  String toString() => '安全存储访问已暂停，请在系统中允许访问后点击重试。';
}

/// Session-only reuse of authorized values; no secrets are persisted here.
class SecretSessionCache {
  SecretSessionCache({
    required this.enabled,
    required this._read,
    required this._write,
    required this._delete,
  });

  final bool enabled;
  final Future<String?> Function(String) _read;
  final Future<void> Function(String, String) _write;
  final Future<void> Function(String) _delete;
  final _values = <String, String>{};
  final _pendingReads = <String, Future<String?>>{};
  Future<void> _tail = Future.value();
  SecretAccessBlockedException? _blocked;
  int _generation = 0;
  bool _closed = false;

  bool get accessBlocked => _blocked != null;

  /// Only a user-initiated retry should call this; it does not grant OS access.
  void retryAccess() => _blocked = null;

  /// In-flight results from the old session must not repopulate this cache.
  void clear() {
    _generation++;
    _values.clear();
    _pendingReads.clear();
  }

  void close() {
    _closed = true;
    clear();
  }

  StateError _ended() => StateError('安全存储会话已结束，操作已取消');

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final generation = _generation;
    final operation = _tail.then((_) {
      if (_closed || generation != _generation) throw _ended();
      return action();
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<T> _access<T>(Future<T> Function() action) async {
    final blocked = _blocked;
    if (blocked != null) throw blocked;
    try {
      return await action();
    } on PlatformException catch (error, stack) {
      if (error.code == 'Unexpected security result code' &&
          error.details is int &&
          const {-128, -25293, -25308, -25294}.contains(error.details)) {
        final blocked = SecretAccessBlockedException(error.details as int);
        _blocked = blocked;
        Error.throwWithStackTrace(blocked, stack);
      }
      rethrow;
    }
  }

  Future<String?> read(String key) {
    if (_closed) return Future.error(_ended());
    if (!enabled) return _read(key);
    final pending = _pendingReads[key];
    if (pending != null) return pending;
    final generation = _generation;
    final operation = _enqueue(() async {
      final cached = _values[key];
      if (cached != null) return cached;
      final value = await _access(() => _read(key));
      if (value != null && generation == _generation) _values[key] = value;
      return value;
    });
    _pendingReads[key] = operation;
    void forget() {
      if (identical(_pendingReads[key], operation)) _pendingReads.remove(key);
    }

    operation.then<void>(
      (_) => forget(),
      onError: (Object _, StackTrace _) => forget(),
    );
    return operation;
  }

  Future<void> write(String key, String value) {
    if (_closed) return Future.error(_ended());
    if (!enabled) return _write(key, value);
    // A later read belongs after this write, not to an older in-flight read.
    _pendingReads.remove(key);
    final generation = _generation;
    return _enqueue(() async {
      if (_values[key] == value) return;
      var attempted = false;
      try {
        await _access(() {
          attempted = true;
          return _write(key, value);
        });
      } catch (_) {
        // A failed platform write may have partially changed the stored item.
        if (attempted) _values.remove(key);
        rethrow;
      }
      if (generation == _generation) _values[key] = value;
    });
  }

  Future<void> delete(String key) {
    if (_closed) return Future.error(_ended());
    if (!enabled) return _delete(key);
    _pendingReads.remove(key);
    return _enqueue(() async {
      await _access(() => _delete(key));
      _values.remove(key);
    });
  }
}
