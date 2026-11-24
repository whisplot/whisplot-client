import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/app_appearance.dart';
import 'package:nearlink/ui/message_bubble.dart';
import 'package:nearlink/ui/privacy_shield.dart';
import 'package:nearlink/ui/settings_page.dart';
import 'mobile_ui_test.dart' show UiController, mobileSize;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'theme choice survives recreation without changing identity settings',
    () async {
      FlutterSecureStorage.setMockInitialValues({'identity-seed': 'unchanged'});
      final first = AppAppearance();
      await first.load();
      expect(first.palette, AppPalette.warm);
      await first.select(AppPalette.black);
      first.dispose();
      final second = AppAppearance();
      await second.load();
      expect(second.palette, AppPalette.black);
      expect(
        await const FlutterSecureStorage().read(key: 'identity-seed'),
        'unchanged',
      );
      expect(appTheme(second.palette).scaffoldBackgroundColor, Colors.black);
      expect(
        appTheme(second.palette).colorScheme.surfaceContainerLowest,
        Colors.black,
      );
      second.dispose();
    },
  );

  testWidgets(
    'settings selects warm or black and only 1/10/50 automatic ID limits',
    (tester) async {
      await mobileSize(tester);
      FlutterSecureStorage.setMockInitialValues({});
      final appearance = AppAppearance(), controller = UiController();
      addTearDown(appearance.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        AppearanceScope(
          appearance: appearance,
          child: AnimatedBuilder(
            animation: appearance,
            builder: (context, _) => MaterialApp(
              theme: appTheme(appearance.palette),
              home: SettingsPage(controller: controller),
            ),
          ),
        ),
      );
      await tester.tap(find.text('纯黑'));
      await tester.pumpAndSettle();
      expect(appearance.palette, AppPalette.black);
      await tester.tap(find.text('10 条'));
      await tester.pumpAndSettle();
      expect(controller.aliasRotationLimit, 10);
      expect(find.byTooltip('一键换临时ID'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inactive privacy cover hides content and restores existing state',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final input = TextEditingController(text: '保持本机草稿');
      addTearDown(input.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(AppPalette.black),
          home: PrivacyShield(
            child: Scaffold(body: TextField(controller: input)),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('privacy-cover')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byKey(const ValueKey('privacy-cover')), findsOneWidget);
      expect(
        tester.widget<Visibility>(find.byType(Visibility)).visible,
        isFalse,
      );
      expect(input.text, '保持本机草稿');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const ValueKey('privacy-cover')), findsNothing);
      expect(input.text, '保持本机草稿');
    },
  );

  testWidgets(
    'expired own identity is hidden without hiding the original message',
    (tester) async {
      const message = ChatMessage(
        envelope: Envelope(
          groupId: 'g',
          messageId: 'old',
          senderId: 'own',
          nonce: '',
          ciphertext: '',
          signature: '',
        ),
        text: '保留这条消息正文',
        senderName: '临时·OLD234',
        expiredOwnId: true,
        createdAt: 1,
        state: 'stored',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(message: message, onReaction: (_) async {}),
          ),
        ),
      );
      expect(find.text('已过期 ID'), findsOneWidget);
      expect(find.text('临时·OLD234'), findsNothing);
      expect(find.text(message.text), findsOneWidget);
      expect(find.byTooltip('复制消息'), findsOneWidget);
    },
  );

  testWidgets(
    'copy feedback and animated reaction picker work on a narrow display',
    (tester) async {
      await mobileSize(tester);
      String? clipboard, reacted;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const message = ChatMessage(
        envelope: Envelope(
          groupId: 'g',
          messageId: 'm',
          senderId: 'other',
          nonce: '',
          ciphertext: '',
          signature: '',
        ),
        text: '这是一条需要复制的消息，也可以长按选择回应。',
        senderName: '临时·ABC234',
        createdAt: 1,
        state: 'stored',
        reactions: [ReactionSummary(emoji: '👍', count: 2, selectedByMe: true)],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(AppPalette.black),
          home: Scaffold(
            body: Center(
              child: MessageBubble(
                message: message,
                onReaction: (value) async {
                  reacted = value;
                },
              ),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.text(message.text)).textAlign,
        TextAlign.justify,
      );
      await tester.tap(find.byTooltip('复制消息'));
      await tester.pumpAndSettle();
      expect(clipboard, message.text);
      expect(find.text('消息已复制'), findsOneWidget);
      expect(find.byTooltip('已复制'), findsOneWidget);
      await tester.longPress(find.byKey(const ValueKey('message-card-m')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reaction-picker')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reaction-search')),
        '红心',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reaction-grid-❤️')));
      await tester.pumpAndSettle();
      expect(reacted, '❤️');
      final reaction = find.byKey(const ValueKey('reaction-m-👍'));
      expect(reaction, findsOneWidget);
      expect(
        find.descendant(of: reaction, matching: find.text('2')),
        findsOneWidget,
      );
      await tester.tap(reaction);
      await tester.pumpAndSettle();
      expect(reacted, '👍');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
