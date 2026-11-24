import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/app_appearance.dart';
import 'package:nearlink/services/emoji_recents.dart';
import 'package:nearlink/ui/message_bubble.dart';
import 'package:nearlink/ui/reaction_burst.dart';
import 'package:nearlink/ui/reaction_picker.dart';

const _body = 'A private fixture message.';
const _heart = '♥️';

ChatMessage _message({
  String id = 'motion',
  int count = 1,
  bool selected = false,
}) => ChatMessage(
  envelope: Envelope(
    groupId: 'motion-group',
    messageId: id,
    senderId: 'fixture-sender',
    nonce: '',
    ciphertext: '',
    signature: '',
  ),
  text: _body,
  senderName: '临时·FIXTURE',
  createdAt: 1,
  state: 'stored',
  reactions: count == 0
      ? const []
      : [ReactionSummary(emoji: _heart, count: count, selectedByMe: selected)],
);

Widget _host(
  Widget child, {
  AppPalette palette = AppPalette.warm,
  bool reducedMotion = false,
  bool ticking = true,
}) => MaterialApp(
  theme: appTheme(palette),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: TickerMode(enabled: ticking, child: child),
    ),
  ),
);

Widget _bubble({
  String id = 'motion',
  int count = 1,
  bool selected = false,
  bool enabled = true,
  Future<void> Function()? onQuickLike,
  Future<void> Function(String)? onReaction,
}) => MessageBubble(
  message: _message(id: id, count: count, selected: selected),
  reactionsEnabled: enabled,
  onQuickLike: onQuickLike,
  onReaction: onReaction ?? (_) async {},
);

Finder _badge([String id = 'motion']) =>
    find.byKey(ValueKey('reaction-$id-$_heart'));
Finder _effect([String id = 'motion']) =>
    find.byKey(ValueKey('reaction-effect-$id'));
Finder _card([String id = 'motion']) =>
    find.byKey(ValueKey('message-card-$id'));

BoxDecoration _badgeDecoration(WidgetTester tester, Finder badge) => tester
    .widgetList<AnimatedContainer>(
      find.ancestor(of: badge, matching: find.byType(AnimatedContainer)),
    )
    .map((widget) => widget.decoration)
    .whereType<BoxDecoration>()
    .single;

Future<void> _doubleTap(WidgetTester tester, [String id = 'motion']) async {
  final body = find.descendant(of: _card(id), matching: find.text(_body));
  await tester.tap(body);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(body);
  // Completion and the post-layout destination lookup occur on separate frames.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void _semanticTest(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(description, (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      semantics.dispose();
    }
  });
}

