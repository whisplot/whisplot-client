import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/app_language.dart';
import 'package:nearlink/ui/home_page.dart';
import 'package:nearlink/ui/join_page.dart';
import 'package:nearlink/ui/privacy_shield.dart';
import 'package:nearlink/ui/upgrade_gate.dart';

import 'mobile_ui_test.dart' show UiController, mobileSize;

// UI tests keep storage out of scope; AppLanguage persistence is tested in its
// own suite. This still exercises the actual scope and language-toggle widget.
class _UiLanguage extends AppLanguage {
  String _code = 'en';
  @override
  String get languageCode => _code;
  @override
  Locale get locale => Locale(_code);
  @override
  bool get isEnglish => _code == 'en';
  @override
  Future<void> select(String code) async {
    _code = code;
    notifyListeners();
  }
}

Widget _host(AppLanguage language, Widget child) => AppLanguageScope(
  language: language,
  child: MaterialApp(home: child),
);

void main() {
  testWidgets(
    'home switches languages without changing group names or identity',
    (tester) async {
      await mobileSize(tester);
      final language = _UiLanguage();
      final controller = UiController()
        ..server = 'https://original.example'
        ..online = true;
      const group = Group(
        id: 'unchanged-group',
        name: '周末中文群',
        server: 'https://original.example',
        ownerId: 'device-a',
      );
      controller.groups = [group];
      final identity = controller.identity;
      addTearDown(language.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(language, HomePage(controller: controller)),
      );
      expect(find.text('Whisplot'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'English home layout');
      expect(find.text('My chat spaces'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text(group.name), findsOneWidget);
      expect(find.text('ABC234'), findsOneWidget);
      await tester.tap(find.text('中文'));
      await tester.pumpAndSettle();
      expect(find.text('我的聊天空间'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'Chinese home layout');
      expect(find.text(group.name), findsOneWidget);
      expect(controller.identity, same(identity));
      expect(controller.groups.single, same(group));
      await tester.tap(find.text('EN'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'English group dialog');
      expect(find.text('Create a chat space'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '群名 stays unchanged');
      await language.select('zh');
      await tester.pumpAndSettle();
      expect(find.text('创建聊天空间'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '群名 stays unchanged',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('EN'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Warm white'), findsOneWidget);
      expect(find.text('Pure black'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Service address'), findsNothing);
      expect(find.text('Connection settings'), findsNothing);
      expect(find.text('Device identity'), findsNothing);
      await language.select('zh');
      await tester.pumpAndSettle();
      expect(find.text('设备身份'), findsNothing);
      expect(find.text('复制身份标识'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first-run setup remains reachable in English on a narrow screen',
    (tester) async {
      await mobileSize(tester);
      final language = _UiLanguage(), controller = UiController();
      addTearDown(language.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(language, HomePage(controller: controller)),
      );
      final setup = find.text('Set up Whisplot');
      await tester.ensureVisible(setup);
      await tester.pumpAndSettle();
      await tester.tap(setup);
      await tester.pumpAndSettle();
      expect(find.text('Connect to your space'), findsOneWidget);
      expect(find.text('Start with an invitation'), findsOneWidget);
      expect(find.text('中文'), findsOneWidget);
      expect(find.textContaining('导师好'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'join UI switches copy while preserving an untouched invite draft',
    (tester) async {
      await mobileSize(tester);
      final language = _UiLanguage(), controller = UiController();
      addTearDown(language.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(language, JoinPage(controller: controller)),
      );
      expect(find.text('Your friends are waiting'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'AbC-123-中文原文');
      await language.select('zh');
      await tester.pumpAndSettle();
      expect(find.text('朋友已经在等你'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'AbC-123-中文原文',
      );
      await language.select('en');
      await tester.pumpAndSettle();
      expect(find.text('Paste from clipboard'), findsOneWidget);
      expect(controller.configureCalls, 0);
      expect(controller.joinCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'upgrade gate translates controls and feedback without unlocking',
    (tester) async {
      await mobileSize(tester);
      final language = _UiLanguage();
      addTearDown(language.dispose);
      var history = 0;
      await tester.pumpWidget(
        _host(
          language,
          UpgradeGate(
            message: '',
            onViewHistory: () => history++,
            onRetry: () async => throw StateError('internal details'),
          ),
        ),
      );
      expect(find.text('Security check'), findsOneWidget);
      expect(find.text('Update to continue chatting'), findsOneWidget);
      final retry = find.byKey(const ValueKey('retry-upgrade-check'));
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.textContaining('internal details'), findsNothing);
      expect(find.text('暂时无法重新检查，请稍后重试。'), findsNothing);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
      final viewHistory = find.byKey(const ValueKey('view-local-history'));
      await tester.ensureVisible(viewHistory);
      await tester.tap(viewHistory);
      await tester.pumpAndSettle();
      expect(history, 1);
      expect(find.byKey(const ValueKey('upgrade-gate')), findsOneWidget);
      await language.select('zh');
      await tester.pumpAndSettle();
      expect(find.text('安全检查'), findsOneWidget);
      expect(find.text('暂时无法重新检查，请稍后重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('privacy cover translates while retaining protected content', (
    tester,
  ) async {
    await mobileSize(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final language = _UiLanguage();
    addTearDown(language.dispose);
    await tester.pumpWidget(
      _host(
        language,
        PrivacyShield(child: const Scaffold(body: Text('原始私密消息'))),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Return to this window to continue chatting'),
      findsOneWidget,
    );
    expect(find.text('原始私密消息').hitTestable(), findsNothing);
    await language.select('zh');
    await tester.pump();
    expect(find.text('返回窗口后继续聊天'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.text('原始私密消息').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
