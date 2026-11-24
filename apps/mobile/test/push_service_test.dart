import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/push_service.dart';

class FakePushPlatform implements PushPlatform {
  @override
  bool isIOS = false;
  String? apns = 'apns-token';
  String? fcm = 'fcm-token';
  bool hangToken = false;
  bool hangInitialization = false;
  int tokenRequests = 0;
  AuthorizationStatus permission = AuthorizationStatus.authorized;
  Completer<AuthorizationStatus>? permissionPrompt;
  PushHint? initial;
  Completer<PushHint?>? initialReply;
  int initialRequests = 0;
  final refresh = StreamController<String>.broadcast(sync: true);
  final foreground = StreamController<PushHint>.broadcast(sync: true);
  final opened = StreamController<PushHint>.broadcast(sync: true);

  @override
  Future<void> initialize() =>
      hangInitialization ? Completer<void>().future : Future<void>.value();
  @override
  Future<AuthorizationStatus> requestPermission() =>
      permissionPrompt?.future ?? Future.value(permission);
  @override
  Future<String?> apnsToken() async => apns;
  @override
  Future<String?> token() {
    tokenRequests++;
    return hangToken ? Completer<String?>().future : Future.value(fcm);
  }

  @override
  Stream<String> get tokenChanges => refresh.stream;
  @override
  Stream<PushHint> get foregroundMessages => foreground.stream;
  @override
  Stream<PushHint> get openedMessages => opened.stream;
  @override
  Future<PushHint?> initialMessage() {
    initialRequests++;
    return initialReply?.future ?? Future.value(initial);
  }

  Future<void> dispose() async {
    await refresh.close();
    await foreground.close();
    await opened.close();
  }
}

class FakePushApi extends ApiClient {
  FakePushApi([String server = 'https://one.example'])
    : super(
        server: server,
        identity: const Identity(seed: [], publicKey: 'test', id: 'test'),
        crypto: CryptoService(),
      );
  bool backendConfigured = true;
  bool failDelete = false;
  final List<String> methods = [];
  int get registrations => methods.where((method) => method == 'POST').length;
  int get deletions => methods.where((method) => method == 'DELETE').length;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    expect(path, '/v1/devices/push');
    methods.add(method);
    if (method == 'DELETE' && failDelete) {
      throw const ApiException('offline');
    }
    return {'ok': true, 'configured': backendConfigured};
  }
}

