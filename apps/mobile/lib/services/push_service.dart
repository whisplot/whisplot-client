import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'secure_storage.dart';

@pragma('vm:entry-point')
Future<void> nearlinkBackgroundMessage(RemoteMessage message) async {
  // The OS displays a generic notification; no group key enters this isolate.
  try {
    await Firebase.initializeApp().timeout(const Duration(seconds: 10));
  } catch (_) {
    // A notification is only a hint. Opening the app always retries sync.
  }
}

/// Adapter for testing permission, timeout and opt-out without credentials.
class PushHint {
  const PushHint(this.groupId, {this.opened = false});
  final String groupId;
  final bool opened;
}

abstract interface class PushPlatform {
  bool get isIOS;
  Future<void> initialize();
  Future<AuthorizationStatus> requestPermission();
  Future<String?> apnsToken();
  Future<String?> token();
  Stream<String> get tokenChanges;
  Stream<PushHint> get foregroundMessages;
  Stream<PushHint> get openedMessages;
  Future<PushHint?> initialMessage();
}

class FirebasePushPlatform implements PushPlatform {
  @override
  bool get isIOS => Platform.isIOS;

  @override
  Future<void> initialize() async {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(nearlinkBackgroundMessage);
  }

  @override
  Future<AuthorizationStatus> requestPermission() async =>
      (await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      )).authorizationStatus;

  @override
  Future<String?> apnsToken() => FirebaseMessaging.instance.getAPNSToken();

  @override
  // The Worker uses HTTP v1 registration tokens. Moving to FIDs requires a
  // coordinated protocol migration, not only changing this client method.
  // ignore: deprecated_member_use
  Future<String?> token() => FirebaseMessaging.instance.getToken();

  @override
  // See token(): keep token refresh aligned with the existing server payload.
  // ignore: deprecated_member_use
  Stream<String> get tokenChanges => FirebaseMessaging.instance.onTokenRefresh;

  @override
  Stream<PushHint> get foregroundMessages =>
      FirebaseMessaging.onMessage.map((message) => _hint(message));

  @override
  Stream<PushHint> get openedMessages => FirebaseMessaging.onMessageOpenedApp
      .map((message) => _hint(message, opened: true));

  @override
  Future<PushHint?> initialMessage() async {
    final message = await FirebaseMessaging.instance.getInitialMessage();
    return message == null ? null : _hint(message, opened: true);
  }

  PushHint _hint(RemoteMessage message, {bool opened = false}) {
    final groupId = message.data['groupId'];
    return PushHint(
      groupId is String && groupId.length <= 128 ? groupId : '',
      opened: opened,
    );
  }
}

class PushService {
  PushService({
    PushPlatform? platform,
    FlutterSecureStorage? storage,
    Future<String?> Function(String)? readPreference,
    Future<void> Function(String, String)? writePreference,
    bool? platformSupported,
    this.operationTimeout = const Duration(seconds: 10),
  }) : _platform = platform ?? FirebasePushPlatform(),
       supported =
           platformSupported ??
           (platform != null || Platform.isIOS || Platform.isAndroid),
       _read =
           readPreference ??
           ((key) => (storage ?? appSecureStorage).read(key: key)),
       _write =
           writePreference ??
           ((key, value) =>
               (storage ?? appSecureStorage).write(key: key, value: value));

  final PushPlatform _platform;
  final bool supported;
  final Future<String?> Function(String) _read;
  final Future<void> Function(String, String) _write;
  final Duration operationTimeout;
  bool configured = false;
  bool _enabled = false;
  bool _disposed = false;
  int _intentVersion = 0;
  String status = '推送尚未配置';
  ApiClient? _api;
  Future<void>? _initializing;
  Future<void> _tail = Future<void>.value();
  StreamSubscription<String>? _tokens;
  StreamSubscription<PushHint>? _foreground, _opened;
  Future<void> Function()? onMessage;
  Future<void> Function(String groupId, bool opened)? _onGroupHint;
  PushHint? _pendingOpen;
  Future<void>? _opening;
  bool _initialMessageLoaded = false;
  Future<void>? _loadingInitialMessage;
  void Function()? onStatusChanged;

