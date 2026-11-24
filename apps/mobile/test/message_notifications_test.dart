import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/message_notifications.dart';

class FakeNotifications implements MessageNotificationPlatform {
  final openedController = StreamController<String>.broadcast(sync: true);
  bool allowed = true, wanted = true, prompted = true, failShow = false;
  bool? canRequest;
  int requests = 0, clearedAll = 0, stateReads = 0, settingsOpened = 0;
  final shown = <Map<String, Object>>[];
  final cleared = <(String, int)>[];
  Completer<void>? showGate;
  Completer<void>? showStarted;
  @override
  Stream<String> get opened => openedController.stream;
  @override
  Future<Map<String, dynamic>> state() async {
    stateReads++;
    return {
      'enabled': wanted,
      'granted': allowed,
      'prompted': prompted,
      'canRequest': canRequest,
    };
  }

  @override
  Future<void> openSettings() async {
    settingsOpened++;
  }

  @override
  Future<Map<String, dynamic>> setEnabled(bool enabled) async {
    wanted = enabled;
    if (enabled) {
      requests++;
      prompted = true;
    }
    return state();
  }

  @override
  Future<void> show({
    required String token,
    required int count,
    required int badge,
    required bool sound,
  }) async {
    if (failShow) throw StateError('OS unavailable');
    shown.add({'token': token, 'count': count, 'badge': badge, 'sound': sound});
    final started = showStarted;
    if (started != null && !started.isCompleted) started.complete();
    await showGate?.future;
  }

  @override
  Future<void> clear(String token, int badge) async {
    cleared.add((token, badge));
  }

  @override
  Future<void> clearAll() async {
    clearedAll++;
  }

  @override
  Future<void> dispose() => openedController.close();
}

