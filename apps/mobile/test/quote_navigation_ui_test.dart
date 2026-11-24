import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/message_bubble.dart';
import 'package:nearlink/ui/voice_bubble.dart';

import 'message_gestures_reply_test.dart'
    show ReplyUiController, note, swipe, bubbleHost, doubleTapAt;

Future<void> size(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 650);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

Future<void> mount(
  WidgetTester tester,
  ReplyUiController controller, {
  bool reduceMotion = false,
}) async {
  await size(tester);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: ChatPage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollController scroll(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

Finder card(String id) => find.byKey(ValueKey('message-card-$id'));
Finder quote(String id) => find.byKey(ValueKey('message-reply-$id'));
Finder bubble(String id) => find.byWidgetPredicate(
  (w) => w is MessageBubble && w.message.envelope.messageId == id,
);

Future<void> end(WidgetTester tester, String lastId) async {
  for (var i = 0; i < 12; i++) {
    final controller = scroll(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    if (quote(lastId).hitTestable().evaluate().isNotEmpty) return;
  }
  fail('last reply did not become visible');
}

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      '$kind clickable quote single-tap opens; double-tap only likes',
      (tester) async {
        var opened = 0, liked = 0;
        await tester.pumpWidget(
          bubbleHost(
            MessageBubble(
              message: note('reply', reply: 'source'),
              replyMessage: note('source'),
              onOpenReply: () => opened++,
              onQuickLike: () async => liked++,
              onReaction: (_) async {},
            ),
          ),
        );
        await tester.tap(quote('reply'), kind: kind);
        await tester.pump(kDoubleTapTimeout);
        await tester.pumpAndSettle();
        expect(opened, 1);
        expect(liked, 0);
        opened = 0;
        await doubleTapAt(tester, tester.getCenter(quote('reply')), kind: kind);
        await tester.pump(kDoubleTapTimeout);
        await tester.pumpAndSettle();
        expect(opened, 0);
        expect(liked, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('group name leads the title; connection details live on banner', (
    tester,
  ) async {
    final c = ReplyUiController();
    await mount(tester, c);
    final title = tester.widget<Text>(
      find.byKey(const ValueKey('chat-group-name')),
    );
    final id = tester.widget<Text>(
      find.byKey(const ValueKey('chat-current-id')),
    );
    expect(title.data, c.activeGroup!.name);
    expect(title.style!.fontSize, 26);
    expect(id.style!.fontSize, 16);
    expect(id.data, isNot(contains('临时')));
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('连接状态'), findsNothing);
    await tester.tapAt(const Offset(10, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正在恢复连接 · 本机可继续编辑和排队'));
    await tester.pumpAndSettle();
    expect(find.text('连接状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'far quote locates an unmounted variable-height row, reduce=$reduceMotion',
      (tester) async {
        final c = ReplyUiController();
        c.messages = [
          for (var i = 0; i < 100; i++)
            note(
              'row-$i',
              text: '第 $i 条。${'长短不同的消息内容。' * (i % 13)}',
              reply: i == 99 ? 'row-4' : null,
            ),
        ];
        await mount(tester, c, reduceMotion: reduceMotion);
        await end(tester, 'row-99');
        expect(card('row-4'), findsNothing);
        await tester.tap(quote('row-99'));
        await tester.pump(kDoubleTapTimeout);
        if (reduceMotion) {
          await tester.pump();
        } else {
          await tester.pump(const Duration(milliseconds: 100));
          expect(scroll(tester).position.isScrollingNotifier.value, isTrue);
        }
        await tester.pumpAndSettle();
        expect(card('row-4').hitTestable(), findsOneWidget);
        expect(
          tester.widget<MessageBubble>(bubble('row-4')).highlighted,
          isTrue,
        );
        expect(c.likes, isEmpty);
        expect(c.toggles, isEmpty);
        await tester.pump(const Duration(milliseconds: 1500));
        await tester.pumpAndSettle();
        expect(
          tester.widget<MessageBubble>(bubble('row-4')).highlighted,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'forward voice quote and repeated requests find one exact target',
    (tester) async {
      final c = ReplyUiController();
      c.messages = [
        note('first', reply: 'voice-target'),
        for (var i = 0; i < 55; i++) note('between-$i'),
        note('voice-target', voice: true),
      ];
      await mount(tester, c);
      final open = tester.widget<MessageReplyPreview>(quote('first')).onTap!;
      open();
      await tester.pump(const Duration(milliseconds: 60));
      open();
      await tester.pumpAndSettle();
      expect(card('voice-target').hitTestable(), findsOneWidget);
      expect(
        tester.widget<MessageBubble>(bubble('voice-target')).highlighted,
        isTrue,
      );
      expect(find.byType(VoiceBubble).hitTestable(), findsOneWidget);
      expect(c.likes, isEmpty);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('composer quote opens original; cancellation stays independent', (
    tester,
  ) async {
    final c = ReplyUiController();
    c.messages = [for (var i = 0; i < 35; i++) note('row-$i')];
    await mount(tester, c);
    await swipe(tester, 'row-0');
    final list = scroll(tester);
    list.jumpTo(list.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(card('row-0'), findsNothing);
    final preview = find.byKey(const ValueKey('composer-reply-preview'));
    await tester.tap(
      find.descendant(of: preview, matching: find.text('正文 row-0')),
    );
    await tester.pumpAndSettle();
    expect(card('row-0').hitTestable(), findsOneWidget);
    expect(preview, findsOneWidget);
    await tester.tap(find.byTooltip('取消引用'));
    await tester.pumpAndSettle();
    expect(preview, findsNothing);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'incoming messages do not pull a located quote back to the bottom',
    (tester) async {
      final c = ReplyUiController();
      c.messages = [
        for (var i = 0; i < 80; i++)
          note('row-$i', reply: i == 79 ? 'row-2' : null),
      ];
      await mount(tester, c);
      await end(tester, 'row-79');
      await tester.tap(quote('row-79'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      final locatedOffset = scroll(tester).offset;
      c.messages = [...c.messages, note('incoming')];
      c.changed();
      await tester.pumpAndSettle();
      expect(scroll(tester).offset, closeTo(locatedOffset, .1));
      expect(card('row-2').hitTestable(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      c.messages = [...c.messages, note('incoming-after-highlight')];
      c.changed();
      await tester.pumpAndSettle();
      expect(scroll(tester).offset, closeTo(locatedOffset, .1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'privacy cover cancels navigation and does not resume it when uncovered',
    (tester) async {
      await size(tester);
      final c = ReplyUiController();
      addTearDown(c.dispose);
      c.messages = [
        note('first', reply: 'target'),
        for (var i = 0; i < 90; i++) note('between-$i'),
        note('target'),
      ];
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: visible,
            child: ChatPage(controller: c),
            builder: (context, enabled, child) =>
                TickerMode(enabled: enabled, child: child!),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(quote('first'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pump(const Duration(milliseconds: 60));
      visible.value = false;
      await tester.pump();
      final stoppedAt = scroll(tester).offset;
      await tester.pump(const Duration(milliseconds: 600));
      expect(scroll(tester).offset, closeTo(stoppedAt, .1));
      visible.value = true;
      await tester.pumpAndSettle();
      expect(scroll(tester).offset, closeTo(stoppedAt, .1));
      expect(
        find.byWidgetPredicate((w) => w is MessageBubble && w.highlighted),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('user dragging during a distant seek takes over scrolling', (
    tester,
  ) async {
    final c = ReplyUiController();
    c.messages = [
      note('first', reply: 'target'),
      for (var i = 0; i < 90; i++) note('between-$i'),
      note('target'),
    ];
    await mount(tester, c);
    await tester.tap(quote('first'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pump(const Duration(milliseconds: 100));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    final stoppedAt = scroll(tester).offset;
    await tester.pump(const Duration(milliseconds: 600));
    expect(scroll(tester).offset, closeTo(stoppedAt, .1));
    expect(card('target').hitTestable(), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is MessageBubble && w.highlighted),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('seeking survives alternating very tall and short rows', (
    tester,
  ) async {
    final c = ReplyUiController();
    c.messages = [
      for (var i = 0; i < 200; i++)
        note(
          'row-$i',
          text: i.isEven || i == 199
              ? '短消息 $i'
              : '第 $i 条长消息\n${'不同高度的内容\n' * 30}',
          reply: i == 199 ? 'row-94' : null,
        ),
    ];
    await mount(tester, c);
    await end(tester, 'row-199');
    expect(card('row-94'), findsNothing);
    await tester.tap(quote('row-199'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(card('row-94').hitTestable(), findsOneWidget);
    expect(tester.widget<MessageBubble>(bubble('row-94')).highlighted, isTrue);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing and cross-room references do not navigate or expose source',
    (tester) async {
      final c = ReplyUiController();
      final foreign = ChatMessage(
        envelope: const Envelope(
          groupId: 'another-room',
          messageId: 'foreign',
          senderId: 'device-b',
          nonce: '',
          ciphertext: '',
          signature: '',
        ),
        text: 'not this room',
        createdAt: 1,
        state: 'stored',
      );
      c.messages = [
        note('missing', reply: 'unknown'),
        note('cross', reply: 'foreign'),
        foreign,
      ];
      await mount(tester, c);
      expect(
        tester.widget<MessageReplyPreview>(quote('missing')).onTap,
        isNull,
      );
      expect(tester.widget<MessageReplyPreview>(quote('cross')).onTap, isNull);
      expect(
        find.descendant(
          of: quote('cross'),
          matching: find.text('not this room'),
        ),
        findsNothing,
      );
      final before = scroll(tester).offset;
      await tester.tap(quote('missing'));
      await tester.pumpAndSettle();
      expect(scroll(tester).offset, before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing room cancels in-flight location and cannot highlight reused ID',
    (tester) async {
      final c = ReplyUiController();
      c.messages = [
        note('first', reply: 'target'),
        for (var i = 0; i < 60; i++) note('between-$i'),
        note('target'),
      ];
      await mount(tester, c);
      await tester.tap(quote('first'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pump(const Duration(milliseconds: 60));
      c.activeGroup = const Group(
        id: 'other-room',
        server: 'https://example.com',
        name: '别的群',
        ownerId: 'device-a',
      );
      c.messages = [
        ChatMessage(
          envelope: const Envelope(
            groupId: 'other-room',
            messageId: 'target',
            senderId: 'device-a',
            nonce: '',
            ciphertext: '',
            signature: '',
          ),
          text: '重名消息',
          createdAt: 1,
          state: 'stored',
        ),
      ];
      c.changed();
      await tester.pumpAndSettle();
      expect(
        tester.widget<MessageBubble>(bubble('target')).highlighted,
        isFalse,
      );
      expect(find.text('别的群'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
