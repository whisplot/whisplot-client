import 'package:flutter/widgets.dart';
import '../services/app_language.dart';
import '../core/emoji_catalog.dart';

/// Uses the bundled artwork even on older devices with incomplete emoji fonts.
/// Unknown or unavailable assets fall back to local text, never a network URL.
class EmojiGlyph extends StatelessWidget {
  const EmojiGlyph({
    super.key,
    required this.emoji,
    this.size = 24,
    this.semanticLabel,
  });

  final String emoji;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final entry = EmojiCatalog.find(emoji);
    Widget fallback() => Text(
      emoji,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: size, height: 1),
    );
    return Semantics(
      label:
          semanticLabel ??
          (entry == null ? emoji : context.tr(entry.name, entry.englishName)),
      image: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: entry == null
              ? fallback()
              : Image.asset(
                  entry.assetPath,
                  width: size,
                  height: size,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => fallback(),
                ),
        ),
      ),
    );
  }
}
