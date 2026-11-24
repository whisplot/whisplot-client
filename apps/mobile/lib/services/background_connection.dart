import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

abstract interface class BackgroundConnectionPlatform {
  Stream<Map<String, dynamic>> get changes;
  Future<Map<String, dynamic>> state();
  Future<Map<String, dynamic>> setEnabled(bool enabled);
  Future<void> dispose();
}

class NativeBackgroundConnectionPlatform
    implements BackgroundConnectionPlatform {
  static const _channel = MethodChannel('nearlink/background_connection');
  final _changes = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  bool _attached = false;

  void _attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed' && call.arguments is Map) {
        _changes.add(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }

  @override
  Stream<Map<String, dynamic>> get changes {
    _attach();
    return _changes.stream;
  }

  Future<Map<String, dynamic>> _invoke(
    String method, [
    Object? arguments,
  ]) async {
    _attach();
    return await _channel.invokeMapMethod<String, dynamic>(method, arguments) ??
        <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> state() => _invoke('state');
  @override
  Future<Map<String, dynamic>> setEnabled(bool enabled) =>
      _invoke('setEnabled', {'enabled': enabled});
  @override
  Future<void> dispose() async {
    if (_attached) _channel.setMethodCallHandler(null);
    await _changes.close();
  }
}

/// Android's visible foreground service supports the existing Flutter process.
/// This does not create another engine, bypass Doze, or restart a stopped app.
/// `running` reports the service, never connectivity or a guaranteed presence.
class BackgroundConnectionService {
  BackgroundConnectionService({
    BackgroundConnectionPlatform? platform,
    bool? platformSupported,
    this.operationTimeout = const Duration(seconds: 8),
  }) : supported =
           platformSupported ?? (platform != null || Platform.isAndroid),
       _platform = platform ?? NativeBackgroundConnectionPlatform();

  final BackgroundConnectionPlatform _platform;
  final bool supported;
  final Duration operationTimeout;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Future<void>? _starting;
  bool _disposed = false;
  bool _wanted = false;
  int _generation = 0;
  bool running = false;
  String status = '后台连接未开启';
  void Function()? onChanged;
  bool get available => supported;

  void _listen() {
    _subscription ??= _platform.changes.listen((state) {
      if (!_disposed && (_wanted || state['running'] != true)) _apply(state);
    });
  }

  void _apply(Map<String, dynamic> state) {
    if (state['available'] is! bool || state['running'] is! bool) {
      running = false;
      status = '后台连接暂不可用';
    } else {
      running = state['available'] == true && state['running'] == true;
      status = running ? '后台连接已开启' : '后台连接未开启';
    }
    if (!_disposed) onChanged?.call();
  }

  /// Invoke while the app is resumed. Android rejects a new foreground service
  /// launched from the background; an already-running one continues on lock.
  Future<void> start() {
    if (!supported || _disposed || running) return Future<void>.value();
    _wanted = true;
    final pending = _starting;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _start().whenComplete(() {
      if (identical(_starting, operation)) _starting = null;
    });
    _starting = operation;
    return operation;
  }

  Future<void> _start() async {
    _listen();
    final generation = _generation;
    try {
      final state = await _platform.setEnabled(true).timeout(operationTimeout);
      if (!_disposed && generation == _generation) _apply(state);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      running = false;
      status = '系统暂未允许后台连接';
      onChanged?.call();
    }
  }

  Future<void> refresh() async {
    if (!supported || _disposed) return;
    _listen();
    final generation = _generation;
    try {
      final state = await _platform.state().timeout(operationTimeout);
      if (!_disposed && generation == _generation) _apply(state);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      running = false;
      status = '后台连接暂不可用';
      onChanged?.call();
    }
  }

  Future<void> stop() async {
    if (!supported || _disposed) return;
    _generation++;
    _wanted = false;
    _starting = null;
    running = false;
    status = '后台连接未开启';
    onChanged?.call();
    try {
      await _platform.setEnabled(false).timeout(operationTimeout);
    } catch (_) {
      // Engine cleanup also stops the native service. Never restart it here.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _wanted = false;
    _generation++;
    running = false;
    await _subscription?.cancel();
    if (supported) {
      try {
        await _platform.setEnabled(false).timeout(operationTimeout);
      } catch (_) {}
    }
    await _platform.dispose();
  }
}