  set onGroupHint(Future<void> Function(String groupId, bool opened)? value) {
    _onGroupHint = value;
    unawaited(_drainOpened());
  }

  bool get enabled => _enabled;
  ApiClient? get api => _api;
  set api(ApiClient? value) {
    if (identical(_api, value)) return;
    _api = value;
    _intentVersion++;
    _enabled = false;
    if (!_disposed && supported) unawaited(retryRegistration());
  }

  String _preferenceKey(ApiClient client, String suffix) =>
      'push:$suffix:${base64Url.encode(utf8.encode(client.server))}';

  Future<bool> _wanted(ApiClient client) async =>
      await _read(
        _preferenceKey(client, 'enabled'),
      ).timeout(operationTimeout) ==
      'true';

  bool _current(ApiClient client) => !_disposed && identical(client, _api);

  void _status(String value) {
    if (_disposed) return;
    status = value;
    onStatusChanged?.call();
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (!supported) {
      _status('Mac 版暂不提供系统推送；保持应用运行可同步，退出后重开补收');
      return;
    }
    try {
      await _platform.initialize().timeout(operationTimeout);
      if (_disposed) return;
      configured = true;
      _status('推送已配置，尚未启用');
      _tokens = _platform.tokenChanges.listen((token) {
        final client = _api;
        if (client == null || _disposed) return;
        unawaited(
          _serial(() async {
            if (!_current(client) || !await _wanted(client)) return;
            await _register(client, token);
          }).catchError((Object _) {
            if (_current(client)) _status('推送登记失败，恢复连接后会重试');
          }),
        );
      }, onError: (Object _) => _status('推送令牌暂不可用，打开 App 仍可同步'));
      _foreground = _platform.foregroundMessages.listen(_messageHint);
      _opened = _platform.openedMessages.listen(
        (hint) => _messageHint(PushHint(hint.groupId, opened: true)),
      );
      await _loadInitialMessage();
      unawaited(retryRegistration());
    } catch (_) {
      configured = false;
      _status('此构建未配置 Firebase 或推送初始化超时，打开 App 后仍可同步');
    }
  }

  Future<void> _loadInitialMessage() {
    if (_disposed || !configured || _initialMessageLoaded) {
      return Future<void>.value();
    }
    return _loadingInitialMessage ??= _readInitialMessage().whenComplete(
      () => _loadingInitialMessage = null,
    );
  }

  Future<void> _readInitialMessage() async {
    try {
      final hint = await _platform.initialMessage().timeout(operationTimeout);
      _initialMessageLoaded = true;
      if (hint != null) {
        _messageHint(PushHint(hint.groupId, opened: true));
      }
    } catch (_) {
      // A timeout must not disable token registration; retry on reconnect.
    }
  }

  void _messageHint(PushHint hint) {
    if (_disposed) return;
    if (hint.groupId.isNotEmpty && hint.opened) {
      _pendingOpen = hint;
      unawaited(_drainOpened());
      return;
    }
    final groupHandler = _onGroupHint;
    if (hint.groupId.isNotEmpty && _api != null && groupHandler != null) {
      unawaited(groupHandler(hint.groupId, false).catchError((Object _) {}));
      return;
    }
    final handler = onMessage;
    if (handler == null) return;
    unawaited(
      handler().catchError((Object _) {
        // Normal chat reconnect handles failed synchronization.
      }),
    );
  }

  Future<void> _drainOpened() {
    if (_disposed ||
        _api == null ||
        _onGroupHint == null ||
        _pendingOpen == null) {
      return Future<void>.value();
    }
    return _opening ??= _openPending().whenComplete(() => _opening = null);
  }

  Future<void> _openPending() async {
    while (!_disposed && _api != null && _onGroupHint != null) {
      final hint = _pendingOpen;
      if (hint == null) return;
      _pendingOpen = null;
      try {
        await _onGroupHint!(hint.groupId, true);
      } catch (_) {
        _pendingOpen ??= hint;
        return;
      }
    }
  }

