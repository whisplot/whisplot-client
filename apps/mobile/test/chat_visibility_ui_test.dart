import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/privacy_shield.dart';

import 'mobile_ui_test.dart' show UiController;

class _VisibilityController extends UiController {
  _VisibilityController() {
    server = 'https://example.com';
    activeGroup = const Group(
      id: 'visible-group',
      server: 'https://example.com',
      name: '可见性测试',
      ownerId: 'device-a',
    );
    messages = List.generate(30, _message);
  }

  final visibleStates = <bool>[];
  final reported = <List<String>>[];

  static ChatMessage _message(int index) => ChatMessage(
    envelope: Envelope(
      groupId: 'visible-group',
      messageId: 'message-$index',
      senderId: 'device-b',
      nonce: '',
      ciphertext: '',
      signature: '',
    ),
    text: '消息 $index：只有真正显示在当前聊天窗口中的内容才发送已读回执。',
    senderName: '临时·DEF567',
    createdAt: index + 1,
    state: 'stored',
  );

  @override
  void setChatVisibility(String storageId, bool visible) {
    visibleStates.add(visible);
  }

  @override
  Future<void> markMessagesVisible(
    String storageId,
    Iterable<String> messageIds,
  ) async {
    reported.add(messageIds.toList());
  }

  void append() {
    messages = [...messages, _message(messages.length)];
    changed();
  }
}

Future<void> _size(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 650);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets(
    'only visible rows are reported; covering route pauses receipts',
    (tester) async {
      await _size(tester);
      final controller = _VisibilityController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ChatPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      final initiallyRead = controller.reported
          .expand((batch) => batch)
          .toSet();
      expect(initiallyRead, contains('message-0'));
      expect(initiallyRead, isNot(contains('message-29')));
      expect(initiallyRead.length, lessThan(controller.messages.length));
      expect(controller.visibleStates.last, isTrue);

      await tester.drag(find.byType(ListView), const Offset(0, -550));
      await tester.pumpAndSettle();
      final afterScroll = controller.reported.expand((batch) => batch).toSet();
      expect(afterScroll.difference(initiallyRead), isNotEmpty);

      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(ChatPage)),
          builder: (context) => AlertDialog(
            title: const Text('遮住聊天的窗口'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭测试窗口'),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.visibleStates.last, isFalse);
      controller.reported.clear();
      controller.append();
      await tester.pumpAndSettle();
      expect(controller.reported, isEmpty);

      await tester.tap(find.text('关闭测试窗口'));
      await tester.pumpAndSettle();
      expect(controller.visibleStates.last, isTrue);
      expect(controller.reported, isNotEmpty);
    },
  );

  testWidgets('inactive lifecycle never reports hidden messages', (
    tester,
  ) async {
    await _size(tester);
    final controller = _VisibilityController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PrivacyShield(child: ChatPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.reported, isNotEmpty);
    expect(controller.visibleStates.last, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    controller.reported.clear();
    controller.append();
    await tester.pumpAndSettle();
    expect(controller.reported, isEmpty);
    expect(controller.visibleStates.last, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(controller.visibleStates.last, isTrue);
    expect(controller.reported, isNotEmpty);
  });
}
