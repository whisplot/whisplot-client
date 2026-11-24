import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

abstract interface class MessageNotificationPlatform {
  Stream<String> get opened;
  Future<Map<String, dynamic>> state();
  Future<Map<String, dynamic>> setEnabled(bool enabled);
  Future<void> openSettings();
  Future<void> show({
    required String token,
    required int count,
    required int badge,
    required bool sound,
  });
  Future<void> clear(String token, int badge);
  Future<void> clearAll();
  Future<void> dispose();
}

class NativeMessageNotificationPlatform implements MessageNotificationPlatform {
  bool _attached = false;
  void _attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened' && call.arguments is String) {
        final token = call.arguments as String;
        if (RegExp(r'^[A-Za-z0-9_-]{24}$').hasMatch(token)) {
          _opened.add(token);
        }
      }
    });
  }

  static const _channel = MethodChannel('nearlink/message_notifications');
  final _opened = StreamController<String>.broadcast(sync: true);
  @override
  Stream<String> get opened => _opened.stream;

  Future<Map<String, dynamic>> _settings(String method, [Object? args]) async {
    _attach();
    final value = await _channel.invokeMapMethod<String, dynamic>(method, args);
    if (value == null ||
        value['enabled'] is! bool ||
        value['granted'] is! bool ||
        value['prompted'] is! bool) {
      throw const FormatException('无法确认系统通知权限');
    }
    return value;
  }

  @override
  Future<Map<String, dynamic>> state() => _settings('state');
  @override
  Future<Map<String, dynamic>> setEnabled(bool enabled) =>
      _settings('setEnabled', {'enabled': enabled});
  @override
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');
  @override
  Future<void> show({
    required String token,
    required int count,
    required int badge,
    required bool sound,
  }) => _channel.invokeMethod<void>('show', {
    'token': token,
    'count': count,
    'badge': badge,
    'sound': sound,
  });
  @override
  Future<void> clear(String token, int badge) =>
      _channel.invokeMethod<void>('clear', {'token': token, 'badge': badge});
  @override
  Future<void> clearAll() => _channel.invokeMethod<void>('clearAll');
  @override
  Future<void> dispose() async {
    if (_attached) _channel.setMethodCallHandler(null);
    await _opened.close();
  }
}

/// Local reminders contain no sender, group name, message text, keys or IDs.
/// The OS receives an opaque per-session routing token only. Quitting the app
/// stops local reception; optional remote push is handled by PushService.
class MessageNotificationService {
  MessageNotificationService({
    MessageNotificationPlatform? platform,
    bool? platformSupported,
    bool? androidForegroundOnly,
    DateTime Function()? now,
    this.operationTimeout = const Duration(seconds: 10),
  }) : supported =
           platformSupported ??
           (platform != null ||
               Platform.isMacOS ||
               Platform.isAndroid ||
               Platform.isWindows),
       foregroundOnly = androidForegroundOnly ?? false,
       _platform = platform ?? NativeMessageNotificationPlatform(),
       _now = now ?? DateTime.now;

  final MessageNotificationPlatform _platform;
  final bool supported;

  /// Optional restriction for integrations without background networking.
  /// The app uses a foreground service on Android; this is still local
  /// reception while its process runs, not configured post-quit remote push.
  final bool foregroundOnly;
  final Duration operationTimeout;
  final DateTime Function() _now;
  final Set<String> _seen = {};
  final Map<String, Set<String>> _unread = {};
  final Map<String, String> _tokens = {};
  final Map<String, DateTime> _lastSound = {};
  final Map<String, int> _groupGenerations = {};
  int _generation = 0;
  StreamSubscription<String>? _opened;
  Future<void>? _initializing;
  Future<void> _tail = Future<void>.value();
  bool _disposed = false,
      _wanted = true,
      _prompted = false,
      _canRequest = true,
      _initialized = false;
  bool permissionGranted = false;
  String status = '未开启';
  void Function()? onStatusChanged;
  Future<void> Function(String groupStorageId)? onOpenGroup;
  bool get enabled => supported && _wanted && permissionGranted;
  bool get needsSystemSettings =>
      supported && _wanted && !permissionGranted && _prompted && !_canRequest;
  bool get showSystemSettings => needsSystemSettings || (supported && Platform.isWindows);
  int get unreadCount => _unread.values.fold(0, (sum, ids) => sum + ids.length);
  int unreadInGroup(String storageId) => _unread[storageId]?.length ?? 0;

  void _changed() {
    if (!_disposed) onStatusChanged?.call();
  }

  void _apply(Map<String, dynamic> state) {
    _wanted = state['enabled'] == true;
    _prompted = state['prompted'] == true;
    final canRequest = state['canRequest'];
    _canRequest = canRequest is bool ? canRequest : !_prompted;
    permissionGranted = state['granted'] == true;
    status = !_wanted
        ? '已关闭'
        : permissionGranted
        ? (foregroundOnly ? '前台提醒已开启' : '已开启')
        : _prompted && !_canRequest
        ? '系统未允许'
        : '未开启';
    _changed();
  }

