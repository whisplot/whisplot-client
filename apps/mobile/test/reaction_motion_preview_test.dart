// Optional synthetic component preview; does not record a device screen.
// HELLO_MENTOR_MOTION_PREVIEW=1 ../../scripts/flutter.sh test \
//   test/reaction_motion_preview_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/emoji_catalog.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/app_appearance.dart';
import 'package:nearlink/ui/message_bubble.dart';
import 'package:nearlink/ui/reaction_burst.dart';

const _previewFont = 'ReactionMotionPreview';
const _previewSize = Size(480, 360);

ChatMessage _message(List<ReactionSummary> reactions) => ChatMessage(
  envelope: const Envelope(
    groupId: 'synthetic-motion-group',
    messageId: 'synthetic-motion-message',
    senderId: 'synthetic-participant',
    nonce: '',
    ciphertext: '',
    signature: '',
  ),
  text: '让每一个回应，都生动起来。',
  senderName: '临时·DEMO',
  createdAt: DateTime.utc(2026, 11, 20, 11, 40).millisecondsSinceEpoch,
  state: 'stored',
  reactions: reactions,
);

Future<void> _saveFrame(
  WidgetTester tester,
  GlobalKey boundaryKey,
  File destination,
) async {
  await tester.runAsync(() async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await destination.parent.create(recursive: true);
      await destination.writeAsBytes(
        data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}

void main() {
  testWidgets(
    'render synthetic reaction motion and uniform orange in both palettes',
    (tester) async {
      await tester.runAsync(() async {
        final body = FontLoader(_previewFont)
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
      tester.view.physicalSize = _previewSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final palette in [AppPalette.warm, AppPalette.black]) {
        final boundaryKey = GlobalKey();
        final theme = appTheme(palette);
        var reactions = <ReactionSummary>[];
        var parityPreview = false;
        late StateSetter update;
        final output = Directory(
          '../../artifacts/reaction-motion/${palette.name}',
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              key: ValueKey(palette),
              debugShowCheckedModeBanner: false,
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: _previewFont),
              ),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return Column(
                      children: [
                        const SizedBox(height: 24),
                        Text(
                          parityPreview ? '统一橙色 · 合成预览' : '回应动画 · 合成预览',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          parityPreview
                              ? '两枚回应具有不同内部选择状态，外观相同'
                              : '本机绘制 · 未使用真实聊天记录',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Expanded(
                          child: Center(
                            child: MessageBubble(
                              key: const ValueKey('synthetic-motion-bubble'),
                              message: _message(reactions),
                              onReaction: (_) async {},
                              onQuickLike: () async {},
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future.wait([
            for (final emoji in ['♥️', '😂'])
              precacheImage(
                AssetImage(EmojiCatalog.find(emoji)!.assetPath),
                boundaryKey.currentContext!,
              ),
          ]),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ReactionBurst), findsNothing);

        update(() {
          reactions = const [
            ReactionSummary(emoji: '♥️', count: 1, selectedByMe: true),
          ];
        });
        // First pump updates the message and schedules the reaction; the second
        // paints its initial state without advancing the animation clock.
        await tester.pump();
        await tester.pump();
        expect(find.byType(ReactionBurst), findsOneWidget);
        // Twenty frames: frame 00 at 0ms, then 40ms intervals through 760ms.
        for (var frame = 0; frame < 20; frame++) {
          if (frame != 0) {
            await tester.pump(const Duration(milliseconds: 40));
          }
          expect(tester.takeException(), isNull);
          await _saveFrame(
            tester,
            boundaryKey,
            File(
              '${output.path}/frame-${frame.toString().padLeft(2, '0')}.png',
            ),
          );
        }
        expect(find.byType(ReactionBurst), findsNothing);

        update(() {
          parityPreview = true;
          reactions = const [
            ReactionSummary(emoji: '♥️', count: 2, selectedByMe: false),
            ReactionSummary(emoji: '😂', count: 2, selectedByMe: true),
          ];
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _saveFrame(
          tester,
          boundaryKey,
          File('${output.path}/selection-parity.png'),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
    skip:
        !Platform.isMacOS ||
        (Platform.environment['HELLO_MENTOR_MOTION_PREVIEW'] != '1' &&
            const String.fromEnvironment('HELLO_MENTOR_MOTION_PREVIEW') != '1'),
  );
}
