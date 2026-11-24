import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/message_bubble.dart';
import 'package:nearlink/ui/voice_composer.dart';

import 'message_gestures_reply_test.dart' show ReplyUiController, note, swipe;

class SendScrollController extends ReplyUiController {
  SendScrollController() {
    messages = [
      for (var i = 0; i < 90; i++)
        note(
          'history-$i',
          text: i < 40 ? '短消息 $i' : '较长消息 $i\n${'历史内容\n' * (i % 17)}',
        ),
    ];
  }

  int sent = 0;
  Completer<void>? acknowledgement;
  bool deferAppend = false;
  void Function()? appendPending;

  @override
  Future<void> send(
    String text, {
    String? replyToMessageId,
    String? expectedStorageId,
  }) async {
    final id = 'sent-${++sent}';
    void append() {
      messages = [...messages, note(id, text: text, reply: replyToMessageId)];
      changed();
    }

    if (deferAppend) {
      appendPending = append;
    } else {
      append();
    }
    await acknowledgement?.future;
  }

  @override
  Future<void> sendVoice(
    Uint8List wav, {
    String? replyToMessageId,
    String? expectedStorageId,
  }) async {
    final id = 'sent-${++sent}';
    messages = [...messages, note(id, voice: true, reply: replyToMessageId)];
    changed();
    await acknowledgement?.future;
  }
}

ScrollController listScroll(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

Future<void> mountSendChat(
  WidgetTester tester,
  SendScrollController controller, {
  bool reduceMotion = false,
  ValueNotifier<bool>? visibility,
}) async {
  tester.view.physicalSize = const Size(800, 650);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: visibility == null
          ? ChatPage(controller: controller)
          : ValueListenableBuilder<bool>(
              valueListenable: visibility,
              child: ChatPage(controller: controller),
              builder: (context, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
            ),
    ),
  );
  await tester.pumpAndSettle();
}

void expectLatestBottom(WidgetTester tester, String id) {
  expect(
    listScroll(tester).position.extentAfter,
    lessThanOrEqualTo(1),
    reason: 'the lazy list must reach its real end, not its earlier estimate',
  );
  final metadata = find.byKey(ValueKey('message-metadata-$id'));
  expect(metadata.hitTestable(), findsOneWidget);
  expect(
    tester.getRect(metadata).bottom,
    lessThanOrEqualTo(tester.getRect(find.byType(ListView)).bottom),
  );
}

