import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/home_page.dart';
import 'package:nearlink/ui/reaction_picker.dart';

import 'mobile_ui_test.dart' show UiController, mobileSize;

const _group = Group(
  id: 'ui-leave-group',
  server: 'https://example.com',
  name: '共同的群聊',
  ownerId: 'device-a',
  keyEpoch: 1,
  protocolVersion: 2,
  privacyEpoch: 2,
  minClientBuild: 8,
);

class LeaveUiController extends UiController {
  LeaveUiController({Group group = _group}) {
    server = group.server;
    groups = [group];
    activeGroup = group;
  }
  final departed = <String>{};
  final sent = <String>[];
  final leaveRequests = <String?>[];
  bool confirmLeave = true, failLeave = false;
  int pending = 0;

  @override
  int get pendingGroupLeaveCount => pending;

  @override
  bool isGroupLeft(Group group) => departed.contains(group.storageId);

  @override
  bool canSendToGroup(Group group) =>
      super.canSendToGroup(group) &&
      !isGroupLeft(group) &&
      !group.rekeyRequired;

  @override
  Future<void> send(
    String text, {
    String? replyToMessageId,
    String? expectedStorageId,
  }) async => sent.add(text);

  @override
  Future<bool> leaveActiveGroup({String? expectedStorageId}) async {
    leaveRequests.add(expectedStorageId);
    if (failLeave) throw const FormatException('退群未完成，请重试');
    final group = activeGroup!;
    departed.add(group.storageId);
    groups = [];
    leftGroups = [group];
    pending = confirmLeave ? 0 : 1;
    activeGroup = null;
    changed();
    return confirmLeave;
  }
}

Future<void> pickFlower(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('reaction-search')), '樱花');
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('reaction-grid-🌸')));
  await tester.pumpAndSettle();
}

Future<void> openLeave(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('退出群聊'));
  await tester.pumpAndSettle();
}

