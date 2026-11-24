import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/home_page.dart';

import 'mobile_ui_test.dart' show UiController, mobileSize;

const _group = Group(
  id: 'readonly-group',
  server: 'https://example.com',
  name: '保留的群聊',
  ownerId: 'device-a',
  keyEpoch: 1,
  protocolVersion: 2,
  privacyEpoch: 2,
  minClientBuild: 5,
);

const _message = ChatMessage(
  envelope: Envelope(
    groupId: 'readonly-group',
    messageId: 'saved-message',
    senderId: 'another-device',
    nonce: '',
    ciphertext: '',
    signature: '',
  ),
  text: '更新前已经保存在本机的消息',
  senderName: '临时·OLD234',
  createdAt: 1,
  state: 'stored',
  reactions: [ReactionSummary(emoji: '👍', count: 2, selectedByMe: false)],
);

class ReadonlyUiController extends UiController {
  ReadonlyUiController() {
    server = _group.server;
    groups = [_group];
    activeGroup = _group;
    messages = [_message];
  }

  int sendCalls = 0, reactionCalls = 0;

  @override
  Future<void> send(
    String text, {
    String? replyToMessageId,
    String? expectedStorageId,
  }) async => sendCalls++;

  @override
  Future<void> toggleReaction(
    String messageId,
    String emoji, {
    String? expectedStorageId,
  }) async => reactionCalls++;
}

void expectChatDisabled(WidgetTester tester) {
  for (final label in ['发送', '变声语音', '表情', '邀请朋友']) {
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == label,
            ),
          )
          .onPressed,
      isNull,
      reason: '$label must remain disabled in read-only history',
    );
  }
  expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  expect(
    tester
        .widget<InkWell>(
          find.byKey(const ValueKey('reaction-saved-message-👍')),
        )
        .onTap,
    isNull,
  );
}

void main() {
  testWidgets('read-only history shows messages but disables participation', (
    tester,
  ) async {
    await mobileSize(tester);
    final controller = ReadonlyUiController()..uiParticipationAllowed = false;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text(_message.text), findsOneWidget);
    expect(find.textContaining('本机历史 · 只读'), findsOneWidget);
    expectChatDisabled(tester);
    await tester.longPress(find.text(_message.text));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reaction-picker')), findsNothing);
    expect(controller.sendCalls, 0);
    expect(controller.reactionCalls, 0);
    expect(find.byTooltip('复制消息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending group key keeps history visible and sending disabled', (
    tester,
  ) async {
    await mobileSize(tester);
    final controller = ReadonlyUiController()..uiGroupSendAllowed = false;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text(_message.text), findsOneWidget);
    expectChatDisabled(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('policy fencing disables composer without discarding its draft', (
    tester,
  ) async {
    final controller = ReadonlyUiController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(controller: controller)),
    );
    await tester.enterText(find.byType(TextField), '尚未发送的草稿');

    controller.uiParticipationAllowed = false;
    controller.changed();
    await tester.pumpAndSettle();

    expectChatDisabled(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '尚未发送的草稿',
    );
    expect(find.text(_message.text), findsOneWidget);
    expect(controller.sendCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history home disables group creation and join but opens history',
    (tester) async {
      final controller = ReadonlyUiController()
        ..activeGroup = null
        ..uiParticipationAllowed = false;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: HomePage(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.text('本机历史 · 只读'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '邀请码入群'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '创建群聊'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text(_group.name));
      await tester.pumpAndSettle();
      expect(controller.openedGroups, [_group.id]);
      expect(find.byType(ChatPage), findsOneWidget);
      expect(controller.participationAllowed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
