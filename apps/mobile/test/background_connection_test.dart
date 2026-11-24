import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/background_connection.dart';

class BackgroundPlatformFixture implements BackgroundConnectionPlatform {
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final requests = <bool>[];
  final pending = <Completer<Map<String, dynamic>>>[];
  bool holdStarts = false, failStart = false, disposed = false, active = false;
  int reads = 0;
  @override
  Stream<Map<String, dynamic>> get changes => events.stream;
  @override
  Future<Map<String, dynamic>> state() async {
    reads++;
    return {'available': true, 'running': active};
  }

  @override
  Future<Map<String, dynamic>> setEnabled(bool enabled) async {
    requests.add(enabled);
    if (enabled && failStart) {
      throw PlatformException(code: 'BACKGROUND_START_UNAVAILABLE');
    }
    if (enabled && holdStarts) {
      final operation = Completer<Map<String, dynamic>>();
      pending.add(operation);
      return operation.future;
    }
    active = enabled;
    return {'available': true, 'running': active};
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unsupported platform never calls native background methods', () async {
    final platform = BackgroundPlatformFixture();
    final service = BackgroundConnectionService(
      platform: platform,
      platformSupported: false,
    );
    await service.start();
    await service.refresh();
    await service.stop();
    expect(service.available, isFalse);
    expect(platform.requests, isEmpty);
    expect(platform.reads, 0);
    await service.dispose();
  });

  test(
    'concurrent starts share one native request and await actual service',
    () async {
      final platform = BackgroundPlatformFixture()..holdStarts = true;
      final service = BackgroundConnectionService(platform: platform);
      addTearDown(service.dispose);
      final first = service.start(), second = service.start();
      expect(service.running, isFalse);
      expect(platform.requests, [true]);
      platform.pending.single.complete({'available': true, 'running': true});
      await Future.wait([first, second]);
      expect(service.running, isTrue);
      expect(service.status, '后台连接已开启');
      await service.start();
      expect(platform.requests, [true]);
    },
  );

  test(
    'OS rejection is reported without retries or claimed background support',
    () async {
      final platform = BackgroundPlatformFixture()..failStart = true;
      final service = BackgroundConnectionService(platform: platform);
      addTearDown(service.dispose);
      await service.start();
      expect(service.running, isFalse);
      expect(service.status, '系统暂未允许后台连接');
      expect(platform.requests, [true]);
      platform.failStart = false;
      await service.start();
      expect(service.running, isTrue);
      expect(platform.requests, [true, true]);
    },
  );

  test(
    'native task removal updates state and never restarts the service',
    () async {
      final platform = BackgroundPlatformFixture();
      final service = BackgroundConnectionService(platform: platform);
      addTearDown(service.dispose);
      var changes = 0;
      service.onChanged = () => changes++;
      await service.start();
      platform.events.add({'available': true, 'running': false});
      expect(service.running, isFalse);
      expect(changes, 2);
      expect(platform.requests, [true]);
    },
  );

  test('stop invalidates a pending start and late running events', () async {
    final platform = BackgroundPlatformFixture()..holdStarts = true;
    final service = BackgroundConnectionService(platform: platform);
    addTearDown(service.dispose);
    final start = service.start();
    await service.stop();
    platform.pending.single.complete({'available': true, 'running': true});
    platform.events.add({'available': true, 'running': true});
    await start;
    expect(service.running, isFalse);
    expect(platform.requests, [true, false]);
  });

  test(
    'stop then start uses a new operation; old completion cannot overwrite it',
    () async {
      final platform = BackgroundPlatformFixture()..holdStarts = true;
      final service = BackgroundConnectionService(platform: platform);
      addTearDown(service.dispose);
      final oldStart = service.start();
      await service.stop();
      final newStart = service.start();
      expect(platform.requests, [true, false, true]);
      platform.pending[1].complete({'available': true, 'running': true});
      await newStart;
      platform.pending[0].complete({'available': true, 'running': false});
      await oldStart;
      expect(service.running, isTrue);
    },
  );

  test(
    'dispose stops pending native work and ignores completion without a new engine',
    () async {
      final platform = BackgroundPlatformFixture()..holdStarts = true;
      final service = BackgroundConnectionService(platform: platform);
      final start = service.start();
      await service.dispose();
      platform.pending.single.complete({'available': true, 'running': true});
      await start;
      await service.start();
      expect(service.running, isFalse);
      expect(platform.disposed, isTrue);
      expect(platform.requests, [true, false]);
    },
  );

  test(
    'refresh queries status only; malformed native state is never running',
    () async {
      final platform = BackgroundPlatformFixture();
      final service = BackgroundConnectionService(platform: platform);
      addTearDown(service.dispose);
      await service.refresh();
      expect(platform.requests, isEmpty);
      expect(platform.reads, 1);
      platform.events.add({'running': 'true'});
      expect(service.running, isFalse);
      expect(service.status, '后台连接暂不可用');
    },
  );

  test(
    'native channel sends only a boolean, never identities or connection data',
    () async {
      const channel = MethodChannel('nearlink/background_connection');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {
          'available': true,
          'running': call.arguments is Map && call.arguments['enabled'] == true,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final platform = NativeBackgroundConnectionPlatform();
      await platform.state();
      await platform.setEnabled(true);
      await platform.setEnabled(false);
      expect(calls.map((c) => c.method), ['state', 'setEnabled', 'setEnabled']);
      expect(calls.first.arguments, isNull);
      expect(calls[1].arguments, {'enabled': true});
      expect(calls[2].arguments, {'enabled': false});
      await platform.dispose();
    },
  );
}
