import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/services/app_language.dart';
import 'package:nearlink/services/system_text.dart';
import 'package:nearlink/ui/common.dart';
import 'package:path/path.dart' as p;

import 'mobile_ui_test.dart' show UiController;

// Widget rendering uses fake time; real-file persistence is tested separately.
class _WidgetLanguage extends AppLanguage {
  String code = 'en';
  @override
  String get languageCode => code;
  @override
  Locale get locale => Locale(code);
  @override
  bool get isEnglish => code == 'en';
  @override
  Future<void> select(String value) async {
    code = value;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File preference;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'whisplot-language-test-',
    );
    preference = File(p.join(directory.path, 'language-v1.txt'));
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  AppLanguage makeLanguage({Future<void> Function(String)? sync}) =>
      AppLanguage(
        preferenceFile: () async => preference,
        syncNativeLanguage: sync ?? (_) async {},
      );

  test(
    'first launch is English and language selection never reads Keychain',
    () async {
      final calls = <String>[];
      for (final name in [
        'plugins.it_nomads.com/flutter_secure_storage',
        'nearlink/mac_secret_vault',
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(name), (call) async {
              calls.add('$name/${call.method}');
              throw StateError('Language must not request secrets');
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(MethodChannel(name), null),
        );
      }
      final language = makeLanguage();
      addTearDown(language.dispose);
      expect(language.locale, const Locale('en'));
      await language.load();
      expect(language.languageCode, 'en');
      await language.select('zh');
      expect(await preference.readAsString(), 'zh');
      expect(calls, isEmpty);
    },
  );

  test('saved Chinese is restored by a fresh instance', () async {
    final first = makeLanguage();
    await first.load();
    await first.select('zh');
    first.dispose();
    final restored = makeLanguage();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.locale, const Locale('zh'));
  });

  test('selection rebuilds immediately while persistence is delayed', () async {
    final resolver = Completer<File>();
    final language = AppLanguage(
      preferenceFile: () => resolver.future,
      syncNativeLanguage: (_) async {},
    );
    addTearDown(language.dispose);
    final observed = <String>[];
    language.addListener(() => observed.add(language.languageCode));
    final saving = language.select('zh');
    expect(language.languageCode, 'zh');
    expect(observed, ['zh']);
    expect(await preference.exists(), isFalse);
    resolver.complete(preference);
    await saving;
    expect(await preference.readAsString(), 'zh');
  });

  test(
    'late saved preference cannot overwrite an explicit selection',
    () async {
      await preference.writeAsString('zh');
      final loadingFile = Completer<File>();
      var requests = 0;
      final language = AppLanguage(
        preferenceFile: () =>
            ++requests == 1 ? loadingFile.future : Future.value(preference),
        syncNativeLanguage: (_) async {},
      );
      addTearDown(language.dispose);
      final loading = language.load();
      final saving = language.select('en');
      loadingFile.complete(preference);
      await Future.wait([loading, saving]);
      expect(language.languageCode, 'en');
      expect(await preference.readAsString(), 'en');
    },
  );

  test(
    'rapid choices persist and mirror in order with the final choice winning',
    () async {
      final nativeGate = Completer<void>();
      final nativeFinished = Completer<void>();
      final mirrored = <String>[];
      final language = makeLanguage(
        sync: (code) async {
          if (mirrored.isEmpty) await nativeGate.future;
          mirrored.add(code);
          if (mirrored.length == 3) nativeFinished.complete();
        },
      );
      addTearDown(language.dispose);
      final choices = [
        language.select('zh'),
        language.select('en'),
        language.select('zh'),
      ];
      expect(language.languageCode, 'zh');
      await Future.wait(choices);
      expect(await preference.readAsString(), 'zh');
      nativeGate.complete();
      await nativeFinished.future;
      expect(mirrored, ['zh', 'en', 'zh']);
      expect(directory.listSync().map((f) => f.path), [preference.path]);
    },
  );