void main() {
  late FakeNotifications platform;
  late MessageNotificationService service;
  var now = DateTime.utc(2026, 11, 20);
  setUp(() {
    platform = FakeNotifications();
    service = MessageNotificationService(platform: platform, now: () => now);
  });
  tearDown(() => service.dispose());
  Future<void> message(
    String id, {
    String group = 'private-group@example',
    bool notify = true,
  }) => service.notifyIncoming(
    groupStorageId: group,
    messageId: id,
    shouldNotify: notify,
  );

  test('requests permission at first opt-in initialization only', () async {
    platform.prompted = false;
    await service.initialize(requestPermissionIfNeeded: true);
    await service.initialize(requestPermissionIfNeeded: true);
    expect(platform.requests, 1);
    expect(service.enabled, isTrue);
    expect(platform.clearedAll, 1);
  });

  test('lifecycle events before setup do not query OS permissions', () async {
    await service.refreshPermission();
    expect(platform.stateReads, 0);
    await service.initialize();
    await service.refreshPermission();
    expect(platform.stateReads, 2);
  });

  test('system denial can be repaired from notification settings', () async {
    platform.allowed = false;
    platform.canRequest = false;
    await service.initialize();
    expect(platform.requests, 0);
    expect(service.enabled, isFalse);
    expect(service.needsSystemSettings, isTrue);
    await service.openSystemSettings();
    expect(platform.settingsOpened, 1);
    platform.allowed = true;
    await service.refreshPermission();
    expect(service.enabled, isTrue);
    expect(service.needsSystemSettings, isFalse);
  });

  test('Android status does not claim background push is configured', () async {
    await service.dispose();
    platform = FakeNotifications();
    service = MessageNotificationService(
      platform: platform,
      androidForegroundOnly: true,
    );
    await service.initialize();
    expect(service.enabled, isTrue);
    expect(service.status, '前台提醒已开启');
    expect(service.foregroundOnly, isTrue);
  });

  test(
    'previous permission denial is not automatically requested again',
    () async {
      platform.allowed = false;
      await service.initialize(requestPermissionIfNeeded: true);
      expect(platform.requests, 0);
      expect(service.enabled, isFalse);
      await message('new');
      expect(platform.shown, isEmpty);
      await service.enable();
      expect(platform.requests, 1);
      expect(service.enabled, isFalse);
      expect(service.status, '系统未允许');
    },
  );

  test('suppressed and duplicate events never notify later', () async {
    await service.initialize();
    await message('visible', notify: false);
    await message('visible');
    await message('fresh');
    await message('fresh');
    expect(platform.shown, hasLength(1));
    expect(service.unreadCount, 1);
  });

  test(
    'native payload uses opaque route and counts without chat identifiers',
    () async {
      await service.initialize();
      await message('secret-message');
      final payload = platform.shown.single;
      expect(
        payload.keys,
        unorderedEquals(['token', 'count', 'badge', 'sound']),
      );
      expect(payload['token'], matches(r'^[A-Za-z0-9_-]{24}$'));
      expect(payload.toString(), isNot(contains('private-group')));
      expect(payload.toString(), isNot(contains('secret-message')));
      expect(payload['badge'], 1);
    },
  );

  test(
    'groups aggregate with stable routes and clearing one preserves another',
    () async {
      await service.initialize();
      await message('a');
      await message('b');
      await message('c', group: 'other');
      expect(platform.shown[0]['token'], platform.shown[1]['token']);
      expect(platform.shown[2]['token'], isNot(platform.shown[0]['token']));
      expect(service.unreadCount, 3);
      var changes = 0;
      service.onStatusChanged = () => changes++;
      await service.clearGroup('private-group@example');
      expect(service.unreadCount, 1);
      expect(platform.cleared.single.$2, 1);
      await service.clearGroup('private-group@example');
      expect(
        changes,
        1,
        reason: 'already-visible reports must not create UI loops',
      );
    },
  );

  test('notification click only opens its in-memory group route', () async {
    await service.initialize();
    await message('a');
    final opens = <String>[];
    service.onOpenGroup = (group) async {
      opens.add(group);
    };
    platform.openedController.add('unknown-token');
    platform.openedController.add(platform.shown.single['token'] as String);
    await Future<void>.delayed(Duration.zero);
    expect(opens, ['private-group@example']);
  });

  test('bursts are visually updated without repeated sounds', () async {
    await service.initialize();
    await message('a');
    await message('b');
    now = now.add(const Duration(seconds: 4));
    await message('c');
    expect(platform.shown.map((e) => e['sound']), [true, false, true]);
  });

  test('disable clears badges and does not enqueue later reminders', () async {
    await service.initialize();
    await message('a');
    await service.disable();
    await message('b');
    expect(service.enabled, isFalse);
    expect(service.unreadCount, 0);
    expect(platform.shown, hasLength(1));
    expect(platform.clearedAll, 2);
  });

  test('OS failure does not break incoming-message processing', () async {
    await service.initialize();
    platform.failShow = true;
    await message('a');
    expect(service.status, '提醒暂不可用');
    platform.failShow = false;
    await message('b');
    expect(platform.shown, hasLength(1));
    expect(service.unreadCount, 2);
  });

  for (final reason in ['opened', 'left']) {
    test(
      'queued reminder rechecks live eligibility after room is $reason',
      () async {
        await service.initialize();
        platform.showGate = Completer<void>();
        platform.showStarted = Completer<void>();
        final first = message('blocking', group: 'other-room');
        await platform.showStarted!.future;
        var eligible = true;
        final pending = service.notifyIncoming(
          groupStorageId: 'target-room',
          messageId: 'queued',
          shouldNotify: true,
          stillEligible: () => eligible,
        );
        eligible = false;
        platform.showGate!.complete();
        await Future.wait([first, pending]);
        expect(platform.shown, hasLength(1));
        expect(service.unreadInGroup('target-room'), 0);
      },
    );
  }

  test(
    'opening then leaving viewport cannot resurrect queued reminder',
    () async {
      await service.initialize();
      platform.showGate = Completer<void>();
      platform.showStarted = Completer<void>();
      final first = message('blocking', group: 'other-room');
      await platform.showStarted!.future;
      var visible = false;
      final pending = service.notifyIncoming(
        groupStorageId: 'target-room',
        messageId: 'queued',
        shouldNotify: true,
        stillEligible: () => !visible,
      );
      expect(service.unreadInGroup('target-room'), 0);
      visible = true;
      final cleared = service.clearGroup('target-room');
      visible = false;
      platform.showGate!.complete();
      await Future.wait([first, pending, cleared]);
      expect(platform.shown, hasLength(1));
      expect(service.unreadInGroup('target-room'), 0);
      await message('new-after-return', group: 'target-room');
      expect(platform.shown, hasLength(2));
    },
  );

  test('leave and rejoin does not revive old queued notification', () async {
    await service.initialize();
    platform.showGate = Completer<void>();
    platform.showStarted = Completer<void>();
    final first = message('blocking', group: 'other-room');
    await platform.showStarted!.future;
    var left = false;
    final pending = service.notifyIncoming(
      groupStorageId: 'target-room',
      messageId: 'before-leave',
      shouldNotify: true,
      stillEligible: () => !left,
    );
    left = true;
    final cleared = service.clearGroup('target-room');
    left = false;
    platform.showGate!.complete();
    await Future.wait([first, pending, cleared]);
    expect(platform.shown, hasLength(1));
    expect(service.unreadInGroup('target-room'), 0);
  });

  test(
    'disable then re-enable does not revive old queued notification',
    () async {
      await service.initialize();
      platform.showGate = Completer<void>();
      platform.showStarted = Completer<void>();
      final first = message('blocking', group: 'other-room');
      await platform.showStarted!.future;
      final pending = message('before-disable', group: 'target-room');
      await service.disable();
      await service.enable();
      platform.showGate!.complete();
      await Future.wait([first, pending]);
      expect(platform.shown, hasLength(1));
      expect(service.unreadCount, 0);
      await message('new-after-enable', group: 'target-room');
      expect(platform.shown, hasLength(2));
    },
  );
}