  Future<void> initialize({bool requestPermissionIfNeeded = false}) =>
      _initializing ??= _initialize(requestPermissionIfNeeded);
  Future<void> _initialize(bool request) async {
    if (!supported || _disposed) return;
    _opened = _platform.opened.listen((token) {
      final group = _tokens.entries
          .where((e) => e.value == token)
          .firstOrNull
          ?.key;
      final open = onOpenGroup;
      if (group != null && open != null) {
        unawaited(open(group).catchError((Object _) {}));
      }
    });
    try {
      _apply(await _platform.state().timeout(operationTimeout));
      if (_disposed) return;
      _initialized = true;
      // Existing delivered notifications have no routing identity in this new
      // process. Clear those stale hints rather than presenting stale counts.
      await _platform.clearAll().timeout(operationTimeout);
      if (request && _wanted && !_prompted) await _enable();
    } catch (_) {
      status = '提醒暂不可用';
      _changed();
    }
  }

  Future<void> enable() async {
    if (!supported || _disposed) return;
    await initialize();
    if (!_disposed) await _enable();
  }

  Future<void> _enable() async {
    try {
      _apply(
        await _platform.setEnabled(true).timeout(const Duration(minutes: 2)),
      );
    } catch (_) {
      status = '无法开启提醒';
      _changed();
    }
  }

  Future<void> disable() async {
    if (!supported || _disposed) return;
    await initialize();
    if (_disposed) return;
    _generation++;
    _wanted = false;
    _unread.clear();
    try {
      _apply(await _platform.setEnabled(false).timeout(operationTimeout));
      await _platform.clearAll().timeout(operationTimeout);
      _changed();
    } catch (_) {
      status = '无法修改提醒';
      _changed();
    }
  }

  Future<void> openSystemSettings() async {
    if (!supported || _disposed) return;
    try {
      await _platform.openSettings().timeout(operationTimeout);
    } catch (_) {
      status = '无法打开系统通知设置';
      _changed();
    }
  }

  Future<void> refreshPermission() async {
    if (!supported || _disposed || !_initialized) return;
    try {
      _apply(await _platform.state().timeout(operationTimeout));
    } catch (_) {
      /* A transient OS error must not interrupt chat. */
    }
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _tail.then((_) async {
      if (!_disposed) await action();
    });
    _tail = next.catchError((Object _) {});
    return _tail;
  }

  Future<void> notifyIncoming({
    required String groupStorageId,
    required String messageId,
    required bool shouldNotify,
    bool Function()? stillEligible,
  }) {
    // Capture at enqueue time. Opening/leaving a room invalidates queued work
    // synchronously, even before it has created an unread entry. Going back to
    // the home screen cannot make that stale work eligible again.
    final generation = _groupGenerations[groupStorageId] ?? 0;
    final serviceGeneration = _generation;
    return _serial(() async {
      final key = '$groupStorageId\u0000$messageId';
      if (!_seen.add(key)) return;
      if (_seen.length > 4096) _seen.remove(_seen.first);
      if (!shouldNotify ||
          !supported ||
          !enabled ||
          serviceGeneration != _generation ||
          generation != (_groupGenerations[groupStorageId] ?? 0) ||
          (stillEligible != null && !stillEligible())) {
        return;
      }
      _unread.putIfAbsent(groupStorageId, () => {}).add(messageId);
      final token = _tokens.putIfAbsent(groupStorageId, () {
        final random = Random.secure();
        return base64Url.encode(List.generate(18, (_) => random.nextInt(256)));
      });
      final now = _now();
      final previous = _lastSound[groupStorageId];
      final sound =
          previous == null ||
          now.difference(previous) >= const Duration(seconds: 3);
      if (sound) _lastSound[groupStorageId] = now;
      try {
        await _platform
            .show(
              token: token,
              count: unreadInGroup(groupStorageId),
              badge: unreadCount,
              sound: sound,
            )
            .timeout(operationTimeout);
      } catch (_) {
        status = '提醒暂不可用';
      }
      _changed();
    });
  }

  Future<void> clearGroup(String groupStorageId) {
    if (_disposed) return Future<void>.value();
    _groupGenerations[groupStorageId] =
        (_groupGenerations[groupStorageId] ?? 0) + 1;
    return _serial(() async {
      if (_unread.remove(groupStorageId) == null) return;
      final token = _tokens[groupStorageId];
      if (supported && token != null) {
        try {
          await _platform.clear(token, unreadCount).timeout(operationTimeout);
        } catch (_) {
          /* Local unread state is still cleared. */
        }
      }
      _changed();
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    _initialized = false;
    await _opened?.cancel();
    await _platform.dispose();
  }
}
