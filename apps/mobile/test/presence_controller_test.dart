import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/default_connection.dart';
import 'package:nearlink/core/group_presence.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/background_connection.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'mandatory_update_test.dart' show SecurityFixture, settleUntil;
import 'group_departure_controller_test.dart' show DepartureBackend;
import 'group_presence_test.dart' show snapshot;
import 'read_receipt_test.dart' show addOther, seed, incomingId;
import 'quote_reply_controller_test.dart' show reloadMessages;

http.Response groupsReply(List<Map<String, dynamic>> groups) =>
    http.Response(jsonEncode({'groups': groups}), 200);

class BackgroundFixture implements BackgroundConnectionPlatform {
  int starts = 0, stops = 0, checks = 0;
  bool running = false, fail = false;
  @override
  Stream<Map<String, dynamic>> get changes => const Stream.empty();
  Map<String, dynamic> value() => {'available': true, 'running': running};
  @override
  Future<Map<String, dynamic>> state() async {
    checks++;
    return value();
  }

  @override
  Future<Map<String, dynamic>> setEnabled(bool enabled) async {
    if (enabled) {
      starts++;
      if (fail) throw StateError('fixture service unavailable');
    } else {
      stops++;
    }
    running = enabled;
    return value();
  }

  @override
  Future<void> dispose() async {}
}

