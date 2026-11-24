import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'core/chat_controller.dart';
import 'ui/home_page.dart';
import 'core/app_platform.dart';
import 'services/app_appearance.dart';
import 'services/voice_playback.dart';
import 'ui/privacy_shield.dart';
import 'ui/upgrade_gate.dart';
import 'services/app_actions.dart';
import 'services/emoji_licenses.dart';
import 'services/app_language.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerEmojiLicenses();
  unawaited(VoicePlayback.cleanupAbandonedFiles().catchError((Object _) {}));
  runApp(const NearLinkApp());
}

class NearLinkApp extends StatefulWidget {
  const NearLinkApp({super.key});
  @override
  State<NearLinkApp> createState() => _NearLinkAppState();
}

class _NearLinkAppState extends State<NearLinkApp> {
  final controller = ChatController();
  final appearance = AppAppearance();
  final language = AppLanguage();
  @override
  void initState() {
    super.initState();
    controller.initialize();
    appearance.load();
    language.load();
  }

  @override
  void dispose() {
    controller.dispose();
    appearance.dispose();
    language.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppLanguageScope(
    language: language,
    child: AppearanceScope(
      appearance: appearance,
      child: AnimatedBuilder(
        animation: Listenable.merge([appearance, controller, language]),
        builder: (context, _) => MaterialApp(
          title: 'Whisplot',
          locale: language.locale,
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          debugShowCheckedModeBanner: false,
          theme: appTheme(appearance.palette),
          themeAnimationDuration: const Duration(milliseconds: 200),
          builder: (context, child) => PrivacyShield(
            child:
                controller.ready &&
                    controller.configured &&
                    !controller.participationAllowed &&
                    !controller.viewingLocalHistory
                ? UpgradeGate(
                    message:
                        controller.participationBlock?.message ??
                        '正在验证当前参与政策。本机聊天记录保留。',
                    checking: controller.checkingPolicy,
                    updateRequired:
                        controller.participationBlock != null &&
                        !controller.participationBlock!.expired,
                    onViewHistory: controller.viewLocalHistory,
                    onRetry: controller.retryConnection,
                    onOpenUpdate: AppActions.openUpdatePage,
                  )
                : !isDesktopPlatform
                ? child!
                : ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1120),
                        child: child,
                      ),
                    ),
                  ),
          ),
          home: HomePage(controller: controller),
        ),
      ),
    ),
  );
}
