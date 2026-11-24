import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';

import 'message_gestures_reply_test.dart' show ReplyUiController;

class OnlineUiController extends ReplyUiController {
  int? count;
  bool departed = false;

  @override
  int? get activeOnlineCount => count;

  @override
  bool isGroupLeft(Group group) => departed;

  void update(int? value) {
    count = value;
    notifyListeners();
  }
}

Future<void> mount(WidgetTester tester, OnlineUiController controller) async {
  addTearDown(controller.dispose);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(MaterialApp(home: ChatPage(controller: controller)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('online count updates without changing the group title or ID', (
    tester,
  ) async {
    final controller = OnlineUiController()..count = 2;
    await mount(tester, controller);
    final status = find.byKey(const ValueKey('chat-online-count'));
    expect(tester.widget<Text>(status).data, contains('2 人在线'));
    expect(find.text(controller.activeGroup!.name), findsOneWidget);
    controller.update(3);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(status).data, contains('3 人在线'));
    expect(find.byKey(const ValueKey('chat-current-id')), findsOneWidget);
  });

  testWidgets('expired or unavailable counts are not presented as zero', (
    tester,
  ) async {
    final controller = OnlineUiController()..count = 1;
    await mount(tester, controller);
    controller.update(null);
    await tester.pumpAndSettle();
    final status = tester.widget<Text>(
      find.byKey(const ValueKey('chat-online-count')),
    );
    expect(status.data, contains('在线 —'));
    expect(status.data, isNot(contains('0 人在线')));
  });

  testWidgets('left-group history has no live online count', (tester) async {
    final controller = OnlineUiController()
      ..count = 2
      ..departed = true;
    await mount(tester, controller);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('chat-online-count'))).data,
      '已退出',
    );
  });

  testWidgets('member and online counts fit a narrow phone header', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = OnlineUiController()..count = 50;
    await mount(tester, controller);
    expect(find.byKey(const ValueKey('chat-group-name')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('chat-online-count'))).data,
      contains('50 人在线'),
    );
    expect(tester.takeException(), isNull);
  });
}
