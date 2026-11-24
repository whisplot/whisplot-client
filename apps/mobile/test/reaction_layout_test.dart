import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/emoji_catalog.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/app_appearance.dart';
import 'package:nearlink/services/emoji_recents.dart';
import 'package:nearlink/ui/emoji_glyph.dart';
import 'package:nearlink/ui/message_bubble.dart';
import 'package:nearlink/ui/reaction_picker.dart';
import 'package:nearlink/ui/voice_bubble.dart';

import 'voice_composer_test.dart' show TestPlayer;

ChatMessage sampleMessage({
  List<ReactionSummary> reactions = const [
    ReactionSummary(emoji: '❤️', count: 8, selectedByMe: true),
    ReactionSummary(emoji: '😂', count: 3, selectedByMe: false),
    ReactionSummary(emoji: '🌸', count: 1, selectedByMe: false),
  ],
  bool voice = false,
}) => ChatMessage(
  envelope: const Envelope(
    groupId: 'g',
    messageId: 'layout',
    senderId: 'other',
    nonce: '',
    ciphertext: '',
    signature: '',
  ),
  text: '大家的消息都在中间，长按这条消息试试新的表情回应。',
  senderName: '临时·Q7M4K2',
  createdAt: DateTime(2026, 11, 20, 19, 13).millisecondsSinceEpoch,
  state: 'stored',
  reactions: reactions,
  voice: voice
      ? const VoiceAttachment(
          mediaId: 'voice',
          key: '',
          nonce: '',
          sha256: '',
          byteLength: 100,
          durationMs: 6400,
        )
      : null,
);

