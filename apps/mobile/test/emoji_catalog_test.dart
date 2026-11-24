import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/emoji_catalog.dart';
import 'package:nearlink/ui/emoji_glyph.dart';

void main() {
  test(
    'Unicode 17 catalog preserves exact protocol values and display order',
    () {
      expect(EmojiCatalog.entries, hasLength(3944));
      expect(EmojiCatalog.categories, hasLength(9));
      expect(EmojiCatalog.values.toSet(), hasLength(3944));
      expect(
        EmojiCatalog.entries.map((entry) => entry.category).toSet(),
        EmojiCatalog.categories.toSet(),
      );
      for (var index = 0; index < EmojiCatalog.values.length; index++) {
        final emoji = EmojiCatalog.values[index];
        expect(EmojiCatalog.indexOf(emoji), index);
        expect(EmojiCatalog.find(emoji), same(EmojiCatalog.entries[index]));
      }
      for (final legacy in ['👍', '❤️', '😂', '😮', '😢', '🙏']) {
        expect(EmojiCatalog.contains(legacy), isTrue, reason: legacy);
      }
      expect(EmojiCatalog.contains('❤'), isFalse);
      expect(EmojiCatalog.contains('👍👍'), isFalse);
      expect(EmojiCatalog.find('not an emoji'), isNull);
      expect(EmojiCatalog.indexOf('not an emoji'), -1);
      expect(() => EmojiCatalog.values.add('invented'), throwsUnsupportedError);
    },
  );

  test(
    'Chinese and English search labels cover the entire offline catalog',
    () {
      for (final entry in EmojiCatalog.entries) {
        expect(entry.name.trim(), isNotEmpty);
        expect(entry.englishName.trim(), isNotEmpty);
        expect(entry.keywords, contains(entry.name));
        expect(entry.keywords, contains(entry.englishName));
      }
      expect(EmojiCatalog.find('😂')!.keywords, contains('笑哭'));
      expect(EmojiCatalog.find('❤️')!.name, '红心');
      expect(EmojiCatalog.find('👍')!.keywords, contains('thumbs up'));
    },
  );

  test(
    'every catalog graphic matches its pinned manifest and is a 72px PNG',
    () async {
      final manifest =
          jsonDecode(File('assets/emojis/manifest.json').readAsStringSync())
              as Map<String, dynamic>;
      final files = manifest['files'] as Map<String, dynamic>;
      final paths = EmojiCatalog.entries
          .map((entry) => entry.assetPath)
          .toSet();
      final sha256 = Sha256();
      var totalBytes = 0;
      expect(manifest['runtimeNetworkRequired'], isFalse);
      expect(manifest['artworkModified'], isFalse);
      expect(manifest['twemojiVersion'], EmojiCatalog.twemojiVersion);
      expect(files, hasLength(paths.length));
      for (final path in paths) {
        expect(path, matches(r'^assets/emojis/72x72/[0-9a-f-]+\.png$'));
        final bytes = File(path).readAsBytesSync();
        final expected =
            files[path.substring('assets/emojis/'.length)]
                as Map<String, dynamic>;
        final digest = (await sha256.hash(
          bytes,
        )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10], reason: path);
        final header = ByteData.sublistView(bytes);
        expect(header.getUint32(16), 72, reason: path);
        expect(header.getUint32(20), 72, reason: path);
        expect(digest, expected['sha256'], reason: path);
        expect(bytes.length, expected['bytes'], reason: path);
        totalBytes += bytes.length;
      }
      expect(totalBytes, 4203875);
      expect(totalBytes, manifest['assetBytes']);
    },
  );

  testWidgets('emoji glyph uses the bundled PNG with an accessible label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: EmojiGlyph(emoji: '❤️', size: 32)),
      ),
    );
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect(
      (image.image as AssetImage).assetName,
      'assets/emojis/72x72/2764.png',
    );
    expect(image.width, 32);
    expect(find.bySemanticsLabel('红心'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'unknown emoji falls back to local text without an image request',
    (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: EmojiGlyph(emoji: 'future emoji'),
        ),
      );
      expect(find.text('future emoji'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );
}
