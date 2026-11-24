import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'api_client.dart';

/// A read-only subscription. It never handles keys, message plaintext or peers.
/// Its authenticated handshake is renewed within fifteen minutes; pulse frames
/// only renew presence and obtain a summary on that already-authorized socket.
class GroupWatch {
  GroupWatch({
    required this.api,
    required this.groupId,
    required this.allowed,
    required this.now,
    required this.onState,
    required this.onUnavailable,
    this.interval = const Duration(seconds: 15),
    this.responseTimeout = const Duration(seconds: 10),
    this.retryBase = const Duration(seconds: 2),
  });

  final ApiClient api;
  final String groupId;
  final bool Function() allowed;
  final int Function() now;
  final Future<void> Function(Map<String, dynamic>, int) onState;
  final void Function(String?) onUnavailable;
  final Duration interval, responseTimeout, retryBase;
  WebSocket? _socket;
  Timer? _pulseTimer, _timeout, _renewal, _retry, _hint;
  int _generation = 0, _requestId = 0, _lastAccepted = -1;
  int _pendingId = -1, _pendingStarted = 0, _lastReceived = -1;
  int _lastSentAt = -3000;
  int _retryCount = 0, _deadline = 0;
  bool _stopped = false, _starting = false;
  Future<void> _states = Future.value();

  bool get healthy =>
      !_stopped &&
      allowed() &&
      _socket?.readyState == WebSocket.open &&
      _lastReceived >= 0 &&
      now() - _lastReceived <=
          interval.inMilliseconds + responseTimeout.inMilliseconds &&
      now() < _deadline;

  Future<void> start() async {
    if (_stopped || _starting || !allowed() || _socket != null) return;
    _starting = true;
    _retry?.cancel();
    final generation = _generation;
    final started = now();
    try {
      final socket = await api.watchSocket(groupId);
      if (_stopped || generation != _generation || !allowed()) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      _requestId = 0;
      _lastAccepted = -1;
      _pendingId = 0;
      _pendingStarted = started;
      _lastSentAt = started;
      _lastReceived = -1;
      _deadline = started + const Duration(minutes: 15).inMilliseconds;
      socket.pingInterval = interval;
      _waitForReply(socket, generation);
      socket.listen(
        (raw) => _event(socket, generation, raw),
        onDone: () => _lost(socket, generation),
        onError: (_) => _lost(socket, generation),
        cancelOnError: true,
      );
      _pulseTimer = Timer.periodic(interval, (_) => poll());
    } catch (_) {
      if (!_stopped && generation == _generation) {
        onUnavailable(null);
        _scheduleRetry();
      }
    } finally {
      _starting = false;
    }
  }

  void poll() {
    if (_stopped || !allowed()) {
      unawaited(stop());
      return;
    }
    final socket = _socket;
    if (socket == null || _pendingId >= 0) return;
    if (now() >= _deadline) {
      _lost(socket, _generation, immediate: true);
      return;
    }
    final delay = 3000 - (now() - _lastSentAt);
    if (delay > 0) {
      _hint ??= Timer(Duration(milliseconds: delay), () {
        _hint = null;
        poll();
      });
      return;
    }
    _pendingId = ++_requestId;
    _pendingStarted = now();
    _lastSentAt = _pendingStarted;
    try {
      socket.add(jsonEncode({'type': 'watch_poll', 'requestId': _pendingId}));
      _waitForReply(socket, _generation);
    } catch (_) {
      _lost(socket, _generation);
    }
  }

  void _waitForReply(WebSocket socket, int generation) {
    _timeout?.cancel();
    _timeout = Timer(responseTimeout, () => _lost(socket, generation));
  }

  void _event(WebSocket socket, int generation, dynamic raw) {
    if (_stopped ||
        generation != _generation ||
        !identical(_socket, socket) ||
        !allowed()) {
      return;
    }
    try {
      if (raw is! String || raw.length > 32768) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException();
      final type = value['type'];
      if (type == 'watch_changed') {
        // Collapse fanout bursts. Periodic pulses also recover missed hints.
        _hint ??= Timer(const Duration(milliseconds: 250), () {
          _hint = null;
          poll();
        });
        return;
      }
      if (type != 'watch_state') {
        if (type == 'client_upgrade_required') {
          const error = UpgradeRequiredException();
          api.blockParticipation(error);
          api.onUpgradeRequired?.call(error);
        }
        _lost(socket, generation, reason: type is String ? type : null);
        return;
      }
      final id = value['requestId'];
      final group = value['group'];
      final expiresAt = value['expiresAt'];
      if (id is! int ||
          id != _pendingId ||
          id <= _lastAccepted ||
          group is! Map<String, dynamic> ||
          group['groupId'] != groupId ||
          group['presenceObservedAt'] is! int ||
          expiresAt is! int) {
        return;
      }
      final sentAt = _pendingStarted;
      final lifetime = expiresAt - (group['presenceObservedAt'] as int);
      // Server clock offsets do not extend the lease. Use the monotonic send
      // time, deduct request time, and never extend the original authorization.
      _deadline = min(_deadline, sentAt + lifetime.clamp(0, 900000));
      if (now() >= _deadline) {
        _lost(socket, generation, immediate: true);
        return;
      }
      _lastAccepted = id;
      _pendingId = -1;
      _lastReceived = now();
      _retryCount = 0;
      _timeout?.cancel();
      _renewal?.cancel();
      _renewal = Timer(
        Duration(milliseconds: max(1, _deadline - now() - 5000)),
        () => _lost(socket, generation, immediate: true),
      );
      _states = _states
          .then((_) async {
            if (_stopped || generation != _generation || !allowed()) return;
            await onState(group, sentAt);
          })
          .catchError((Object _) {
            _lost(socket, generation);
          });
    } catch (_) {
      _lost(socket, generation);
    }
  }

  void _lost(
    WebSocket socket,
    int generation, {
    String? reason,
    bool immediate = false,
  }) {
    if (_stopped || generation != _generation || !identical(_socket, socket)) {
      return;
    }
    _generation++;
    _socket = null;
    _lastReceived = -1;
    _pendingId = -1;
    _pulseTimer?.cancel();
    _timeout?.cancel();
    _renewal?.cancel();
    _hint?.cancel();
    _hint = null;
    unawaited(socket.close().catchError((Object _) {}));
    onUnavailable(reason);
    _scheduleRetry(immediate: immediate);
  }

  void _scheduleRetry({bool immediate = false}) {
    if (_stopped || !allowed()) return;
    _retry?.cancel();
    final milliseconds = max(
      api.quotaRetryAfter.inMilliseconds,
      immediate
          ? 1
          : min(
              300000,
              retryBase.inMilliseconds * (1 << min(_retryCount++, 8)),
            ),
    );
    _retry = Timer(Duration(milliseconds: milliseconds), () {
      unawaited(start());
    });
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _generation++;
    _pulseTimer?.cancel();
    _timeout?.cancel();
    _renewal?.cancel();
    _retry?.cancel();
    _hint?.cancel();
    final socket = _socket;
    _socket = null;
    _lastReceived = -1;
    if (socket != null) {
      unawaited(socket.close().catchError((Object _) {}));
    }
  }
}
