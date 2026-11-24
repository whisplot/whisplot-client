import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/client_security.dart';
import 'package:nearlink/ui/upgrade_gate.dart';

Widget hostGate({
  String message = '请更新后继续。',
  VoidCallback? onViewHistory,
  Future<void> Function()? onRetry,
  Future<void> Function()? onOpenUpdate,
  bool checking = false,
  bool updateRequired = true,
}) => MaterialApp(
  home: UpgradeGate(
    message: message,
    onViewHistory: onViewHistory ?? () {},
    onRetry: onRetry ?? () async {},
    onOpenUpdate: onOpenUpdate,
    checking: checking,
    updateRequired: updateRequired,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'copies only the fixed update URL, with no dismiss or URL input',
    (tester) async {
      final copied = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        hostGate(message: '服务提示：https://untrusted.example/update'),
      );
      expect(find.text(AppSecurity.updateUrl), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Back'), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byKey(const ValueKey('open-update-url')), findsNothing);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
      await tester.ensureVisible(find.byKey(const ValueKey('copy-update-url')));
      await tester.tap(find.byKey(const ValueKey('copy-update-url')));
      await tester.pumpAndSettle();
      expect(copied, [AppSecurity.updateUrl]);
      expect(find.text('下载网址已复制，请粘贴到浏览器打开。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history calls only the explicit read-only callback', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(hostGate(onViewHistory: () => opened++));
    final history = find.byKey(const ValueKey('view-local-history'));
    await tester.ensureVisible(history);
    await tester.tap(history);
    await tester.pump();
    expect(opened, 1);
    expect(find.byKey(const ValueKey('upgrade-gate')), findsOneWidget);
    expect(find.textContaining('查看本机历史不会恢复发送'), findsOneWidget);
  });

  testWidgets('a failed retry keeps the gate and cannot run concurrently', (
    tester,
  ) async {
    var calls = 0;
    final pending = Completer<void>();
    await tester.pumpWidget(
      hostGate(
        onRetry: () {
          calls++;
          return pending.future;
        },
      ),
    );
    final retry = find.byKey(const ValueKey('retry-upgrade-check'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<OutlinedButton>(retry).onPressed, isNull);
    pending.completeError(StateError('internal details must not be displayed'));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法重新检查，请稍后重试。'), findsOneWidget);
    expect(find.textContaining('internal details'), findsNothing);
    expect(find.byKey(const ValueKey('upgrade-gate')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(retry).onPressed, isNotNull);
  });

  testWidgets('policy verification state still allows local history', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      hostGate(
        checking: true,
        updateRequired: false,
        onViewHistory: () => opened++,
      ),
    );
    expect(find.text('暂时无法确认安全状态'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('retry-upgrade-check')),
          )
          .onPressed,
      isNull,
    );
    final history = find.byKey(const ValueKey('view-local-history'));
    await tester.ensureVisible(history);
    await tester.tap(history);
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('an optional fixed-destination opener cannot dismiss the gate', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      hostGate(
        onOpenUpdate: () async {
          opens++;
          throw StateError('opening failed');
        },
      ),
    );
    final open = find.byKey(const ValueKey('open-update-url'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(find.text('无法打开下载页，请复制网址后在浏览器中打开。'), findsOneWidget);
    expect(find.byKey(const ValueKey('upgrade-gate')), findsOneWidget);
  });

  testWidgets('system back cannot pop an active upgrade gate', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Previous page')),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => UpgradeGate(
            message: '更新后继续',
            onViewHistory: () {},
            onRetry: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('upgrade-gate')), findsOneWidget);
    expect(find.text('Previous page'), findsNothing);
  });
}
