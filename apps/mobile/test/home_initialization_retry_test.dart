import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/ui/home_page.dart';

import 'mobile_ui_test.dart' show UiController, mobileSize;

class InitializationRetryController extends UiController {
  InitializationRetryController() {
    ready = false;
    error = '钥匙串访问已暂停，不会继续弹窗。';
    server = 'https://example.com';
  }
  int retries = 0;
  final completed = Completer<void>();
  @override
  Future<void> retryInitialization() async {
    retries++;
    error = null;
    changed();
    await completed.future;
    ready = true;
    changed();
  }
}

void main() {
  testWidgets(
    'initialization error retries only after an explicit button tap',
    (tester) async {
      await mobileSize(tester);
      final controller = InitializationRetryController();
      final identity = controller.identity;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: HomePage(controller: controller)),
      );
      expect(find.textContaining('钥匙串访问已暂停'), findsOneWidget);
      final retry = find.byKey(const ValueKey('retry-initialization'));
      expect(retry, findsOneWidget);
      await tester.pump(const Duration(minutes: 1));
      controller.changed();
      await tester.pump();
      expect(controller.retries, 0);
      await tester.tap(retry);
      await tester.pump();
      expect(controller.retries, 1);
      expect(retry, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(controller.retries, 1);
      controller.completed.complete();
      await tester.pumpAndSettle();
      expect(find.text('我的聊天空间'), findsOneWidget);
      expect(controller.identity, same(identity));
      expect(tester.takeException(), isNull);
    },
  );
}
