import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/message_bubble.dart';
import 'package:nearlink/ui/reaction_picker.dart';
import 'package:nearlink/ui/voice_bubble.dart';
import 'package:nearlink/ui/voice_composer.dart';

import 'mobile_ui_test.dart' show UiController, mobileSize;
import 'voice_composer_test.dart' show TestPlayer;

const _group = Group(
  id: 'gesture-group',
  server: 'https://example.com',
  name: '引用测试',
  ownerId: 'device-a',
);
ChatMessage note(
  String id, {
  String? text,
  String? reply,
  bool voice = false,
  bool expired = false,
  List<ReactionSummary> reactions = const [],
}) => ChatMessage(
  envelope: Envelope(
    groupId: _group.id,
    messageId: id,
    senderId: 'device-a',
    nonce: '',
    ciphertext: '',
    signature: '',
  ),
  text: text ?? '正文 $id',
  senderName: '临时·PRIVATE',
  createdAt: 1,
  state: 'stored',
  expiredOwnId: expired,
  replyToMessageId: reply,
  reactions: reactions,
  voice: voice
      ? const VoiceAttachment(
          mediaId: 'voice',
          key: '',
          nonce: '',
          sha256: '',
          byteLength: 32,
          durationMs: 3000,
        )
      : null,
);

class ReplyUiController extends UiController {
  ReplyUiController() {
    server = _group.server;
    activeGroup = _group;
    groups = [_group];
    messages = [note('first'), note('second')];
  }
  final sends = <({String text, String? reply, String? group, bool voice})>[];
  final likes = <({String message, String? group})>[];
  final toggles = <({String message, String emoji, String? group})>[];
  Completer<void>? waiting;
  bool fail = false;
  @override
  Future<void> send(
    String text, {
    String? replyToMessageId,
    String? expectedStorageId,
  }) async {
    sends.add((
      text: text,
      reply: replyToMessageId,
      group: expectedStorageId,
      voice: false,
    ));
    await waiting?.future;
    if (fail) throw const FormatException('发送未完成');
  }

  @override
  Future<void> sendVoice(
    Uint8List wav, {
    String? replyToMessageId,
    String? expectedStorageId,
  }) async {
    sends.add((
      text: '',
      reply: replyToMessageId,
      group: expectedStorageId,
      voice: true,
    ));
    if (fail) throw const FormatException('发送未完成');
  }

  @override
  Future<void> quickLike(String messageId, {String? expectedStorageId}) async =>
      likes.add((message: messageId, group: expectedStorageId));
  @override
  Future<void> toggleReaction(
    String messageId,
    String emoji, {
    String? expectedStorageId,
  }) async =>
      toggles.add((message: messageId, emoji: emoji, group: expectedStorageId));
}

Future<void> doubleTapAt(
  WidgetTester tester,
  Offset position, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  await tester.tapAt(position, kind: kind);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(position, kind: kind);
  await tester.pumpAndSettle();
}

Future<void> doubleTap(WidgetTester tester, Finder finder) =>
    doubleTapAt(tester, tester.getCenter(finder));

Future<void> swipe(
  WidgetTester tester,
  String id, {
  double distance = -150,
}) async {
  await tester.drag(
    find.byKey(ValueKey('message-card-$id')),
    Offset(distance, 0),
  );
  await tester.pumpAndSettle();
}

