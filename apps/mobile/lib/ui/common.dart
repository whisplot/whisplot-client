import 'package:material_ui/material_ui.dart';
import '../core/chat_controller.dart';
import '../services/app_language.dart';

void showError(BuildContext context, Object error) {
  final message = error is FormatException ? error.message : error.toString();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(context.appText(message)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 56});
  final double size;
  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/app_logo.png',
    width: size,
    height: size,
    fit: BoxFit.contain,
    semanticLabel: 'Whisplot',
  );
}

class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.warning = false,
  });
  final IconData icon;
  final String title, body;
  final bool warning;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: warning
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 21,
          color: warning
              ? Theme.of(context).colorScheme.onErrorContainer
              : Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.appText(title),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                context.appText(body),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(height: 1.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

String clockTime(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// Presentation only: preserve the stored pseudonym and its rotation budget.
String displayId(String value) =>
    value.startsWith('临时·') ? value.substring('临时·'.length) : value;

class AliasRotationSettings extends StatelessWidget {
  const AliasRotationSettings({super.key, required this.controller});
  final ChatController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('每几条消息换 ID', 'Messages per ID'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        SegmentedButton<int>(
          segments: [
            ButtonSegment(value: 1, label: Text(context.tr('1 条', '1'))),
            ButtonSegment(value: 10, label: Text(context.tr('10 条', '10'))),
            ButtonSegment(value: 50, label: Text(context.tr('50 条', '50'))),
          ],
          selected: {controller.aliasRotationLimit},
          onSelectionChanged: (selection) async {
            try {
              await controller.setAliasRotationLimit(selection.single);
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
        ),
      ],
    ),
  );
}