Future<void> restart(
  SecurityFixture f, {
  GroupPresence? presence,
  BackgroundConnectionService? background,
}) async {
  f.controller.dispose();
  await Future<void>.delayed(Duration.zero);
  f.controller = ChatController(
    store: f.store,
    crypto: f.crypto,
    defaultConnection: const DefaultConnection(),
    authorityPublicKey: f.authority.publicKey,
    presence: presence,
    backgroundConnection: background,
    apiFactory:
        ({
          required server,
          required identity,
          required crypto,
          required registrationCode,
        }) => ApiClient(
          server: server,
          identity: identity,
          crypto: crypto,
          registrationCode: registrationCode,
          client: MockClient(f.handle),
        ),
  );
  await f.controller.initialize();
  await f.controller.reconnect();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(() {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'disabled notifications still heartbeat all memberships; count follows selected room',
    () async {
      final f = await SecurityFixture.create();
      final other = Group(
        id: '22222222-2222-4222-8222-222222222222',
        server: f.group.server,
        name: 'second',
        ownerId: f.identity.id,
        keyEpoch: 1,
        protocolVersion: 2,
        privacyEpoch: 2,
        minClientBuild: 5,
      );
      f.extraHandler = (r) async => r.url.path == '/v1/groups'
          ? groupsReply([
              {...f.group.toJson(), ...snapshot(3, 100)},
              {...other.toJson(), ...snapshot(7, 100)},
            ])
          : null;
      expect(f.controller.notifications.enabled, isFalse);
      final before = f.requests.length;
      await f.controller.pollMessageNotifications();
      expect(
        f.requests.skip(before).where((r) => r.url.path == '/v1/groups'),
        hasLength(1),
      );
      expect(f.controller.onlineCountForGroup(f.group), 3);
      expect(f.controller.activeOnlineCount, isNull);
      f.selectGroup();
      expect(f.controller.activeOnlineCount, 3);
      f.controller.activeGroup = other;
      expect(f.controller.activeOnlineCount, 7);
      await f.controller.closeGroup();
      expect(f.controller.onlineCountForGroup(f.group), 3);
      final rows = await f.db.query('groups');
      expect(
        rows
            .expand((row) => row.keys)
            .where((key) => key.startsWith('presence') || key == 'onlineCount'),
        isEmpty,
      );
    },
  );

  test(
    'lease expiry notifies UI and missing fields from older server clear count',
    () async {
      final f = await SecurityFixture.create();
      var elapsed = 0, observation = 100;
      final cache = GroupPresence(elapsedMilliseconds: () => elapsed);
      await restart(f, presence: cache);
      var supported = true;
      f.extraHandler = (r) async => r.url.path == '/v1/groups'
          ? groupsReply([
              {
                ...f.group.toJson(),
                if (supported) ...snapshot(2, observation++),
              },
            ])
          : null;
      await f.controller.pollMessageNotifications();
      expect(f.controller.onlineCountForGroup(f.group), 2);
      var changed = 0;
      f.controller.addListener(() => changed++);
      elapsed = 90000;
      cache.expire();
      expect(changed, greaterThan(0));
      expect(f.controller.onlineCountForGroup(f.group), isNull);
      await f.controller.pollMessageNotifications();
      expect(f.controller.onlineCountForGroup(f.group), 2);
      supported = false;
      await f.controller.pollMessageNotifications();
      expect(f.controller.onlineCountForGroup(f.group), isNull);
    },
  );

  test(
    'out of order summaries cannot replace a newer presence count',
    () async {
      final f = await SecurityFixture.create();
      final entered = Completer<void>(), held = Completer<http.Response>();
      var first = true;
      f.extraHandler = (r) async {
        if (r.url.path != '/v1/groups') return null;
        if (first) {
          first = false;
          entered.complete();
          return held.future;
        }
        return groupsReply([
          {...f.group.toJson(), ...snapshot(6, 200)},
        ]);
      };
      final old = f.controller.refreshGroups();
      await entered.future;
      await f.controller.refreshGroups();
      expect(f.controller.onlineCountForGroup(f.group), 6);
      held.complete(
        groupsReply([
          {...f.group.toJson(), ...snapshot(2, 100)},
        ]),
      );
      await old;
      expect(f.controller.onlineCountForGroup(f.group), 6);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    test(
      '$platform inactive, hidden and paused heartbeat but never mark read; detached stops',
      () async {
        final f = await SecurityFixture.create();
        // Exercise platform lifecycle after the shared secure-storage fixture
        // has initialized using its normal test backend.
        debugDefaultTargetPlatformOverride = platform;
        expect(
          f.controller.participationAllowed,
          isTrue,
          reason: f.controller.error,
        );
        final other = await addOther(f);
        await seed(f, other, incomingId);
        await reloadMessages(f);
        f.controller.setChatVisibility(f.group.storageId, true);
        var observed = 100;
        f.extraHandler = (r) async => r.url.path == '/v1/groups'
            ? groupsReply([
                {...f.group.toJson(), ...snapshot(4, observed++)},
              ])
            : null;
        final posts = f.posts;
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          f.controller.didChangeAppLifecycleState(state);
          final before = f.requests.length;
          await f.controller.pollMessageNotifications();
          expect(
            f.requests.skip(before).where((r) => r.url.path == '/v1/groups'),
            hasLength(1),
          );
          expect(f.controller.activeOnlineCount, 4);
          await f.controller.markMessagesVisible(f.group.storageId, [
            incomingId,
          ]);
          await f.controller.flushVisibleReadReceipts();
          expect(f.posts, posts);
          expect(f.controller.messages.single.isRead, isFalse);
        }
        f.controller.didChangeAppLifecycleState(AppLifecycleState.detached);
        final before = f.requests.length;
        await f.controller.pollMessageNotifications();
        await f.controller.refreshGroups();
        expect(f.requests.length, before);
        expect(f.controller.activeOnlineCount, isNull);
      },
    );
  }

  test('a late response after leaving cannot resurrect presence', () async {
    final f = await SecurityFixture.create();
    final backend = DepartureBackend(f);
    backend.heldList = Completer<http.Response>();
    backend.listEntered = Completer<void>();
    final held = backend.heldList!;
    final pending = f.controller.refreshGroups().catchError((Object e) {
      expect(e, isA<TransportChangedException>());
    });
    await backend.listEntered!.future;
    await backend.leaveConfirmed();
    held.complete(
      groupsReply([
        {...f.group.toJson(), ...snapshot(4, 100)},
      ]),
    );
    await pending;
    expect(f.controller.onlineCountForGroup(f.group), isNull);
    expect(f.controller.groups, isEmpty);
  });

  test('poll failure backs off; explicit reconnect refreshes count', () async {
    final f = await SecurityFixture.create();
    var fail = true;
    f.extraHandler = (r) async {
      if (r.url.path != '/v1/groups') return null;
      if (fail) throw const SocketException('synthetic offline');
      return groupsReply([
        {...f.group.toJson(), ...snapshot(2, 100)},
      ]);
    };
    await f.controller.pollMessageNotifications();
    final before = f.requests.length;
    await f.controller.pollMessageNotifications();
    expect(f.requests.length, before);
    fail = false;
    await f.controller.retryConnection();
    expect(f.controller.onlineCountForGroup(f.group), 2);
  });

  test(
    'detaching ignores in-flight presence and stops policy refresh IO',
    () async {
      final f = await SecurityFixture.create();
      final entered = Completer<void>(), held = Completer<http.Response>();
      f.extraHandler = (r) async {
        if (r.url.path != '/v1/groups') return null;
        entered.complete();
        return held.future;
      };
      final pending = f.controller.refreshGroups().catchError((Object e) {
        expect(e, isA<TransportChangedException>());
      });
      await entered.future;
      f.controller.didChangeAppLifecycleState(AppLifecycleState.detached);
      held.complete(
        groupsReply([
          {...f.group.toJson(), ...snapshot(3, 100)},
        ]),
      );
      await pending;
      expect(f.controller.onlineCountForGroup(f.group), isNull);
      final before = f.requests.length;
      await f.controller.refreshPolicy();
      await f.controller.pollMessageNotifications();
      expect(f.requests.length, before);
    },
  );

  test(
    'switching server isolates a late response for the same group ID',
    () async {
      final f = await SecurityFixture.create();
      final original = f.group;
      final entered = Completer<void>(), held = Completer<http.Response>();
      var first = true;
      f.extraHandler = (r) async {
        if (r.url.path != '/v1/groups') return null;
        if (first) {
          first = false;
          entered.complete();
          return held.future;
        }
        return groupsReply([
          {...f.group.toJson(), ...snapshot(8, 200)},
        ]);
      };
      final old = f.controller.refreshGroups().catchError((Object e) {
        expect(e, isA<TransportChangedException>());
      });
      await entered.future;
      await f.controller.configure(
        'https://other-fixture.example',
        '',
        'new-code',
      );
      final current = f.controller.groups.single;
      expect(current.server, 'https://other-fixture.example');
      expect(f.controller.onlineCountForGroup(current), 8);
      held.complete(
        groupsReply([
          {...original.toJson(), ...snapshot(2, 100)},
        ]),
      );
      await old;
      expect(f.controller.onlineCountForGroup(original), isNull);
      expect(f.controller.onlineCountForGroup(current), 8);
    },
  );

  test(
    'an uninitialized controller never starts a background service',
    () async {
      final platform = BackgroundFixture();
      final controller = ChatController(
        backgroundConnection: BackgroundConnectionService(platform: platform),
      );
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(platform.starts, 0);
      controller.dispose();
    },
  );

  test(
    'foreground service starts only with eligibility; failure does not pause heartbeat',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final f = await SecurityFixture.create();
      final platform = BackgroundFixture()..fail = true;
      final service = BackgroundConnectionService(platform: platform);
      await restart(f, background: service);
      await settleUntil(() => platform.starts > 0);
      expect(service.running, isFalse);
      final starts = platform.starts;
      f.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      final before = f.requests.length;
      await f.controller.pollMessageNotifications();
      expect(
        f.requests.skip(before).where((r) => r.url.path == '/v1/groups'),
        hasLength(1),
      );
      expect(platform.starts, starts);
      platform.fail = false;
      f.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settleUntil(() => service.running);
      expect(platform.checks, greaterThan(0));
      final backend = DepartureBackend(f);
      await backend.leaveConfirmed();
      await settleUntil(() => !platform.running);
      expect(f.controller.groups, isEmpty);
      f.controller.didChangeAppLifecycleState(AppLifecycleState.detached);
      await settleUntil(() => !platform.running);
    },
  );
}
