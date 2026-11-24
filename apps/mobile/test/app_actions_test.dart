import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/app_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'update launcher passes only a fixed native action, never a URL',
    () async {
      MethodCall? observed;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppActions.channel, (call) async {
        observed = call;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppActions.channel, null),
      );
      await AppActions.openUpdatePage();
      expect(observed!.method, 'openUpdatePage');
      expect(observed!.arguments, isNull);
    },
  );
}