void main() {
  for (final palette in AppPalette.values) {
    _semanticTest(
      '${palette.name}: own and other reactions have identical orange appearance and semantics',
      (tester) async {
        Rect? previousRect;
        for (final selected in [false, true, false]) {
          await tester.pumpWidget(
            _host(_bubble(count: 2, selected: selected), palette: palette),
          );
          await tester.pumpAndSettle();
          final badge = _badge();
          expect(_badgeDecoration(tester, badge).color, reactionOrange);
          final count = tester.widget<Text>(
            find.descendant(of: badge, matching: find.text('2')),
          );
          expect(count.style?.color, reactionInk);
          final accessible = find.semantics.byLabel(RegExp('红桃，2 人回应'));
          expect(accessible, findsOneWidget);
          expect(
            accessible.evaluate().single.flagsCollection.isSelected,
            Tristate.none,
          );
          expect(find.semantics.byLabel(RegExp('取消回应|我的回应')), findsNothing);
          expect(_effect(), findsNothing);
          final rect = tester.getRect(badge);
          if (previousRect != null) expect(rect, previousRect);
          previousRect = rect;
        }
        expect(tester.takeException(), isNull);
      },
    );

    _semanticTest(
      '${palette.name}: picker never marks the device reaction or labels it as cancellation',
      (tester) async {
        final recents = EmojiRecents(
          read: () async => '[]',
          write: (_) async {},
        );
        await recents.load();
        for (final selected in [_heart, null]) {
          await tester.pumpWidget(
            _host(
              ReactionPicker(selectedEmoji: selected, recents: recents),
              palette: palette,
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('reaction-search')),
            _heart,
          );
          await tester.pumpAndSettle();
          final option = find.byKey(const ValueKey('reaction-grid-♥️'));
          expect(option, findsOneWidget);
          final material = tester.widget<Material>(
            find.ancestor(of: option, matching: find.byType(Material)).first,
          );
          expect(material.color, Colors.transparent);
          final accessible = find.semantics.byLabel('红桃，回应');
          expect(accessible, findsOneWidget);
          expect(
            accessible.evaluate().single.flagsCollection.isSelected,
            Tristate.none,
          );
          expect(find.semantics.byLabel(RegExp('取消回应')), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('initial history and ownership-only updates stay still', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_bubble(count: 8)));
    await tester.pump(const Duration(milliseconds: 160));
    expect(_effect(), findsNothing);
    await tester.pumpWidget(_host(_bubble(count: 8, selected: true)));
    await tester.pump(const Duration(milliseconds: 160));
    expect(_effect(), findsNothing);
    await tester.pumpWidget(_host(_bubble(count: 7, selected: false)));
    await tester.pump(const Duration(milliseconds: 160));
    expect(_effect(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local and remote count increases play the same bounded effect', (
    tester,
  ) async {
    Widget pair(int count) => _host(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _bubble(id: 'local', count: count, selected: true),
          ),
          Expanded(
            child: _bubble(id: 'remote', count: count),
          ),
        ],
      ),
    );
    await tester.pumpWidget(pair(1));
    await tester.pumpAndSettle();
    final localRect = tester.getRect(_card('local'));
    final remoteRect = tester.getRect(_card('remote'));
    expect(find.byType(ReactionBurst), findsNothing);
    await tester.pumpWidget(pair(2));
    // The post-layout anchor callback starts the controller; establish the
    // ticker's first frame before advancing its elapsed animation time.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final local = tester.widget<ReactionBurst>(_effect('local'));
    final remote = tester.widget<ReactionBurst>(_effect('remote'));
    expect(local.emoji, _heart);
    expect(remote.emoji, local.emoji);
    expect(local.progress, inExclusiveRange(0, 1));
    expect(remote.progress, closeTo(local.progress, .00001));
    expect(remote.target, local.target);
    expect(tester.getRect(_card('local')), localRect);
    expect(tester.getRect(_card('remote')), remoteRect);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ReactionBurst), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'successful repeated quick likes replay without changing layout or blocking badges',
    (tester) async {
      var likes = 0, reactions = 0;
      await tester.pumpWidget(
        _host(
          _bubble(
            onQuickLike: () async => likes++,
            onReaction: (_) async => reactions++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = tester.getRect(_card());
      final copy = tester.getRect(
        find.byKey(const ValueKey('copy-message-motion')),
      );
      await _doubleTap(tester);
      expect(likes, 1);
      expect(_effect(), findsOneWidget);
      expect(tester.getRect(_card()), card);
      expect(
        tester.getRect(find.byKey(const ValueKey('copy-message-motion'))),
        copy,
      );
      await tester.tap(_badge());
      await tester.pump();
      expect(
        reactions,
        1,
        reason: 'The visual effect must ignore pointer input',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(_effect(), findsNothing);
      await _doubleTap(tester);
      expect(likes, 2);
      expect(_effect(), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(_effect(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion, disabled tickers and read-only mode suppress or stop effects',
    (tester) async {
      await tester.pumpWidget(_host(_bubble(count: 1)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_host(_bubble(count: 2)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_effect(), findsOneWidget);
      await tester.pumpWidget(_host(_bubble(count: 2), reducedMotion: true));
      expect(_effect(), findsNothing);
      await tester.pumpWidget(_host(_bubble(count: 3), reducedMotion: true));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_effect(), findsNothing);
      await tester.pumpWidget(_host(_bubble(count: 3)));
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        _effect(),
        findsNothing,
        reason: 'Re-enabling motion must not replay history',
      );
      await tester.pumpWidget(_host(_bubble(count: 4), ticking: false));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_effect(), findsNothing);
      await tester.pumpWidget(_host(_bubble(count: 4)));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_effect(), findsNothing);
      await tester.pumpWidget(_host(_bubble(count: 5, enabled: false)));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_effect(), findsNothing);
      expect(tester.widget<InkWell>(_badge()).onTap, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed quick-like and reaction actions never celebrate success',
    (tester) async {
      await tester.pumpWidget(
        _host(
          _bubble(
            onQuickLike: () async =>
                throw const FormatException('quick-like failed'),
            onReaction: (_) async =>
                throw const FormatException('reaction failed'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _doubleTap(tester);
      expect(_effect(), findsNothing);
      expect(find.text('quick-like failed'), findsOneWidget);
      await tester.tap(_badge());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_effect(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late completion and disposal cannot animate a different message',
    (tester) async {
      final pending = Completer<void>();
      await tester.pumpWidget(
        _host(_bubble(onQuickLike: () => pending.future)),
      );
      await tester.pumpAndSettle();
      await _doubleTap(tester);
      expect(_effect(), findsNothing);
      await tester.pumpWidget(_host(_bubble(id: 'replacement')));
      pending.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ReactionBurst), findsNothing);
      await tester.pumpWidget(_host(_bubble(id: 'replacement', count: 2)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_effect('replacement'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removing an own reaction does not play an addition effect', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      _host(_bubble(selected: true, onReaction: (_) async => toggles++)),
    );
    await tester.pumpAndSettle();
    await tester.tap(_badge());
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(toggles, 1);
    expect(_effect(), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
