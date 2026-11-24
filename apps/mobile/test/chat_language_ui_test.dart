import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/app_language.dart';
import 'package:nearlink/services/emoji_recents.dart';
import 'package:nearlink/services/voice_capture.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/message_bubble.dart';
import 'package:nearlink/ui/reaction_picker.dart';
import 'package:nearlink/ui/voice_composer.dart';

import 'desktop_behavior_test.dart' show DesktopController;
import 'voice_capture_test.dart' show TestRecorder, TestProcessor;
import 'voice_composer_test.dart' show TestPlayer;

AppLanguage languageForTest() {
  final directory = Directory.systemTemp.createTempSync(
    'whisplot-ui-language-',
  );
  final language = AppLanguage(
    preferenceFile: () async => File('${directory.path}/language.txt'),
    syncNativeLanguage: (_) async {},
  );
  addTearDown(() {
    language.dispose();
    directory.deleteSync(recursive: true);
  });
  return language;
}

Widget host(AppLanguage language, Widget child, {double scale = 1}) =>
    AppLanguageScope(
      language: language,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: child,
      ),
    );

void narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('English chat captions keep group, ID and outgoing text intact', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    narrow(tester);
    final language = languageForTest();
    final controller = DesktopController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(language, ChatPage(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('桌面群聊'), findsOneWidget);
    expect(find.text('ABC234'), findsOneWidget);
    expect(find.text('Say hello'), findsOneWidget);
    expect(find.byTooltip('Voice with effects'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration?.hintText,
      'Enter to send · Shift+Enter for a new line',
    );
    await tester.enterText(find.byType(TextField), '已发送 is my actual message');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.sent, ['已发送 is my actual message']);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Manage invites'), findsOneWidget);
    await tester.tap(find.text('Leave group'));
    await tester.pumpAndSettle();
    expect(find.text('Leave group?'), findsOneWidget);
    expect(find.textContaining('Leaving “桌面群聊”'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => language.select('zh'));
    await tester.pumpAndSettle();
    expect(find.text('来打个招呼吧'), findsOneWidget);
    expect(find.text('桌面群聊'), findsOneWidget);
    expect(find.byTooltip('变声语音'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'English message metadata and reply placeholders do not translate content',
    (tester) async {
      narrow(tester);
      final language = languageForTest();
      const envelope = Envelope(
        groupId: 'g',
        messageId: 'm',
        senderId: 's',
        nonce: '',
        ciphertext: '',
        signature: '',
      );
      final message = ChatMessage(
        envelope: envelope,
        text: '已读取 · 来打个招呼吧',
        senderName: '临时·已连接',
        createdAt: 1,
        state: 'stored',
        isRead: true,
        replyToMessageId: 'missing',
        reactions: const [
          ReactionSummary(emoji: '♥️', count: 2, selectedByMe: true),
        ],
      );
      await tester.pumpWidget(
        host(
          language,
          Scaffold(
            body: SingleChildScrollView(
              child: MessageBubble(message: message, onReaction: (_) async {}),
            ),
          ),
          scale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('已读取 · 来打个招呼吧'), findsOneWidget);
      expect(find.text('已连接'), findsOneWidget);
      expect(
        find.text('Original message is not on this device'),
        findsOneWidget,
      );
      expect(find.byTooltip('Copy message'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'English emoji categories search and insertion use the offline catalog',
    (tester) async {
      narrow(tester);
      final language = languageForTest();
      String? picked;
      await tester.pumpWidget(
        host(
          language,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ReactionPicker(
                      inserting: true,
                      recents: EmojiRecents(
                        read: () async => null,
                        write: (_) async {},
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Smileys & emotion'), findsOneWidget);
      expect(find.byTooltip('Close emoji picker'), findsOneWidget);
      final search = find.byKey(const ValueKey('reaction-search'));
      expect(tester.widget<TextField>(search).decoration?.hintText, 'Search');
      await tester.enterText(search, 'grinning face');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reaction-grid-😀')));
      await tester.pumpAndSettle();
      expect(picked, '😀');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'English voice preview and send stay usable on a narrow enlarged layout',
    (tester) async {
      narrow(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final language = languageForTest();
      final recorder = TestRecorder(),
          processor = TestProcessor(),
          player = TestPlayer();
      final capture = VoiceCapture(recorder: recorder, processor: processor);
      Uint8List? sent;
      await tester.pumpWidget(
        host(
          language,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => VoiceComposer(
                    capture: capture,
                    player: player,
                    onSend: (wav) async => sent = Uint8List.fromList(wav),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
          scale: 1.3,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('may still identify you'), findsOneWidget);
      await tester.ensureVisible(find.text('Record (up to 30 seconds)'));
      await tester.tap(find.text('Record (up to 30 seconds)'));
      await tester.pumpAndSettle();
      recorder.stream.add(Uint8List.fromList(List.filled(16000, 9)));
      await tester.pump();
      await tester.ensureVisible(find.text('Stop and apply effect'));
      await tester.tap(find.text('Stop and apply effect'));
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Send voice'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('Preview voice'));
      await tester.tap(find.text('Preview voice'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Send voice'));
      await tester.tap(find.text('Send voice'));
      await tester.pumpAndSettle();
      expect(sent, orderedEquals(processor.output));
      expect(tester.takeException(), isNull);
    },
  );
}
