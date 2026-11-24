import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'native_app_language.dart';
import 'system_text.dart';

/// Cosmetic preference only. This class never reads identity, chat data or
/// Keychain. An explicit choice updates the UI before asynchronous persistence.
class AppLanguage extends ChangeNotifier {
  AppLanguage({
    Locale initialLocale = const Locale('en'),
    Future<File> Function()? preferenceFile,
    Future<void> Function(String)? syncNativeLanguage,
  }) : _languageCode = initialLocale.languageCode == 'zh' ? 'zh' : 'en',
       _preferenceFile = preferenceFile ?? _defaultPreferenceFile,
       _syncNativeLanguage = syncNativeLanguage ?? syncNativeAppLanguage;

  static Future<File> _defaultPreferenceFile() async => File(
    p.join((await getApplicationSupportDirectory()).path, 'language-v1.txt'),
  );

  // Isolated legacy widgets without the real app scope stay deterministic.
  // This instance is never loaded or selected by LanguageToggle.
  static final fallback = AppLanguage(initialLocale: const Locale('zh'));
  final Future<File> Function() _preferenceFile;
  final Future<void> Function(String) _syncNativeLanguage;
  String _languageCode;
  bool _disposed = false, _loaded = false;
  int _selectionRevision = 0;
  Future<void>? _loading;
  Future<void> _writes = Future.value(), _nativeWrites = Future.value();

  String get languageCode => _languageCode;
  Locale get locale => Locale(_languageCode);
  bool get isEnglish => _languageCode == 'en';

  Future<void> load() {
    if (_disposed || _loaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final revision = _selectionRevision;
    String? saved;
    try {
      final file = await _preferenceFile();
      if (await file.exists() && await file.length() <= 16) {
        final value = (await file.readAsString()).trim();
        if (value == 'zh' || value == 'en') saved = value;
      }
    } catch (_) {
      // Language cannot block startup or trigger secret-store recovery.
    }
    if (_disposed) return;
    _loaded = true;
    if (_selectionRevision != revision || _selectionRevision != 0) return;
    if (saved != null && saved != _languageCode) {
      _languageCode = saved;
      notifyListeners();
    }
    _mirrorNative(_languageCode);
  }

  Future<void> select(String code) {
    if (code != 'zh' && code != 'en') {
      return Future.error(
        ArgumentError.value(code, 'code', 'Expected zh or en'),
      );
    }
    if (_disposed) return Future.value();
    _selectionRevision++;
    _languageCode = code;
    notifyListeners();
    _mirrorNative(code);
    final operation = _writes.then((_) async {
      final file = await _preferenceFile();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp-${identityHashCode(this)}');
      try {
        await temporary.writeAsString(code, flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
    // Failed cosmetic writes must not poison subsequent choices.
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _mirrorNative(String code) {
    _nativeWrites = _nativeWrites.then((_) async {
      if (_disposed) return;
      try {
        await _syncNativeLanguage(code);
      } catch (_) {
        // A platform display mirror is not the preference source of truth.
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class AppLanguageScope extends InheritedNotifier<AppLanguage> {
  const AppLanguageScope({
    super.key,
    required AppLanguage language,
    required super.child,
  }) : super(notifier: language);

  static AppLanguage? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLanguageScope>()?.notifier;

  static AppLanguage of(BuildContext context) =>
      maybeOf(context) ?? AppLanguage.fallback;
}

extension AppLanguageContext on BuildContext {
  String tr(String zh, String en) =>
      AppLanguageScope.of(this).isEnglish ? en : zh;

  /// Only use for app-owned status/errors, never messages, IDs or group names.
  String appText(String value) =>
      translateSystemText(value, english: AppLanguageScope.of(this).isEnglish);
}

class LanguageToggle extends StatelessWidget {
  const LanguageToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final language = AppLanguageScope.maybeOf(context);
    return Semantics(
      label: context.tr('界面语言', 'App language'),
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(44, 34),
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        segments: const [
          ButtonSegment(value: 'zh', label: Text('中文'), tooltip: '中文'),
          ButtonSegment(value: 'en', label: Text('EN'), tooltip: 'English'),
        ],
        selected: {language?.languageCode ?? 'zh'},
        onSelectionChanged: language == null
            ? null
            : (selection) async {
                try {
                  await language.select(selection.single);
                } catch (_) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(
                        context.tr(
                          '语言已切换，但暂时无法保存。请稍后重新选择。',
                          'Language changed, but could not be saved. Please select it again later.',
                        ),
                      ),
                    ),
                  );
                }
              },
      ),
    );
  }
}