Finder iconButton(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

Future<void> openFromHome(
  WidgetTester tester,
  LeaveUiController controller,
) async {
  controller.activeGroup = null;
  await tester.pumpWidget(MaterialApp(home: HomePage(controller: controller)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(_group.name));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('composer inserts emoji at caret without sending mixed text', (
    tester,
  ) async {
    await mobileSize(tester);
    final controller = LeaveUiController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(controller: controller)),
    );
    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.value = const TextEditingValue(
      text: '一起聊天',
      selection: TextSelection.collapsed(offset: 2),
    );
    await tester.tap(find.byTooltip('表情'));
    await tester.pumpAndSettle();
    expect(find.byType(ReactionPicker), findsOneWidget);
    await pickFlower(tester);
    expect(editor.text, '一起🌸聊天');
    expect(editor.selection.baseOffset, 4);
    expect(controller.sent, isEmpty);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(controller.sent, ['一起🌸聊天']);
    expect(editor.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'composer emoji replaces a selection and keeps surrounding text',
    (tester) async {
      final controller = LeaveUiController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ChatPage(controller: controller)),
      );
      final editor = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      editor.value = const TextEditingValue(
        text: '今天晴天!',
        selection: TextSelection(baseOffset: 2, extentOffset: 4),
      );
      await tester.tap(find.byTooltip('表情'));
      await tester.pumpAndSettle();
      await pickFlower(tester);
      expect(editor.text, '今天🌸!');
      expect(controller.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'composer respects policy changes while the emoji picker is open',
    (tester) async {
      final controller = LeaveUiController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ChatPage(controller: controller)),
      );
      final editor = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      editor.text = '保留草稿';
      await tester.tap(find.byTooltip('表情'));
      await tester.pumpAndSettle();
      controller.uiParticipationAllowed = false;
      controller.changed();
      await tester.pump();
      await pickFlower(tester);
      expect(editor.text, '保留草稿');
      expect(tester.widget<IconButton>(iconButton('表情')).onPressed, isNull);
      expect(controller.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final owner in [true, false]) {
    testWidgets('${owner ? 'owner' : 'member'} may leave read-only history', (
      tester,
    ) async {
      await mobileSize(tester);
      final group = owner
          ? _group
          : const Group(
              id: 'ui-leave-group',
              server: 'https://example.com',
              name: '共同的群聊',
              ownerId: 'someone-else',
            );
      final controller = LeaveUiController(group: group)
        ..uiParticipationAllowed = false;
      addTearDown(controller.dispose);
      await openFromHome(tester, controller);
      await openLeave(tester);
      expect(find.textContaining('未发出的消息不再发送'), findsOneWidget);
      expect(find.textContaining('群主退出后会自动交接'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-leave-group')));
      await tester.pumpAndSettle();
      expect(controller.leaveRequests, [group.storageId]);
      expect(find.byType(ChatPage), findsNothing);
      await tester.scrollUntilVisible(find.text('已退出的群 · 本机历史'), 200);
      expect(find.text('已退出的群 · 本机历史'), findsOneWidget);
      expect(find.text('退群待确认'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancelling leave keeps group and chat unchanged', (
    tester,
  ) async {
    final controller = LeaveUiController();
    addTearDown(controller.dispose);
    await openFromHome(tester, controller);
    await openLeave(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.leaveRequests, isEmpty);
    expect(controller.groups, [_group]);
    expect(find.byType(ChatPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'offline exit returns home with pending status and read-only archive',
    (tester) async {
      final controller = LeaveUiController()..confirmLeave = false;
      addTearDown(controller.dispose);
      await openFromHome(tester, controller);
      await openLeave(tester);
      await tester.tap(find.byKey(const ValueKey('confirm-leave-group')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsNothing);
      expect(find.text('退群待确认'), findsOneWidget);
      final archive = find.text('已退出的群 · 本机历史');
      await tester.scrollUntilVisible(archive, 200);
      await tester.pumpAndSettle();
      await tester.tap(archive);
      await tester.pumpAndSettle();
      final saved = find.byKey(ValueKey('left-group-${_group.storageId}'));
      await tester.ensureVisible(saved);
      await tester.pumpAndSettle();
      await tester.tap(saved);
      await tester.pumpAndSettle();
      expect(find.text('已退出的群 · 本机历史，只读。'), findsOneWidget);
      expect(find.byTooltip('邀请朋友'), findsNothing);
      expect(tester.widget<IconButton>(iconButton('发送')).onPressed, isNull);
      expect(tester.widget<IconButton>(iconButton('表情')).onPressed, isNull);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      for (final action in ['退出群聊', '管理邀请', '更新本群密钥', '为已升级成员补发密钥']) {
        expect(find.text(action), findsNothing);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed leave stays in chat and allows another attempt', (
    tester,
  ) async {
    final controller = LeaveUiController()..failLeave = true;
    addTearDown(controller.dispose);
    await openFromHome(tester, controller);
    await openLeave(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-leave-group')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.textContaining('退群未完成，请重试'), findsOneWidget);
    expect(controller.groups, [_group]);
    await openLeave(tester);
    expect(find.byKey(const ValueKey('confirm-leave-group')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'switching group during confirmation cannot leave the new group',
    (tester) async {
      final controller = LeaveUiController();
      addTearDown(controller.dispose);
      await openFromHome(tester, controller);
      await openLeave(tester);
      controller.activeGroup = const Group(
        id: 'new-group',
        server: 'https://example.com',
        name: '新群',
        ownerId: 'device-a',
      );
      controller.changed();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('confirm-leave-group')));
      await tester.pumpAndSettle();
      expect(controller.leaveRequests, isEmpty);
      expect(find.text('新群'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'membership key rotation explains read-only and offers owner recovery',
    (tester) async {
      final controller = LeaveUiController(
        group: const Group(
          id: 'rotating-group',
          server: 'https://example.com',
          name: '等待更新',
          ownerId: 'device-a',
          keyEpoch: 1,
          rekeyRequired: true,
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ChatPage(controller: controller)),
      );
      expect(find.textContaining('成员已变更，正在更新群密钥'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '更新原群密钥'), findsOneWidget);
      expect(tester.widget<IconButton>(iconButton('发送')).onPressed, isNull);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('退出群聊'), findsOneWidget);
      expect(find.text('更新本群密钥'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