  test('a failed cosmetic save does not poison later choices', () async {
    var requests = 0;
    final language = AppLanguage(
      preferenceFile: () async {
        if (++requests == 1) {
          throw const FileSystemException('Synthetic failure');
        }
        return preference;
      },
      syncNativeLanguage: (_) async {},
    );
    addTearDown(language.dispose);
    await expectLater(
      language.select('zh'),
      throwsA(isA<FileSystemException>()),
    );
    expect(language.languageCode, 'zh');
    await language.select('en');
    expect(await preference.readAsString(), 'en');
  });

  test(
    'invalid or oversized cosmetic preferences fall back to English',
    () async {
      for (final invalid in ['de', 'zh en', 'zh${' ' * 100}']) {
        await preference.writeAsString(invalid);
        final language = makeLanguage();
        await language.load();
        expect(language.languageCode, 'en');
        language.dispose();
      }
    },
  );

  test(
    'dispose suppresses a late load without requesting native state',
    () async {
      await preference.writeAsString('zh');
      final resolver = Completer<File>();
      final native = <String>[];
      var notifications = 0;
      final language = AppLanguage(
        preferenceFile: () => resolver.future,
        syncNativeLanguage: (code) async => native.add(code),
      )..addListener(() => notifications++);
      final pending = language.load();
      language.dispose();
      resolver.complete(preference);
      await pending;
      expect(notifications, 0);
      expect(native, isEmpty);
    },
  );

  testWidgets('toggle rebuilds app and SDK language without changing a draft', (
    tester,
  ) async {
    final language = _WidgetLanguage();
    final draft = TextEditingController(text: '中文消息 hello 未开启');
    addTearDown(language.dispose);
    addTearDown(draft.dispose);
    await tester.pumpWidget(
      AppLanguageScope(
        language: language,
        child: AnimatedBuilder(
          animation: language,
          builder: (context, _) => MaterialApp(
            locale: language.locale,
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const LanguageToggle(),
                    Text(context.tr('设置', 'Settings')),
                    Text(context.appText('未开启')),
                    Text(MaterialLocalizations.of(context).okButtonLabel),
                    TextField(controller: draft),
                    const Text('原消息 未开启'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    await tester.tap(find.text('中文'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('未开启'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('原消息 未开启'), findsOneWidget);
    expect(draft.text, '中文消息 hello 未开启');
    await tester.tap(find.text('EN'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(draft.text, '中文消息 hello 未开启');
    expect(tester.takeException(), isNull);
  });

  testWidgets('isolated legacy widgets stay Chinese with a disabled toggle', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const LanguageToggle(),
                Text(context.tr('中文界面', 'English UI')),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('中文界面'), findsOneWidget);
    expect(
      tester
          .widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>))
          .onSelectionChanged,
      isNull,
    );
  });

  testWidgets('English ID rotation controls fit a 320 pixel phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final language = makeLanguage();
    final controller = UiController();
    addTearDown(language.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      AppLanguageScope(
        language: language,
        child: MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: AliasRotationSettings(controller: controller),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Messages per ID'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(SegmentedButton<int>)).right,
      lessThanOrEqualTo(296),
    );
  });

  test('only exact app-owned messages and constrained error forms translate', () {
    String english(String value) => translateSystemText(value, english: true);
    expect(english('未开启'), 'Off');
    expect(
      english('初始化失败：FormatException: 服务地址无效'),
      'Initialization failed: Invalid service URL',
    );
    expect(
      english('3 条消息未通过验证，已隔离；其他消息仍正常同步'),
      '3 messages failed verification and were isolated. Other messages remain available.',
    );
    expect(
      english('服务返回了无法识别的响应（502）'),
      'The service returned an unrecognized response (502).',
    );
    expect(english('自定义消息 未开启'), '自定义消息 未开启');
    expect(english('ID-未开启'), 'ID-未开启');
    expect(english('未知错误'), '未知错误');
    expect(translateSystemText('未开启', english: false), '未开启');
  });
}
