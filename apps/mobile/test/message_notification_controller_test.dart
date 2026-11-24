import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/message_notifications.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'mandatory_update_test.dart' show SecurityFixture;
import 'group_departure_controller_test.dart' show DepartureBackend;
import 'read_receipt_test.dart' show addOther, receiptPayload;

class NotificationPlatformFixture implements MessageNotificationPlatform {
  final openedController = StreamController<String>.broadcast();
  final shown = <Map<String, Object>>[];
  @override
  Stream<String> get opened => openedController.stream;
  @override
  Future<Map<String, dynamic>> state() async => {
    'enabled': true,
    'granted': true,
    'prompted': true,
  };
  @override
  Future<Map<String, dynamic>> setEnabled(bool enabled) => state();
  @override
  Future<void> openSettings() async {}
  @override
  Future<void> show({
    required String token,
    required int count,
    required int badge,
    required bool sound,
  }) async {
    shown.add({'token': token, 'count': count, 'badge': badge, 'sound': sound});
  }

  @override
  Future<void> clear(String token, int badge) async {}
  @override
  Future<void> clearAll() async {}
  @override
  Future<void> dispose() => openedController.close();
}

Future<NotificationPlatformFixture> withNotifications(SecurityFixture f) async {
  f.controller.dispose();
  await Future<void>.delayed(Duration.zero);
  final platform = NotificationPlatformFixture();
  f.notifications = MessageNotificationService(platform: platform);
  await f.start();
  await f.controller.notifications.initialize();
  return platform;
}

Future<Map<String, dynamic>> remote(
  SecurityFixture f,
  Identity sender,
  String id,
  int seq, {
  Map<String, dynamic>? payload,
}) async {
  final e = await f.crypto.encryptPayload(
    identity: sender,
    groupId: f.group.id,
    messageId: id,
    keyEpoch: 1,
    groupKey: List.filled(32, 41),
    payload:
        payload ??
        {
          'text': 'private text',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        },
  );
  return {
    ...e.toJson(),
    'seq': seq,
    'storedAt': DateTime.now().millisecondsSinceEpoch,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'home polling alerts only new verified other content after startup baseline',
    () async {
      final f = await SecurityFixture.create();
      final other = await addOther(f);
      f.remoteMessages.add(
        await remote(f, other, '11111111-1111-4111-8111-111111111110', 1),
      );
      f.group = f.group.copyWith(lastSeq: 1);
      final platform = await withNotifications(f);
      expect(f.controller.activeGroup, isNull);
      await f.controller.pollMessageNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(platform.shown, isEmpty);
      expect(await f.store.cursor(f.group), 1);
      f.remoteMessages.add(
        await remote(f, other, '22222222-2222-4222-8222-222222222220', 2),
      );
      f.group = f.group.copyWith(lastSeq: 2);
      await f.controller.pollMessageNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(platform.shown.length, 1);
      expect(f.controller.notifications.unreadCount, 1);
      final before = f.requests.length;
      await f.controller.pollMessageNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(platform.shown.length, 1);
      expect(
        f.requests.skip(before).where((r) => r.url.path.endsWith('/messages')),
        isEmpty,
      );
      const eventId = '33333333-3333-4333-8333-333333333330';
      f.remoteMessages.add(
        await remote(
          f,
          other,
          eventId,
          3,
          payload: receiptPayload(eventId, [
            '22222222-2222-4222-8222-222222222220',
          ]),
        ),
      );
      f.remoteMessages.add(
        await remote(
          f,
          other,
          '44444444-4444-4444-8444-444444444440',
          4,
          payload: {
            'type': 'reaction',
            'targetMessageId': '22222222-2222-4222-8222-222222222220',
            'action': 'set',
            'emoji': '👍',
            'counter': 1,
            'createdAt': 100,
          },
        ),
      );
      f.remoteMessages.add(
        await remote(f, f.identity, '55555555-5555-4555-8555-555555555550', 5),
      );
      f.group = f.group.copyWith(lastSeq: 5);
      await f.controller.pollMessageNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(platform.shown.length, 1);
      expect(await f.store.cursor(f.group), 5);
      expect(f.controller.notifications.unreadCount, 1);
    },
  );
  test(
    'visible active chat suppresses alerts but covered chat permits reminders',
    () async {
      final f = await SecurityFixture.create();
      final other = await addOther(f);
      final platform = await withNotifications(f);
      f.selectGroup();
      f.controller.setChatVisibility(f.group.storageId, true);
      f.remoteMessages.add(
        await remote(f, other, '66666666-6666-4666-8666-666666666660', 1),
      );
      f.group = f.group.copyWith(lastSeq: 1);
      await f.controller.pollMessageNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(platform.shown, isEmpty);
      f.controller.setChatVisibility(f.group.storageId, false);
      f.remoteMessages.add(
        await remote(f, other, '77777777-7777-4777-8777-777777777770', 2),
      );
      f.group = f.group.copyWith(lastSeq: 2);
      await f.controller.pollMessageNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(platform.shown.length, 1);
      expect(f.controller.notifications.unreadCount, 1);
      f.controller.setChatVisibility(f.group.storageId, true);
      await Future<void>.delayed(Duration.zero);
      expect(f.controller.notifications.unreadCount, 0);
    },
  );
  test(
    'leaving and readmitting resets only the new admission notification baseline',
    () async {
      final f = await SecurityFixture.create();
      final other = await addOther(f);
      final platform = await withNotifications(f);
      final backend = DepartureBackend(f);
      await backend.leaveConfirmed();
      f.remoteMessages.add(
        await remote(f, other, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 1),
      );
      f.group = f.group.copyWith(lastSeq: 1);
      await f.controller.join(backend.invitation());
      await f.controller.closeGroup();
      await f.controller.pollMessageNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(platform.shown, isEmpty);
      expect(await f.store.cursor(f.group), 1);
    },
  );

  test(
    'summary polling is bounded across many groups and does not resurrect a deleted group',
    () async {
      final f = await SecurityFixture.create();
      await withNotifications(f);
      final roomList = <Group>[
        for (var i = 0; i < 12; i++)
          Group(
            id: '${(i + 1).toString().padLeft(8, '0')}-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            server: f.group.server,
            name: 'Synthetic room',
            ownerId: f.identity.id,
            lastSeq: 1,
            keyEpoch: 1,
            protocolVersion: 2,
            privacyEpoch: 2,
            minClientBuild: 5,
          ),
      ];
      for (final room in roomList) {
        await f.store.saveGroup(room);
      }
      final deleted = roomList.last;
      await f.controller
          .deleteGroupLocallyAndLeave(deleted.storageId)
          .catchError((Object _) {});
      f.extraHandler = (request) async {
        if (request.url.path == '/v1/groups') {
          return http.Response(
            jsonEncode({'groups': roomList.map((g) => g.toJson()).toList()}),
            200,
          );
        }
        if (request.url.path.endsWith('/messages')) {
          return http.Response(
            jsonEncode({'messages': [], 'nextCursor': 1, 'hasMore': false}),
            200,
          );
        }
        if (request.url.path.endsWith('/ack')) {
          return http.Response('{"ok":true}', 200);
        }
        return null;
      };
      await f.controller.reconnect();
      final before = f.requests.length;
      await f.controller.pollMessageNotifications();
      final requests = f.requests.skip(before).toList();
      expect(requests.where((r) => r.url.path == '/v1/groups').length, 1);
      expect(requests.where((r) => r.url.path.endsWith('/messages')).length, 2);
      expect(
        f.controller.groups.any((g) => g.storageId == deleted.storageId),
        isFalse,
      );
    },
  );
}
