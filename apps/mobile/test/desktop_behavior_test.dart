import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/push_service.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/ui/chat_page.dart';

import 'mobile_ui_test.dart' show UiController;
import 'push_service_test.dart' show FakePushApi, FakePushPlatform;

class DesktopController extends UiController {
  DesktopController() {
    server = 'https://example.com';
    displayName = '临时·ABC234';
    activeGroup = const Group(
      id: 'desktop-group',
      server: 'https://example.com',
      name: '桌面群聊',
      ownerId: 'device-a',
    );
  }

  final sent = <String>[];
  Completer<void>? sending;
  int reconnects = 0;

  @override
  Future<void> send(
    String text, {
    String? replyToMessageId,
    String? expectedStorageId,
  }) async {
    sent.add(text);
    await sending?.future;
  }

  @override
  Future<void> reconnect() async => reconnects++;
}

class CountingPushPlatform extends FakePushPlatform {
  int initializations = 0;

  @override
  Future<void> initialize() async => initializations++;
}

class MissingKeyStore extends LocalStore {
  int writes = 0;
  @override
  Future<String?> readAliasState() async => null;
  @override
  Future<void> open() async {}
  @override
  Future<bool> hasChatData() async => true;
  @override
  Future<String?> readSecret(String key) async => null;
  @override
  Future<void> writeSecret(String key, String value) async => writes++;
  @override
  Future<void> close() async {}
}

Future<DesktopController> desktopChat(WidgetTester tester) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = DesktopController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(home: ChatPage(controller: controller)));
  return controller;
}

void main() {
  testWidgets('Existing Mac chats block replacing an unavailable identity', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final store = MissingKeyStore();
    final controller = ChatController(store: store);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.ready, isFalse);
    expect(controller.error, contains('已有聊天记录'));
    expect(store.writes, 0);
  });

  testWidgets('Mac Enter sends once and Shift+Enter inserts a line break', (
    tester,
  ) async {
    final controller = await desktopChat(tester);
    final input = find.byType(TextField);
    expect(
      tester.widget<TextField>(input).decoration?.hintText,
      'Enter 发送 · Shift+Enter 换行',
    );
    expect(find.text('Enter 发送 · Shift+Enter 换行'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-current-id')), findsOneWidget);
    expect(find.text('ABC234'), findsOneWidget);
    expect(find.textContaining('临时ID：'), findsNothing);
    expect(find.textContaining('加密群聊'), findsNothing);
    await tester.enterText(input, '第一行');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.sent, isEmpty);
    expect(tester.widget<TextField>(input).controller!.text, '第一行\n');
    await tester.enterText(input, '第一行\n第二行');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.sent, ['第一行\n第二行']);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
  });

  testWidgets('Confirming Chinese composition never sends the draft', (
    tester,
  ) async {
    final controller = await desktopChat(tester);
    await tester.showKeyboard(find.byType(TextField));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.sent, isEmpty);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.sent, ['你好']);
  });

  testWidgets('Finishing a queued send preserves newer composer input', (
    tester,
  ) async {
    final controller = await desktopChat(tester);
    controller.sending = Completer<void>();
    final input = find.byType(TextField);
    await tester.enterText(input, '已提交的消息');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.enterText(input, '接下来要写的消息');
    controller.sending!.complete();
    await tester.pump();
    expect(controller.sent, ['已提交的消息']);
    expect(tester.widget<TextField>(input).controller!.text, '接下来要写的消息');
  });

  testWidgets('Wide-screen own and peer messages stay centered and readable', (
    tester,
  ) async {
    final controller = await desktopChat(tester);
    controller.messages = [
      for (final sender in ['device-a', 'device-b'])
        ChatMessage(
          envelope: Envelope(
            groupId: 'desktop-group',
            messageId: sender,
            senderId: sender,
            nonce: '',
            ciphertext: '',
            signature: '',
          ),
          text: '这是一条需要在宽屏窗口里保持可读宽度的消息。' * 12,
          senderName: '临时·ABC234',
          createdAt: 1,
          state: 'stored',
        ),
    ];
    controller.changed();
    await tester.pumpAndSettle();
    for (final sender in ['device-a', 'device-b']) {
      final card = find.byKey(ValueKey('message-card-$sender'));
      expect(tester.getCenter(card).dx, closeTo(720, 0.1));
      expect(tester.getSize(card).width, lessThanOrEqualTo(720));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mac focus and hide cycles do not reconnect the session', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = DesktopController()..activeGroup = null;
    addTearDown(controller.dispose);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      controller.didChangeAppLifecycleState(state);
    }
    expect(controller.reconnects, 0);
    controller.didChangeAppLifecycleState(AppLifecycleState.detached);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.reconnects, 1);
  });

  testWidgets('Android background keeps networking; detached still reconnects', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = DesktopController()..activeGroup = null;
    addTearDown(controller.dispose);
    controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(controller.reconnects, 0);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.reconnects, 0);
    controller.didChangeAppLifecycleState(AppLifecycleState.detached);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.reconnects, 1);
  });

  test(
    'Unsupported desktop push never touches Firebase or device registration',
    () async {
      final platform = CountingPushPlatform();
      final api = FakePushApi();
      var storageReads = 0;
      final service = PushService(
        platform: platform,
        platformSupported: false,
        readPreference: (_) async {
          storageReads++;
          return 'true';
        },
        writePreference: (_, _) async {},
      );
      addTearDown(service.dispose);
      addTearDown(platform.dispose);
      addTearDown(api.close);
      await service.initialize();
      service.api = api;
      await service.retryRegistration();
      await expectLater(service.enable(), throwsA(isA<ApiException>()));
      await service.disable();
      expect(platform.initializations, 0);
      expect(platform.tokenRequests, 0);
      expect(api.methods, isEmpty);
      expect(storageReads, 0);
      expect(service.configured, isFalse);
      expect(service.status, contains('Mac'));
    },
  );
}