Widget bubbleHost(Widget bubble) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: bubble)),
);
Finder draft() => find.byKey(const ValueKey('composer-reply-preview'));
Future<void> mountChat(
  WidgetTester tester,
  ReplyUiController controller,
) async {
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(home: ChatPage(controller: controller)));
  await tester.pumpAndSettle();
}

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      '$kind double-click likes card padding, metadata and quoted content',
      (tester) async {
        var likes = 0;
        await tester.pumpWidget(
          bubbleHost(
            MessageBubble(
              message: note('reply', reply: 'first'),
              replyMessage: note('first'),
              onReaction: (_) async {},
              onQuickLike: () async => likes++,
              onReply: () {},
            ),
          ),
        );
        final card = tester.getRect(
          find.byKey(const ValueKey('message-card-reply')),
        );
        final targets = [
          // Previously only the two Text widgets had a double-tap handler.
          card.topCenter + const Offset(0, 3),
          card.centerLeft + const Offset(3, 0),
          tester.getCenter(
            find.byKey(const ValueKey('message-metadata-reply')),
          ),
          tester.getCenter(find.byKey(const ValueKey('message-reply-reply'))),
          tester.getCenter(find.text('正文 reply')),
        ];
        for (var i = 0; i < targets.length; i++) {
          await doubleTapAt(tester, targets[i], kind: kind);
          expect(likes, i + 1);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a primary-button mouse drag can quote without removing the row',
    (tester) async {
      var replies = 0;
      await tester.pumpWidget(
        bubbleHost(
          MessageBubble(
            message: note('first'),
            onReaction: (_) async {},
            onReply: () => replies++,
          ),
        ),
      );
      final card = find.byKey(const ValueKey('message-card-first'));
      await tester.drag(
        card,
        const Offset(-150, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(replies, 1);
      expect(card, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quote draft refreshes an expired own ID and never resolves across groups',
    (tester) async {
      final c = ReplyUiController();
      await mountChat(tester, c);
      await swipe(tester, 'first');
      expect(
        find.descendant(of: draft(), matching: find.text('PRIVATE')),
        findsOneWidget,
      );
      c.messages = [note('first', expired: true), note('second')];
      c.changed();
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: draft(), matching: find.text('已过期 ID')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: draft(), matching: find.text('PRIVATE')),
        findsNothing,
      );
      c.messages = [
        note('reply', reply: 'first'),
        ChatMessage(
          envelope: const Envelope(
            groupId: 'different-group',
            messageId: 'first',
            senderId: 'someone',
            nonce: '',
            ciphertext: '',
            signature: '',
          ),
          text: '另一个群的记录',
          createdAt: 1,
          state: 'stored',
        ),
      ];
      c.changed();
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('message-reply-reply'));
      expect(
        find.descendant(of: preview, matching: find.text('引用消息未在本机保存')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: preview, matching: find.text('另一个群的记录')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'left swipe replies once on release, short or right drags cancel and spring back',
    (tester) async {
      var replies = 0;
      await tester.pumpWidget(
        bubbleHost(
          MessageBubble(
            message: note('first'),
            onReaction: (_) async {},
            onReply: () => replies++,
          ),
        ),
      );
      final card = find.byKey(const ValueKey('message-card-first'));
      final before = tester.getRect(card);
      await swipe(tester, 'first', distance: -35);
      await swipe(tester, 'first', distance: 150);
      expect(replies, 0);
      expect(tester.getRect(card), before);
      final gesture = await tester.startGesture(tester.getCenter(card));
      await gesture.moveBy(const Offset(-25, 0));
      await gesture.moveBy(const Offset(-110, 0));
      await tester.pump();
      expect(replies, 0);
      expect(tester.getRect(card).left, lessThan(before.left));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(replies, 1);
      expect(tester.getRect(card), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('vertical scrolling does not trigger reply', (tester) async {
    var replies = 0;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              for (var i = 0; i < 20; i++)
                MessageBubble(
                  message: note('$i'),
                  onReaction: (_) async {},
                  onReply: () => replies++,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('message-card-0')),
      const Offset(0, -170),
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(replies, 0);
  });

  testWidgets(
    'double taps request an idempotent like while chips retain their separate action',
    (tester) async {
      var likes = 0, toggles = 0;
      final liked = ValueNotifier(false);
      addTearDown(liked.dispose);
      await tester.pumpWidget(
        bubbleHost(
          ValueListenableBuilder<bool>(
            valueListenable: liked,
            builder: (_, selected, _) => MessageBubble(
              message: note(
                'first',
                reactions: selected
                    ? const [
                        ReactionSummary(
                          emoji: '♥️',
                          count: 1,
                          selectedByMe: true,
                        ),
                      ]
                    : [],
              ),
              onReaction: (_) async => toggles++,
              onQuickLike: () async {
                likes++;
                liked.value = true;
              },
            ),
          ),
        ),
      );
      await doubleTap(tester, find.text('正文 first'));
      expect(likes, 1);
      await doubleTap(tester, find.text('正文 first'));
      expect(likes, 2);
      await tester.tap(find.byKey(const ValueKey('reaction-first-♥️')));
      await tester.pumpAndSettle();
      expect(toggles, 1);
      expect(likes, 2);
      await doubleTapAt(
        tester,
        tester.getCenter(find.byKey(const ValueKey('reaction-first-♥️'))),
        kind: PointerDeviceKind.mouse,
      );
      expect(likes, 2);
      expect(toggles, 3);
      await tester.longPress(find.text('正文 first'));
      await tester.pumpAndSettle();
      expect(find.byType(ReactionPicker), findsOneWidget);
      expect(likes, 2);
    },
  );

  testWidgets('voice playback buttons do not trigger quick likes', (
    tester,
  ) async {
    final player = TestPlayer();
    var likes = 0;
    await tester.pumpWidget(
      bubbleHost(
        MessageBubble(
          message: note('voice', voice: true),
          onReaction: (_) async {},
          onQuickLike: () async => likes++,
          content: VoiceBubble(
            durationMs: 3000,
            loader: () async => Uint8List(48),
            player: player,
          ),
        ),
      ),
    );
    await doubleTap(tester, find.widgetWithText(TextButton, '变声语音 · 3.0 秒'));
    expect(likes, 0);
    expect(player.plays, greaterThan(0));
    await doubleTap(tester, find.byKey(const ValueKey('message-id-voice')));
    expect(likes, 1);
  });

  testWidgets('read-only policy cancels a swipe and leaves copying available', (
    tester,
  ) async {
    var replies = 0, likes = 0;
    final allowed = ValueNotifier(true);
    addTearDown(allowed.dispose);
    await tester.pumpWidget(
      bubbleHost(
        ValueListenableBuilder<bool>(
          valueListenable: allowed,
          builder: (_, enabled, _) => MessageBubble(
            message: note('first'),
            reactionsEnabled: enabled,
            onReaction: (_) async {},
            onReply: () => replies++,
            onQuickLike: () async => likes++,
          ),
        ),
      ),
    );
    final card = find.byKey(const ValueKey('message-card-first'));
    final before = tester.getRect(card);
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(-140, 0));
    allowed.value = false;
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await doubleTap(tester, find.text('正文 first'));
    expect(replies, 0);
    expect(likes, 0);
    expect(tester.getRect(card), before);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('copy-message-first')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'reply preview uses the current hidden ID, handles missing records, and stays centered',
    (tester) async {
      await mobileSize(tester);
      final source = note('first', expired: true);
      await tester.pumpWidget(
        bubbleHost(
          Column(
            children: [
              MessageBubble(
                message: note('reply', reply: 'first'),
                replyMessage: source,
                onReaction: (_) async {},
              ),
              MessageBubble(
                message: note('missing', reply: 'unknown'),
                onReaction: (_) async {},
              ),
              MessageBubble(
                message: note('voice-reply', reply: 'voice'),
                replyMessage: note('voice', voice: true, expired: true),
                onReaction: (_) async {},
              ),
            ],
          ),
        ),
      );
      final preview = find.byKey(const ValueKey('message-reply-reply'));
      expect(
        find.descendant(of: preview, matching: find.text('已过期 ID')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: preview, matching: find.text('临时·PRIVATE')),
        findsNothing,
      );
      expect(find.text('引用消息未在本机保存'), findsOneWidget);
      expect(find.text('变声语音'), findsOneWidget);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('message-card-reply')))
            .center
            .dx,
        closeTo(180, .1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'swiping focuses the composer; text sends only the message ID and expected group',
    (tester) async {
      final c = ReplyUiController();
      await mountChat(tester, c);
      await swipe(tester, 'first');
      expect(draft(), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), '引用后的文字');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(c.sends.single, (
        text: '引用后的文字',
        reply: 'first',
        group: _group.storageId,
        voice: false,
      ));
      expect(draft(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed text preserves quote and draft, and cancel only removes quote',
    (tester) async {
      final c = ReplyUiController()..fail = true;
      await mountChat(tester, c);
      await swipe(tester, 'first');
      await tester.enterText(find.byType(TextField), '保留的草稿');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(draft(), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留的草稿',
      );
      await tester.tap(find.byTooltip('取消引用'));
      await tester.pumpAndSettle();
      expect(draft(), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留的草稿',
      );
    },
  );

  testWidgets(
    'sending preserves a new quote selected while the previous send is pending',
    (tester) async {
      final c = ReplyUiController()..waiting = Completer<void>();
      await mountChat(tester, c);
      await swipe(tester, 'first');
      await tester.enterText(find.byType(TextField), '发送中');
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('message-card-second')),
        const Offset(-150, 0),
      );
      await tester.pump(const Duration(milliseconds: 250));
      c.waiting!.complete();
      await tester.pumpAndSettle();
      expect(c.sends.single.reply, 'first');
      expect(
        find.descendant(of: draft(), matching: find.text('正文 second')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'switching group clears quote and a late send cannot clear the new draft',
    (tester) async {
      final c = ReplyUiController()..waiting = Completer<void>();
      await mountChat(tester, c);
      await swipe(tester, 'first');
      await tester.enterText(find.byType(TextField), '相同文字');
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      c.activeGroup = const Group(
        id: 'other',
        server: 'https://example.com',
        name: '另一个群',
        ownerId: 'device-a',
      );
      c.messages = [];
      c.changed();
      await tester.pump();
      expect(draft(), findsNothing);
      await tester.enterText(find.byType(TextField), '相同文字');
      c.waiting!.complete();
      await tester.pumpAndSettle();
      expect(c.sends.single.group, _group.storageId);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '相同文字',
      );
    },
  );

  testWidgets(
    'quick like and long-press selection retain the originating group',
    (tester) async {
      final c = ReplyUiController();
      await mountChat(tester, c);
      await doubleTap(tester, find.text('正文 first'));
      expect(c.likes.single, (message: 'first', group: _group.storageId));
      await tester.longPress(find.text('正文 first'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reaction-search')),
        '樱花',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reaction-grid-🌸')));
      await tester.pumpAndSettle();
      expect(c.toggles.single, (
        message: 'first',
        emoji: '🌸',
        group: _group.storageId,
      ));
    },
  );

  testWidgets(
    'voice send callback carries its quote and refuses a later group switch',
    (tester) async {
      final c = ReplyUiController();
      await mountChat(tester, c);
      await swipe(tester, 'first');
      await tester.tap(find.byTooltip('变声语音'));
      await tester.pumpAndSettle();
      final onSend = tester
          .widget<VoiceComposer>(find.byType(VoiceComposer))
          .onSend;
      c.fail = true;
      await expectLater(onSend(Uint8List(48)), throwsFormatException);
      expect(draft(), findsOneWidget);
      c.fail = false;
      await onSend(Uint8List(48));
      await tester.pump();
      expect(c.sends.last, (
        text: '',
        reply: 'first',
        group: _group.storageId,
        voice: true,
      ));
      expect(draft(), findsNothing);
      c.activeGroup = const Group(
        id: 'other',
        server: 'https://example.com',
        name: '另一群',
        ownerId: 'device-a',
      );
      c.changed();
      await tester.pump();
      final count = c.sends.length;
      await expectLater(onSend(Uint8List(48)), throwsFormatException);
      expect(c.sends.length, count);
    },
  );
}