void main() {
  late FakePushPlatform platform;
  late FakePushApi api;
  late Map<String, String> preferences;
  late PushService service;

  PushService newService(FakePushPlatform p) => PushService(
    platform: p,
    operationTimeout: const Duration(milliseconds: 30),
    readPreference: (key) async => preferences[key],
    writePreference: (key, value) async {
      preferences[key] = value;
    },
  );

  setUp(() {
    platform = FakePushPlatform();
    api = FakePushApi();
    preferences = {};
    service = newService(platform)..api = api;
  });

  tearDown(() async {
    await service.dispose();
    await platform.dispose();
    api.close();
  });

  test('token refresh never opts a new backend in', () async {
    await service.initialize();
    platform.refresh.add('refreshed');
    await service.retryRegistration();
    expect(api.registrations, 0);
    expect(service.enabled, isFalse);
  });

  test(
    'foreground group B hint does not request navigation; tap does',
    () async {
      final hints = <(String, bool)>[];
      service.onGroupHint = (groupId, opened) async {
        hints.add((groupId, opened));
      };
      await service.initialize();
      platform.foreground.add(const PushHint('group-b'));
      platform.opened.add(const PushHint('group-b'));
      await service.retryRegistration();
      expect(hints, [('group-b', false), ('group-b', true)]);
      expect(api.registrations, 0);
    },
  );

  test(
    'cold-start notification waits for backend and handler then opens once',
    () async {
      service.api = null;
      platform.initial = const PushHint('group-b');
      final hints = <(String, bool)>[];
      await service.initialize();
      service.onGroupHint = (groupId, opened) async {
        hints.add((groupId, opened));
      };
      expect(hints, isEmpty);
      service.api = api;
      await service.retryRegistration();
      await service.retryRegistration();
      expect(hints, [('group-b', true)]);
    },
  );

  test('startup and reconnect share one initial notification read', () async {
    service.api = null;
    platform.initialReply = Completer<PushHint?>();
    final targets = <String>[];
    service.onGroupHint = (groupId, opened) async => targets.add(groupId);
    final initializing = service.initialize();
    await Future<void>.delayed(Duration.zero);
    service.api = api;
    final retrying = service.retryRegistration();
    await Future<void>.delayed(Duration.zero);
    expect(platform.initialRequests, 1);
    platform.initialReply!.complete(const PushHint('group-b'));
    await initializing;
    await retrying;
    expect(targets, ['group-b']);
  });

  test('notification target survives temporary controller failure', () async {
    var ready = false;
    final targets = <String>[];
    service.onGroupHint = (groupId, opened) async {
      if (!ready) throw const ApiException('group list not ready');
      targets.add(groupId);
    };
    await service.initialize();
    platform.opened.add(const PushHint('group-b'));
    await service.retryRegistration();
    expect(targets, isEmpty);
    ready = true;
    await service.retryRegistration();
    expect(targets, ['group-b']);
  });

  test(
    'opt-out survives token refresh, resume and a process restart',
    () async {
      await service.initialize();
      await service.enable();
      final initial = api.registrations;
      expect(initial, greaterThan(0));
      await service.disable();
      platform.refresh.add('refreshed-after-disable');
      await service.retryRegistration();
      expect(api.registrations, initial);
      expect(api.deletions, 1);
      expect(service.enabled, isFalse);

      final secondPlatform = FakePushPlatform();
      final restored = newService(secondPlatform)..api = api;
      await restored.initialize();
      secondPlatform.refresh.add('new-process-token');
      await restored.retryRegistration();
      expect(api.registrations, initial);
      expect(restored.enabled, isFalse);
      await restored.dispose();
      await secondPlatform.dispose();
    },
  );

  test('enabling one backend does not enable another', () async {
    await service.initialize();
    await service.enable();
    final second = FakePushApi('https://two.example');
    service.api = second;
    platform.refresh.add('same-device-token');
    await service.retryRegistration();
    expect(second.registrations, 0);
    expect(service.enabled, isFalse);
    service.api = api;
    await service.retryRegistration();
    expect(service.enabled, isTrue);
    expect(api.registrations, greaterThan(1));
    second.close();
  });

  test('missing backend credentials are not reported as usable push', () async {
    api.backendConfigured = false;
    await service.initialize();
    await service.enable();
    expect(service.status, contains('后端尚未配置'));
    expect(service.enabled, isTrue);
  });

  test(
    'iOS waits for APNs token and retries when it becomes available',
    () async {
      platform.isIOS = true;
      platform.apns = null;
      await service.initialize();
      await service.enable();
      expect(platform.tokenRequests, 0);
      expect(api.registrations, 0);
      expect(service.status, contains('等待 Apple'));
      platform.apns = 'apns-ready';
      await service.retryRegistration();
      expect(platform.tokenRequests, 1);
      expect(api.registrations, 1);
    },
  );

  test(
    'unresponsive token acquisition times out and preserves retry intent',
    () async {
      await service.initialize();
      platform.hangToken = true;
      await expectLater(service.enable(), throwsA(isA<TimeoutException>()));
      expect(service.enabled, isTrue);
      expect(api.registrations, 0);
      platform.hangToken = false;
      await service.retryRegistration();
      expect(api.registrations, 1);
    },
  );

  test(
    'initialization timeout does not prevent the chat service from starting',
    () async {
      platform.hangInitialization = true;
      await service.initialize();
      expect(service.configured, isFalse);
      expect(service.status, contains('超时'));
      expect(api.registrations, 0);
    },
  );

  test(
    'disable while permission prompt is pending cancels the enable intent',
    () async {
      await service.initialize();
      platform.permissionPrompt = Completer<AuthorizationStatus>();
      final enabling = service.enable();
      await Future<void>.delayed(Duration.zero);
      final disabling = service.disable();
      platform.permissionPrompt!.complete(AuthorizationStatus.authorized);
      await enabling;
      await disabling;
      platform.refresh.add('token-after-cancel');
      await service.retryRegistration();
      expect(api.registrations, 0);
      expect(service.enabled, isFalse);
    },
  );

  test(
    'offline opt-out is persisted and unregister retried on reconnect',
    () async {
      await service.initialize();
      await service.enable();
      final initial = api.registrations;
      api.failDelete = true;
      await service.disable();
      expect(service.status, contains('联网后'));
      platform.refresh.add('token-after-offline-opt-out');
      api.failDelete = false;
      await service.retryRegistration();
      expect(api.registrations, initial);
      expect(api.deletions, 2);
      expect(service.enabled, isFalse);
    },
  );
}
