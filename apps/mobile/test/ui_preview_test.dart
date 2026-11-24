// Optional component render, not a device/network test:
// flutter test test/ui_preview_test.dart --dart-define=NEARLINK_CAPTURE_UI=true
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/emoji_catalog.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/emoji_glyph.dart';
import 'package:nearlink/services/app_appearance.dart';

import 'mobile_ui_test.dart' show UiController;

void main() {
  testWidgets(
    'render chat components with clearly marked demonstration data',
    (tester) async {
      await tester.runAsync(() async {
        final body = FontLoader('NearLinkPreview')
          ..addFont(
            File(
              '/System/Library/Fonts/STHeiti Medium.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await body.load();
        await icons.load();
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = UiController()
        ..server = 'https://preview.invalid'
        ..displayName = '临时·K7M2Q9';
      controller.activeGroup = const Group(
        id: 'preview-group',
        server: 'https://preview.invalid',
        name: '导师好 · 界面预览',
        ownerId: 'device-a',
      );
      controller.members = {
        'device-a': const Member('device-a', 'a', '小林'),
        'device-b': const Member('device-b', 'b', '阿简'),
        'device-c': const Member('device-c', 'c', '小周'),
      };
      final entries = [
        ('device-b', '每个回应，都留在消息里面。长按试试更多表情。', 'stored'),
        ('device-c', '', 'stored'),
        ('device-a', '这条消息正在本机等待发送。', 'pending'),
      ];
      controller.messages = [
        for (var i = 0; i < entries.length; i++)
          ChatMessage(
            envelope: Envelope(
              groupId: 'preview-group',
              messageId: 'preview-$i',
              senderId: entries[i].$1,
              nonce: '',
              ciphertext: '',
              signature: '',
            ),
            text: entries[i].$2,
            senderName: i == 0
                ? '临时·H4T8N6'
                : i == 2
                ? '临时·V9D3R5'
                : '临时·K7M2Q9',
            createdAt: DateTime(
              2026,
              11,
              19,
              19,
              40 + i,
            ).millisecondsSinceEpoch,
            state: entries[i].$3,
            voice: i == 1
                ? const VoiceAttachment(
                    mediaId: 'preview-voice',
                    key: '',
                    nonce: '',
                    sha256: '',
                    byteLength: 100,
                    durationMs: 6400,
                  )
                : null,
            expiredOwnId: entries[i].$1 == 'device-a',
            reactions: i == 0
                ? const [
                    ReactionSummary(emoji: '❤️', count: 8, selectedByMe: true),
                    ReactionSummary(emoji: '🌸', count: 3, selectedByMe: false),
                    ReactionSummary(emoji: '🚀', count: 1, selectedByMe: false),
                  ]
                : i == 1
                ? const [
                    ReactionSummary(emoji: '😂', count: 2, selectedByMe: false),
                    ReactionSummary(emoji: '✨', count: 1, selectedByMe: false),
                  ]
                : const [],
          ),
      ];
      addTearDown(controller.dispose);
      for (final preview in [
        (AppPalette.warm, const Size(390, 844), 'warm'),
        (AppPalette.black, const Size(390, 844), 'black'),
        (AppPalette.warm, const Size(320, 480), 'narrow'),
      ]) {
        final palette = preview.$1;
        tester.view.physicalSize = preview.$2;
        final key = GlobalKey();
        final theme = appTheme(palette);
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'NearLinkPreview'),
              ),
              home: ChatPage(controller: controller),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future.wait([
            for (final glyph in tester.widgetList<EmojiGlyph>(
              find.byType(EmojiGlyph),
            ))
              precacheImage(
                AssetImage(EmojiCatalog.find(glyph.emoji)!.assetPath),
                key.currentContext!,
              ),
          ]),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final target = File(
            '../../artifacts/chat-component-${preview.$3}.png',
          );
          await target.parent.create(recursive: true);
          await target.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        if (preview.$3 == 'warm') {
          await tester.longPress(
            find.byKey(const ValueKey('message-card-preview-0')),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => Future.wait([
              for (final glyph in tester.widgetList<EmojiGlyph>(
                find.byType(EmojiGlyph),
              ))
                precacheImage(
                  AssetImage(EmojiCatalog.find(glyph.emoji)!.assetPath),
                  key.currentContext!,
                ),
            ]),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '../../artifacts/reaction-picker-warm.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          await tester.tap(find.byTooltip('关闭表情列表'));
          await tester.pumpAndSettle();
        }
      }
    },
    skip:
        !const bool.fromEnvironment('NEARLINK_CAPTURE_UI') || !Platform.isMacOS,
  );
}