void displaySize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget host(
  Widget child, {
  AppPalette palette = AppPalette.warm,
  double scale = 1,
}) => MaterialApp(
  theme: appTheme(palette),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets(
    'recent emoji appear above the full catalog and selection updates locally',
    (tester) async {
      displaySize(tester, const Size(390, 844));
      String? saved = '["🌸","❤️"]';
      final recents = EmojiRecents(
        read: () async => saved,
        write: (value) async => saved = value,
      );
      await recents.load();
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  picked = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ReactionPicker(recents: recents),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final recent = find.byKey(const ValueKey('reaction-recent-🌸'));
      final firstCatalog = find.byKey(
        ValueKey('reaction-grid-${EmojiCatalog.entries.first.emoji}'),
      );
      expect(
        tester.getRect(recent).bottom,
        lessThan(tester.getRect(firstCatalog).top),
      );
      expect(find.text('更多表情'), findsNothing);
      expect(find.text('最近使用'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reaction-recent-❤️')));
      await tester.pumpAndSettle();
      expect(picked, '❤️');
      expect(recents.values, ['❤️', '🌸']);
      expect(saved, '["❤️","🌸"]');
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reaction-recent-❤️')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final palette in AppPalette.values) {
    testWidgets(
      '${palette.name}: ID, reactions and time are inside the centered bubble',
      (tester) async {
        displaySize(tester, const Size(390, 844));
        final message = sampleMessage();
        await tester.pumpWidget(
          host(
            MessageBubble(message: message, onReaction: (_) async {}),
            palette: palette,
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('message-card-layout'));
        for (final key in [
          'message-id-layout',
          'message-reactions-layout',
          'message-metadata-layout',
        ]) {
          expect(
            find.descendant(of: card, matching: find.byKey(ValueKey(key))),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(of: card, matching: find.text(message.text)),
          findsOneWidget,
        );
        final body = tester.widget<Text>(find.text(message.text));
        expect(body.textAlign, TextAlign.justify);
        expect(find.byType(CircleAvatar), findsNothing);
        final copy = find.byKey(const ValueKey('copy-message-layout'));
        expect(find.descendant(of: card, matching: copy), findsNothing);
        final cardRect = tester.getRect(card);
        expect(cardRect.center.dx, closeTo(195, .1));
        expect(tester.getRect(copy).top, greaterThanOrEqualTo(cardRect.bottom));
        for (final reaction in message.reactions) {
          final rect = tester.getRect(
            find.byKey(ValueKey('reaction-layout-${reaction.emoji}')),
          );
          expect(cardRect.contains(rect.topLeft), isTrue);
          expect(cardRect.contains(rect.bottomRight), isTrue);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'fifty reactions wrap within a narrow bubble at large text scale',
    (tester) async {
      displaySize(tester, const Size(320, 480));
      final reactions = [
        for (final entry in EmojiCatalog.entries.take(50))
          ReactionSummary(emoji: entry.emoji, count: 1, selectedByMe: false),
      ];
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: sampleMessage(reactions: reactions),
            onReaction: (_) async {},
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      final card = tester.getRect(
        find.byKey(const ValueKey('message-card-layout')),
      );
      for (final reaction in reactions) {
        final pill = tester.getRect(
          find.byKey(ValueKey('reaction-layout-${reaction.emoji}')),
        );
        expect(pill.left, greaterThanOrEqualTo(card.left));
        expect(pill.right, lessThanOrEqualTo(card.right));
      }
      expect(card.center.dx, closeTo(160, .1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'voice content and its reactions fit inside the bubble without a text copy button',
    (tester) async {
      displaySize(tester, const Size(320, 480));
      final player = TestPlayer();
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: sampleMessage(voice: true),
            content: VoiceBubble(
              durationMs: 6400,
              loader: () async => Uint8List(100),
              player: player,
            ),
            onReaction: (_) async {},
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('复制消息'), findsNothing);
      final card = find.byKey(const ValueKey('message-card-layout'));
      expect(
        find.descendant(of: card, matching: find.text('变声语音 · 6.4 秒')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey('reaction-layout-🌸')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long press expands a lazy offline grid, searches both languages and selects a rich emoji',
    (tester) async {
      displaySize(tester, const Size(390, 844));
      String? picked;
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: sampleMessage(),
            onReaction: (emoji) async => picked = emoji,
          ),
        ),
      );
      await tester.longPress(find.byKey(const ValueKey('message-card-layout')));
      await tester.pumpAndSettle();
      expect(find.byType(ReactionPicker), findsOneWidget);
      expect(find.byKey(const ValueKey('reaction-full-grid')), findsOneWidget);
      expect(find.text('更多表情'), findsNothing);
      expect(find.text('回应这条消息'), findsNothing);
      expect(
        find.byType(EmojiGlyph).evaluate().length,
        lessThan(150),
        reason: 'The full catalog must be built lazily',
      );
      await tester.enterText(
        find.byKey(const ValueKey('reaction-search')),
        'rocket',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reaction-grid-🚀')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reaction-search')),
        '樱花',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reaction-grid-🌸')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reaction-grid-🌸')));
      await tester.pumpAndSettle();
      expect(picked, '🌸');
      expect(find.byType(ReactionPicker), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search and categories combine, empty searches recover, and large-text picker stays scrollable',
    (tester) async {
      displaySize(tester, const Size(320, 480));
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: sampleMessage(reactions: []),
            onReaction: (_) async {},
          ),
          scale: 2,
        ),
      );
      await tester.longPress(find.byKey(const ValueKey('message-card-layout')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reaction-search')),
        '不存在的表情xyz',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reaction-empty')), findsOneWidget);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      final category = find.byKey(const ValueKey('reaction-category-表情与情感'));
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(category).isSelected, isTrue);
      final gridGlyphs = find.descendant(
        of: find.byType(SliverGrid),
        matching: find.byType(EmojiGlyph),
      );
      expect(gridGlyphs, findsWidgets);
      for (final glyph in tester.widgetList<EmojiGlyph>(gridGlyphs)) {
        expect(EmojiCatalog.find(glyph.emoji)!.category, '表情与情感');
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read-only policy changing while picker is open blocks the selected reaction',
    (tester) async {
      final allowed = ValueNotifier(true);
      addTearDown(allowed.dispose);
      var count = 0;
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<bool>(
            valueListenable: allowed,
            builder: (_, enabled, _) => MessageBubble(
              message: sampleMessage(),
              reactionsEnabled: enabled,
              onReaction: (_) async => count++,
            ),
          ),
        ),
      );
      await tester.longPress(find.byKey(const ValueKey('message-card-layout')));
      await tester.pumpAndSettle();
      allowed.value = false;
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('reaction-search')),
        '红心',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reaction-grid-❤️')));
      await tester.pumpAndSettle();
      expect(count, 0);
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('reaction-layout-❤️')))
            .onTap,
        isNull,
      );
      await tester.longPress(find.byKey(const ValueKey('message-card-layout')));
      await tester.pumpAndSettle();
      expect(find.byType(ReactionPicker), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search with the keyboard open remains usable on a small display',
    (tester) async {
      displaySize(tester, const Size(320, 480));
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: sampleMessage(reactions: []),
            onReaction: (_) async {},
          ),
        ),
      );
      await tester.longPress(find.byKey(const ValueKey('message-card-layout')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reaction-search')),
        '樱花',
      );
      await tester.pumpAndSettle();
      final found = find.byKey(const ValueKey('reaction-grid-🌸'));
      await tester.ensureVisible(found);
      await tester.pumpAndSettle();
      expect(tester.getRect(found).bottom, lessThanOrEqualTo(260));
      expect(tester.takeException(), isNull);
    },
  );
}
