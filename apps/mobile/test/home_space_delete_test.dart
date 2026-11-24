import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/home_page.dart';

import 'mobile_ui_test.dart' show UiController, mobileSize;

const _group = Group(
  id: 'delete-ui-group',
  server: 'https://example.com',
  name: '可删除的群聊',
  ownerId: 'device-a',
);

class _DeleteUiController extends UiController {
  _DeleteUiController() {
    server = _group.server;
    groups = [_group];
  }

  final deleted = <String>[];
  bool failDelete = false;
  int pending = 0;
  Completer<void>? deletionGate;

  @override
  int get pendingGroupLeaveCount => pending;

  @override
  bool isGroupLeft(Group group) =>
      leftGroups.any((entry) => entry.storageId == group.storageId);

  @override
  Future<void> deleteGroupLocallyAndLeave(String storageId) async {
    deleted.add(storageId);
    if (failDelete) throw const FormatException('删除未完成，请重试');
    await deletionGate?.future;
    groups.removeWhere((entry) => entry.storageId == storageId);
    leftGroups.removeWhere((entry) => entry.storageId == storageId);
    changed();
  }
}

Finder _row(Group group) =>
    find.byKey(ValueKey('swipe-space-${group.storageId}'));

Finder _delete(Group group) =>
    find.byKey(ValueKey('delete-space-${group.storageId}'));

Future<void> _home(WidgetTester tester, _DeleteUiController controller) async {
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(home: HomePage(controller: controller)));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Group group) async {
  await tester.ensureVisible(_row(group));
  await tester.pumpAndSettle();
  await tester.drag(_row(group), const Offset(-130, 0));
  await tester.pumpAndSettle();
  expect(_delete(group).hitTestable(), findsOneWidget);
}

Future<void> _confirmation(WidgetTester tester, Group group) async {
  await _reveal(tester, group);
  await tester.tap(_delete(group));
  await tester.pumpAndSettle();
  expect(find.text('删除聊天空间？'), findsOneWidget);
}

void main() {
  testWidgets(
    'left swipe reveals delete without acting; cancel keeps history',
    (tester) async {
      await mobileSize(tester);
      final controller = _DeleteUiController();
      await _home(tester, controller);
      await _reveal(tester, _group);
      expect(controller.deleted, isEmpty);
      expect(controller.openedGroups, isEmpty);
      await tester.tap(_delete(_group));
      await tester.pumpAndSettle();
      expect(find.textContaining('全部本机聊天记录，无法撤销'), findsOneWidget);
      expect(find.textContaining('群主身份会自动交接'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.deleted, isEmpty);
      expect(controller.groups, [_group]);
      expect(_delete(_group).hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('confirmed deletion targets exact server and removes only it', (
    tester,
  ) async {
    const sameIdElsewhere = Group(
      id: 'delete-ui-group',
      server: 'https://different.example.com',
      name: '另一服务器的群',
      ownerId: 'other',
    );
    final controller = _DeleteUiController()
      ..groups = [_group, sameIdElsewhere]
      ..uiParticipationAllowed = false;
    await _home(tester, controller);
    await _confirmation(tester, _group);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-space')));
    await tester.pumpAndSettle();
    expect(controller.deleted, [_group.storageId]);
    expect(controller.groups, [sameIdElsewhere]);
    expect(controller.leftGroups, isEmpty);
    expect(_row(_group), findsNothing);
    expect(find.text('另一服务器的群'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'archived space can delete history without another leave prompt',
    (tester) async {
      final controller = _DeleteUiController()
        ..groups = []
        ..leftGroups = [_group];
      await _home(tester, controller);
      final archive = find.text('已退出的群 · 本机历史');
      await tester.ensureVisible(archive);
      await tester.tap(archive);
      await tester.pumpAndSettle();
      await _confirmation(tester, _group);
      expect(find.text('删除记录'), findsOneWidget);
      expect(find.text('退出并删除'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('confirm-delete-space')));
      await tester.pumpAndSettle();
      expect(controller.deleted, [_group.storageId]);
      expect(controller.leftGroups, isEmpty);
      expect(find.text('已退出的群 · 本机历史'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failure leaves a retryable row and repeated submit is blocked', (
    tester,
  ) async {
    final controller = _DeleteUiController()..failDelete = true;
    await _home(tester, controller);
    await _confirmation(tester, _group);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-space')));
    await tester.pumpAndSettle();
    expect(find.text('删除未完成，请重试'), findsOneWidget);
    expect(controller.groups, [_group]);
    controller
      ..failDelete = false
      ..deletionGate = Completer<void>();
    await _confirmation(tester, _group);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-space')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.deleted, [_group.storageId, _group.storageId]);
    expect(find.text('删除中'), findsOneWidget);
    await tester.tap(_delete(_group), warnIfMissed: false);
    await tester.pump();
    expect(controller.deleted, hasLength(2));
    controller.deletionGate!.complete();
    await tester.pumpAndSettle();
    expect(controller.groups, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed target during confirmation never deletes a new row', (
    tester,
  ) async {
    const replacement = Group(
      id: 'different-group',
      server: 'https://example.com',
      name: '新来的群',
      ownerId: 'other',
    );
    final controller = _DeleteUiController();
    await _home(tester, controller);
    await _confirmation(tester, _group);
    controller.groups = [replacement];
    controller.changed();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('confirm-delete-space')));
    await tester.pumpAndSettle();
    expect(controller.deleted, isEmpty);
    expect(controller.groups, [replacement]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal trackpad scrolling reveals the delete action', (
    tester,
  ) async {
    final controller = _DeleteUiController();
    await _home(tester, controller);
    await tester.ensureVisible(_row(_group));
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(_row(_group)),
        scrollDelta: const Offset(50, 0),
      ),
    );
    await tester.pumpAndSettle();
    expect(_delete(_group).hitTestable(), findsOneWidget);
    expect(controller.deleted, isEmpty);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(_row(_group)),
        scrollDelta: const Offset(-50, 0),
      ),
    );
    await tester.pumpAndSettle();
    expect(_delete(_group).hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
