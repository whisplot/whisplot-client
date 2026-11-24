import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';

/// Covers chat content while the app is inactive.
/// This does not detect recording or guarantee protection from other recorders.
class PrivacyShield extends StatefulWidget {
  const PrivacyShield({super.key, required this.child});
  final Widget child;

  @override
  State<PrivacyShield> createState() => _PrivacyShieldState();
}

class _PrivacyShieldState extends State<PrivacyShield>
    with WidgetsBindingObserver {
  bool _inactive = false;
  bool get _covered => _inactive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _inactive = state != null && state != AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final inactive = state != AppLifecycleState.resumed;
    if (inactive != _inactive && mounted) setState(() => _inactive = inactive);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeFocus(
        excluding: _covered,
        child: Visibility(
          visible: !_covered,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: TickerMode(enabled: !_covered, child: widget.child),
        ),
      ),
      if (_covered)
        ColoredBox(
          key: const ValueKey('privacy-cover'),
          color: Theme.of(context).colorScheme.surface,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 32,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  'Whisplot',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    context.tr(
                      '返回窗口后继续聊天',
                      'Return to this window to continue chatting',
                    ),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}
