import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/emoji_catalog.dart';
import 'package:nearlink/services/emoji_recents.dart';

void main() {
  test(
    'recent choices survive reopening and store only ordered emoji',
    () async {
      String? saved;
      final recents = EmojiRecents(
        read: () async => saved,
        write: (value) async => saved = value,
      );
      await recents.remember('🌸');
      await recents.remember('❤️');
      await recents.remember('🌸');
      expect(jsonDecode(saved!), ['🌸', '❤️']);
      final reopened = EmojiRecents(read: () async => saved);
      await reopened.load();
      expect(reopened.values, ['🌸', '❤️']);
    },
  );

  test(
    'concurrent choices keep the latest 24 without duplicate entries',
    () async {
      String? saved;
      final recents = EmojiRecents(
        read: () async => null,
        write: (value) async => saved = value,
      );
      final choices = EmojiCatalog.entries
          .take(30)
          .map((e) => e.emoji)
          .toList();
      await Future.wait(choices.map(recents.remember));
      expect(recents.values, choices.reversed.take(24).toList());
      await recents.remember(choices[12]);
      expect(recents.values.first, choices[12]);
      expect(recents.values.toSet().length, 24);
      expect(jsonDecode(saved!), recents.values);
    },
  );

  test('invalid data and extra fields cannot become emoji history', () async {
    for (final input in [
      '{broken',
      '{"emoji":"🌸","groupId":"private-group"}',
      'x' * 17000,
    ]) {
      final recents = EmojiRecents(read: () async => input);
      await recents.load();
      expect(recents.values, isEmpty);
    }
    var writes = 0;
    final recents = EmojiRecents(
      read: () async => '["🌸","private-group",7,"🌸","❤️"]',
      write: (_) async => writes++,
    );
    await recents.load();
    expect(recents.values, ['🌸', '❤️']);
    await recents.remember('a search phrase');
    expect(writes, 0);
    expect(recents.values, ['🌸', '❤️']);
  });

  test('unavailable local storage does not interrupt selection', () async {
    final recents = EmojiRecents(
      read: () async => throw StateError('storage unavailable'),
      write: (_) async => throw StateError('storage unavailable'),
    );
    await recents.remember('🌸');
    await recents.remember('❤️');
    expect(recents.values, ['❤️', '🌸']);
  });
}