void main() {
  testWidgets(
    'sending from history reaches the real last message after variable-height layout',
    (tester) async {
      final controller = SendScrollController();
      await mountSendChat(tester, controller);
      listScroll(tester).jumpTo(650);
      await tester.pumpAndSettle();
      expect(listScroll(tester).position.extentAfter, greaterThan(1000));
      await tester.enterText(
        find.byType(TextField),
        '我刚刚发送的消息\n${'换行内容\n' * 12}',
      );
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(controller.sent, 1);
      expectLatestBottom(tester, 'sent-1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quoted multiline send recalibrates after acknowledgement clears composer',
    (tester) async {
      final controller = SendScrollController()
        ..acknowledgement = Completer<void>();
      await mountSendChat(tester, controller);
      await swipe(tester, 'history-0');
      await tester.enterText(
        find.byType(TextField),
        '引用后发送\n${'输入中的多行内容\n' * 15}',
      );
      await tester.tap(find.byTooltip('发送'));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const ValueKey('composer-reply-preview')),
        findsOneWidget,
      );
      controller.acknowledgement!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('composer-reply-preview')),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expectLatestBottom(tester, 'sent-1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('voice send follows after its covering sheet closes', (
    tester,
  ) async {
    final controller = SendScrollController();
    await mountSendChat(tester, controller);
    await swipe(tester, 'history-0');
    await tester.tap(find.byTooltip('变声语音'));
    await tester.pumpAndSettle();
    final sheet = find.byType(VoiceComposer);
    await tester.widget<VoiceComposer>(sheet).onSend(Uint8List(48));
    await tester.pump();
    tester.view.physicalSize = const Size(820, 700);
    await tester.pump();
    Navigator.of(tester.element(sheet)).pop();
    await tester.pumpAndSettle();
    expectLatestBottom(tester, 'sent-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'consecutive reduced-motion sends and same-length ACK reorder keep real tail visible',
    (tester) async {
      final controller = SendScrollController();
      await mountSendChat(tester, controller, reduceMotion: true);
      await tester.enterText(find.byType(TextField), '第一条');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expectLatestBottom(tester, 'sent-1');
      await tester.enterText(find.byType(TextField), '超高的新消息\n${'多行\n' * 45}');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expectLatestBottom(tester, 'sent-2');
      final before = controller.messages;
      controller.messages = [
        ...before.take(before.length - 2),
        before.last,
        before[before.length - 2],
      ];
      controller.changed();
      await tester.pumpAndSettle();
      expectLatestBottom(tester, 'sent-1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delayed content load after send returns still follows new message',
    (tester) async {
      final controller = SendScrollController()..deferAppend = true;
      await mountSendChat(tester, controller);
      await tester.enterText(find.byType(TextField), '晚到的本机消息\n${'内容\n' * 10}');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      controller.appendPending!();
      await tester.pumpAndSettle();
      expectLatestBottom(tester, 'sent-1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual history browsing is not interrupted by incoming messages',
    (tester) async {
      final controller = SendScrollController();
      await mountSendChat(tester, controller);
      await tester.enterText(find.byType(TextField), '先到底部');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expectLatestBottom(tester, 'sent-1');
      await tester.drag(find.byType(ListView), const Offset(0, 280));
      await tester.pumpAndSettle();
      final browsingOffset = listScroll(tester).offset;
      expect(listScroll(tester).position.extentAfter, greaterThan(48));
      controller.messages = [
        ...controller.messages,
        note('incoming', text: '别人发来的消息'),
      ];
      controller.changed();
      await tester.pumpAndSettle();
      expect(listScroll(tester).offset, closeTo(browsingOffset, 1));
      expect(
        find.byKey(const ValueKey('message-metadata-incoming')).hitTestable(),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sending cancels a quote seek instead of stopping at the quoted row',
    (tester) async {
      final controller = SendScrollController();
      controller.messages = [
        note('reply', reply: 'history-70'),
        ...controller.messages,
      ];
      await mountSendChat(tester, controller);
      await tester.enterText(find.byType(TextField), '发送优先于旧引用定位');
      tester
          .widget<MessageReplyPreview>(
            find.byKey(const ValueKey('message-reply-reply')),
          )
          .onTap!();
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expectLatestBottom(tester, 'sent-1');
      expect(
        find.byWidgetPredicate((w) => w is MessageBubble && w.highlighted),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual drag cancels pending send scrolling including late ACK cleanup',
    (tester) async {
      final controller = SendScrollController()
        ..acknowledgement = Completer<void>();
      await mountSendChat(tester, controller);
      await tester.enterText(find.byType(TextField), '等待确认的消息');
      await tester.tap(find.byTooltip('发送'));
      await tester.pump(const Duration(milliseconds: 100));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
      );
      await gesture.moveBy(const Offset(0, 130));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final stoppedAt = listScroll(tester).offset;
      controller.acknowledgement!.complete();
      await tester.pumpAndSettle();
      expect(listScroll(tester).offset, closeTo(stoppedAt, 1));
      expect(
        find.byKey(const ValueKey('message-metadata-sent-1')).hitTestable(),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing room cancels old send follow and late completion', (
    tester,
  ) async {
    final controller = SendScrollController()
      ..acknowledgement = Completer<void>();
    await mountSendChat(tester, controller);
    await tester.enterText(find.byType(TextField), '旧群消息');
    await tester.tap(find.byTooltip('发送'));
    await tester.pump(const Duration(milliseconds: 90));
    controller.activeGroup = const Group(
      id: 'new-room',
      server: 'https://example.com',
      name: '新群',
      ownerId: 'device-a',
    );
    controller.messages = [];
    controller.changed();
    controller.acknowledgement!.complete();
    await tester.pumpAndSettle();
    expect(find.text('新群'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'privacy cover cancels send follow and late acknowledgement cannot resume it',
    (tester) async {
      final controller = SendScrollController()
        ..acknowledgement = Completer<void>();
      final visibility = ValueNotifier(true);
      addTearDown(visibility.dispose);
      await mountSendChat(tester, controller, visibility: visibility);
      await tester.enterText(find.byType(TextField), '遮罩前发出的消息');
      await tester.tap(find.byTooltip('发送'));
      await tester.pump(const Duration(milliseconds: 90));
      visibility.value = false;
      await tester.pump();
      final stoppedAt = listScroll(tester).offset;
      controller.acknowledgement!.complete();
      await tester.pump(const Duration(milliseconds: 600));
      expect(listScroll(tester).offset, closeTo(stoppedAt, 1));
      visibility.value = true;
      await tester.pumpAndSettle();
      expect(listScroll(tester).offset, closeTo(stoppedAt, 1));
      expect(
        find.byKey(const ValueKey('message-metadata-sent-1')).hitTestable(),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposing chat during send follow leaves no late scrolling work',
    (tester) async {
      final controller = SendScrollController()
        ..acknowledgement = Completer<void>();
      await mountSendChat(tester, controller);
      await tester.enterText(find.byType(TextField), '离开页面前发出的消息');
      await tester.tap(find.byTooltip('发送'));
      await tester.pump(const Duration(milliseconds: 90));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.acknowledgement!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
