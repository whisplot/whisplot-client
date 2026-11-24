import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'emoji_glyph.dart';

/// A single, local reaction celebration driven by the owning message's clock.
/// No actor identity, network asset, timer or repeating animation is used here.
class ReactionBurst extends StatelessWidget {
  const ReactionBurst({
    super.key,
    required this.emoji,
    required this.progress,
    required this.target,
  });

  final String emoji;
  final double progress;
  final Offset target;

  /// A small initial response and a second bounce as the large glyph lands.
  static double badgeScale(double progress) {
    if (!progress.isFinite || progress <= 0 || progress >= 1) return 1;
    return 1 +
        .10 * math.sin(math.pi * _unit(progress / .36)) +
        .16 * math.sin(math.pi * _unit((progress - .62) / .38));
  }

  @override
  Widget build(BuildContext context) {
    if (!progress.isFinite || progress <= 0 || progress >= 1) {
      return const SizedBox.shrink();
    }
    final kind = _kindFor(emoji);
    final t = _unit(progress);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;
              if (!width.isFinite ||
                  !height.isFinite ||
                  width <= 0 ||
                  height <= 0) {
                return const SizedBox.shrink();
              }
              final glyphSize = math.min(
                52.0,
                math.min(width * .3, height * .48),
              );
              final margin = glyphSize * .65;
              final destination = Offset(
                target.dx.isFinite
                    ? target.dx.clamp(0.0, width).toDouble()
                    : width * .5,
                target.dy.isFinite
                    ? target.dy.clamp(0.0, height).toDouble()
                    : height * .75,
              );
              // Keep the celebration near its badge even for very long text.
              final origin = Offset(
                (destination.dx +
                        (width * .5 - destination.dx).clamp(-56.0, 56.0))
                    .clamp(margin, width - margin)
                    .toDouble(),
                (destination.dy - math.min(62.0, height * .32))
                    .clamp(margin, height - margin)
                    .toDouble(),
              );
              final travel = Curves.easeInOutCubic.transform(
                _unit((t - .48) / .52),
              );
              final control = Offset(
                (origin.dx + destination.dx) * .5,
                math.max(margin, math.min(origin.dy, destination.dy) - 22),
              );
              final position =
                  origin * math.pow(1 - travel, 2).toDouble() +
                  control * (2 * (1 - travel) * travel) +
                  destination * (travel * travel);
              final entrance = Curves.easeOutBack.transform(_unit(t / .23));
              final heartbeat = kind == _BurstKind.heart
                  ? 1 + .13 * _bump(t, .27, .055) + .10 * _bump(t, .42, .05)
                  : 1.0;
              final scale = entrance * heartbeat * (1 - travel * .57);
              final angle =
                  (kind == _BurstKind.laugh ? .18 : .07) *
                  math.sin(t * math.pi * (kind == _BurstKind.laugh ? 7 : 3)) *
                  (1 - travel);
              final opacity = _unit(t / .08) * (1 - _unit((t - .80) / .20));
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _BurstParticles(
                        kind: kind,
                        progress: t,
                        origin: origin,
                      ),
                    ),
                  ),
                  Positioned(
                    left: position.dx - glyphSize * .5,
                    top: position.dy - glyphSize * .5,
                    child: Opacity(
                      opacity: opacity,
                      child: Transform.rotate(
                        angle: angle,
                        child: Transform.scale(
                          scale: scale,
                          child: EmojiGlyph(emoji: emoji, size: glyphSize),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

double _unit(double value) => value.clamp(0.0, 1.0).toDouble();
double _bump(double t, double center, double spread) =>
    math.exp(-math.pow((t - center) / spread, 2));

enum _BurstKind { heart, laugh, confetti, sparkle }

_BurstKind _kindFor(String emoji) {
  if (const {
    '♥️',
    '❤️',
    '🩷',
    '🧡',
    '💛',
    '💚',
    '💙',
    '🩵',
    '💜',
    '🤎',
    '🖤',
    '🩶',
    '🤍',
    '💖',
    '💗',
    '💓',
    '💞',
    '💕',
    '💘',
    '💝',
    '❤️‍🔥',
  }.contains(emoji)) {
    return _BurstKind.heart;
  }
  if (const {'😂', '🤣', '😆', '😁', '😹'}.contains(emoji)) {
    return _BurstKind.laugh;
  }
  if (const {'🎉', '🎊', '👏', '🥳', '🙌'}.contains(emoji)) {
    return _BurstKind.confetti;
  }
  return _BurstKind.sparkle;
}

class _BurstParticles extends CustomPainter {
  const _BurstParticles({
    required this.kind,
    required this.progress,
    required this.origin,
  });
  final _BurstKind kind;
  final double progress;
  final Offset origin;
  static const _colors = [
    Color(0xFFF37021),
    Color(0xFFDE5C13),
    Color(0xFFF5AD6D),
    Color(0xFFFFC871),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final radius = math.min(46.0, math.min(size.width, size.height) * .34);
    for (var i = 0; i < 8; i++) {
      final t = _unit((progress - .06 - i * .012) / .68);
      if (t <= 0 || t >= 1) continue;
      final travel = Curves.easeOutCubic.transform(t);
      final angle = -math.pi / 2 + i * math.pi / 4;
      final distance = radius * (.35 + .65 * travel);
      final drift = kind == _BurstKind.heart ? -18 * t : 8 * t * t;
      final point =
          origin +
          Offset(
            math.cos(angle) * distance,
            math.sin(angle) * distance + drift,
          );
      final alpha = math.sin(math.pi * t) * .85;
      final extent = math.min(
        (3.0 + i % 3) * (1 - t * .35),
        math.min(size.width, size.height) * .18,
      );
      final paint = Paint()
        ..color = _colors[i % _colors.length].withValues(alpha: alpha);
      canvas.save();
      canvas.translate(
        point.dx.clamp(extent, size.width - extent).toDouble(),
        point.dy.clamp(extent, size.height - extent).toDouble(),
      );
      canvas.rotate(kind == _BurstKind.confetti ? angle + t * 4 : angle * .12);
      if (kind == _BurstKind.heart) {
        final path = Path()
          ..moveTo(0, extent * .85)
          ..cubicTo(
            -extent * 1.7,
            -extent * .1,
            -extent * .7,
            -extent * 1.4,
            0,
            -extent * .5,
          )
          ..cubicTo(
            extent * .7,
            -extent * 1.4,
            extent * 1.7,
            -extent * .1,
            0,
            extent * .85,
          )
          ..close();
        canvas.drawPath(path, paint);
      } else if (kind == _BurstKind.confetti) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(-extent * .4, -extent, extent * .8, extent * 2),
            const Radius.circular(1),
          ),
          paint,
        );
      } else {
        final path = Path()
          ..moveTo(0, -extent)
          ..lineTo(extent * .3, -extent * .3)
          ..lineTo(extent, 0)
          ..lineTo(extent * .3, extent * .3)
          ..lineTo(0, extent)
          ..lineTo(-extent * .3, extent * .3)
          ..lineTo(-extent, 0)
          ..lineTo(-extent * .3, -extent * .3)
          ..close();
        canvas.drawPath(path, paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _BurstParticles oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.progress != progress ||
      oldDelegate.origin != origin;
}
