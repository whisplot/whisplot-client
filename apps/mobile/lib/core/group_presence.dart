import 'dart:async';

/// Ephemeral aggregate presence. No roster, identity or timestamp is persisted.
/// A monotonic lease keeps wall-clock changes from making old counts look live.
class GroupPresence {
  GroupPresence({int Function()? elapsedMilliseconds}) {
    final watch = Stopwatch()..start();
    _elapsedMilliseconds =
        elapsedMilliseconds ?? () => watch.elapsedMilliseconds;
  }

  late final int Function() _elapsedMilliseconds;
  final Map<String, _PresenceLease> _leases = {};
  Timer? _expiry;
  bool _disposed = false;
  void Function()? onChanged;
  int get now => _elapsedMilliseconds();

  int? countFor(String storageId) {
    final lease = _leases[storageId];
    return lease != null && lease.expiresAt > now ? lease.count : null;
  }

  /// The controller accepts only the newest request for the current network
  /// generation. Request time is deducted conservatively from the server TTL.
  void accept(
    Map<String, Map<String, dynamic>> summaries, {
    required int requestStartedAt,
    bool replace = true,
  }) {
    if (_disposed) return;
    final receivedAt = now;
    final elapsed = (receivedAt - requestStartedAt).clamp(0, 90000);
    if (replace) _leases.removeWhere((key, _) => !summaries.containsKey(key));
    for (final entry in summaries.entries) {
      final value = entry.value;
      final count = value['onlineCount'];
      final ttl = value['presenceTtlMs'];
      final observed = value['presenceObservedAt'];
      if (count is! int ||
          count < 0 ||
          count > 50 ||
          ttl is! int ||
          ttl <= 0 ||
          observed is! int ||
          observed <= 0) {
        // An older server has no presence fields: display unknown, never zero.
        _leases.remove(entry.key);
        continue;
      }
      final previous = _leases[entry.key];
      if (previous != null && observed <= previous.observedAt) continue;
      final lifetime = ttl.clamp(0, 90000) - elapsed;
      if (lifetime <= 0) {
        _leases.remove(entry.key);
      } else {
        _leases[entry.key] = _PresenceLease(
          count,
          observed,
          receivedAt + lifetime,
        );
      }
    }
    expire();
    onChanged?.call();
  }

  void remove(String storageId) {
    if (_disposed) return;
    if (_leases.remove(storageId) != null) onChanged?.call();
    _scheduleExpiry();
  }

  void clear() {
    _expiry?.cancel();
    _leases.clear();
    if (!_disposed) onChanged?.call();
  }

  void expire() {
    if (_disposed) return;
    final before = _leases.length;
    final current = now;
    _leases.removeWhere((_, lease) => lease.expiresAt <= current);
    _scheduleExpiry();
    if (_leases.length != before) onChanged?.call();
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    if (_disposed || _leases.isEmpty) return;
    final earliest = _leases.values
        .map((lease) => lease.expiresAt)
        .reduce((a, b) => a < b ? a : b);
    _expiry = Timer(
      Duration(milliseconds: (earliest - now).clamp(1, 90000)),
      expire,
    );
  }

  void dispose() {
    _disposed = true;
    _expiry?.cancel();
    _leases.clear();
    onChanged = null;
  }
}

class _PresenceLease {
  const _PresenceLease(this.count, this.observedAt, this.expiresAt);
  final int count, observedAt, expiresAt;
}