  Future<void> enable() {
    if (!supported) {
      return Future.error(const ApiException('Mac 版暂不提供系统推送'));
    }
    final client = _api;
    final version = ++_intentVersion;
    if (client == null) {
      return Future.error(const ApiException('请先连接聊天服务'));
    }
    return _serial(() async {
      if (!configured) {
        throw const ApiException('此构建尚未配置 Firebase/APNs；请先添加客户端配置');
      }
      final permission = await _platform.requestPermission().timeout(
        operationTimeout,
      );
      if (!_current(client) || version != _intentVersion) return;
      if (permission != AuthorizationStatus.authorized &&
          permission != AuthorizationStatus.provisional) {
        _enabled = false;
        await _write(
          _preferenceKey(client, 'enabled'),
          'false',
        ).timeout(operationTimeout);
        _status('系统通知未授权');
        return;
      }
      await _write(
        _preferenceKey(client, 'enabled'),
        'true',
      ).timeout(operationTimeout);
      if (!_current(client) || version != _intentVersion) return;
      _enabled = true;
      await _tryRegistration(client);
    });
  }

  /// Retry after chat registration and on resume without asking for permission
  /// or opting a disabled backend back in.
  Future<void> retryRegistration() => _serial(() async {
    if (!supported) return;
    final client = _api;
    if (client == null || _disposed) return;
    await _loadInitialMessage();
    await _drainOpened();
    try {
      final wanted = await _wanted(client);
      if (!_current(client)) return;
      _enabled = wanted;
      if (!wanted) {
        final cleanup = await _read(
          _preferenceKey(client, 'cleanup'),
        ).timeout(operationTimeout);
        if (cleanup == 'true') await _unregister(client);
        if (_current(client) && configured) _status('当前服务的推送已关闭');
        return;
      }
      if (configured) await _tryRegistration(client);
    } catch (_) {
      if (_current(client)) _status('推送登记暂不可用，恢复连接后会重试');
    }
  });

  Future<void> _tryRegistration(ApiClient client) async {
    if (!_current(client) || !await _wanted(client)) return;
    if (_platform.isIOS &&
        await _platform.apnsToken().timeout(operationTimeout) == null) {
      if (_current(client)) _status('等待 Apple 推送令牌，下次恢复前台时重试');
      return;
    }
    final token = await _platform.token().timeout(operationTimeout);
    if (!_current(client) || !await _wanted(client)) return;
    if (token == null || token.isEmpty) {
      _status('暂未取得推送令牌，下次恢复前台时重试');
      return;
    }
    await _register(client, token);
  }

  Future<void> _register(ApiClient client, String token) async {
    if (!_current(client) || !await _wanted(client)) return;
    final result = await client
        .request('POST', '/v1/devices/push', {
          'provider': 'fcm',
          'token': token,
          'platform': _platform.isIOS ? 'ios' : 'android',
        })
        .timeout(operationTimeout);
    if (!_current(client)) return;
    if (result['configured'] != true) {
      _status('设备已登记，但后端尚未配置推送凭证');
    } else {
      _status('推送已登记；是否送达仍受系统与网络影响');
    }
  }

  Future<void> disable() {
    if (!supported) return Future<void>.value();
    final client = _api;
    ++_intentVersion;
    _enabled = false;
    _status('正在关闭当前服务的推送');
    if (client == null) return Future<void>.value();
    return _serial(() async {
      // Persist the opt-out before networking; token refresh cannot undo it.
      await _write(
        _preferenceKey(client, 'enabled'),
        'false',
      ).timeout(operationTimeout);
      await _write(
        _preferenceKey(client, 'cleanup'),
        'true',
      ).timeout(operationTimeout);
      try {
        await _unregister(client);
        if (_current(client)) _status('已关闭当前服务的推送登记');
      } catch (_) {
        if (_current(client)) {
          _status('本机已关闭推送；联网后会撤销后端登记');
        }
      }
    });
  }

  Future<void> _unregister(ApiClient client) async {
    await client
        .request('DELETE', '/v1/devices/push')
        .timeout(operationTimeout);
    await _write(
      _preferenceKey(client, 'cleanup'),
      'false',
    ).timeout(operationTimeout);
  }

  Future<void> dispose() async {
    _disposed = true;
    _intentVersion++;
    await _tokens?.cancel();
    await _foreground?.cancel();
    await _opened?.cancel();
  }
}
