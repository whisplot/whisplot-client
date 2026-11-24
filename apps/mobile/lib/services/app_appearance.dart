import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'secure_storage.dart';

enum AppPalette { warm, black }

/// Appearance is independent from connection settings and device identity.
class AppAppearance extends ChangeNotifier {
  AppAppearance({
    FlutterSecureStorage? storage,
    bool? macPreferences,
    Future<File> Function()? preferenceFile,
  }) : _storage = storage ?? appSecureStorage,
       _macPreferences =
           macPreferences ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS),
       _preferenceFile = preferenceFile ?? _defaultPreferenceFile;
  final bool _macPreferences;
  final Future<File> Function() _preferenceFile;
  static Future<File> _defaultPreferenceFile() async => File(
    '${(await getApplicationSupportDirectory()).path}/appearance-v2.txt',
  );

  Future<String?> _readPreference() async {
    if (!_macPreferences) return _storage.read(key: storageKey);
    final file = await _preferenceFile();
    if (await file.exists()) {
      if (await file.length() > 32) return null;
      final value = (await file.readAsString()).trim();
      return value == 'black' || value == 'warm' ? value : null;
    }
    // Missing cosmetic preferences use the default palette. Do not touch the
    // old Keychain item at all, even with a noninteractive query: appearance
    // loading runs alongside the single vault unlock and must not create a
    // second Keychain operation. Already migrated file preferences stay intact.
    return null;
  }

  Future<void> _writePreference(String value) async {
    if (!_macPreferences) return _storage.write(key: storageKey, value: value);
    final file = await _preferenceFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    await temporary.rename(file.path);
  }

  static final fallback = AppAppearance();
  static const storageKey = 'appearance-v1';
  final FlutterSecureStorage _storage;
  AppPalette _palette = AppPalette.warm;
  AppPalette get palette => _palette;
  bool _disposed = false;
  bool _userSelected = false;
  Future<void> _writes = Future.value();

  Future<void> load() {
    final operation = _writes.then((_) async {
      try {
        final saved = await _readPreference();
        if (!_disposed && !_userSelected) {
          _palette = saved == 'black' ? AppPalette.black : AppPalette.warm;
          notifyListeners();
        }
      } catch (_) {
        // A cosmetic preference must never block identity/keychain recovery.
      }
    });
    _writes = operation;
    return operation;
  }

  Future<void> select(AppPalette palette) {
    _userSelected = true;
    final operation = _writes.then((_) async {
      await _writePreference(palette.name);
      if (!_disposed) {
        _palette = palette;
        notifyListeners();
      }
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class AppearanceScope extends InheritedNotifier<AppAppearance> {
  const AppearanceScope({
    super.key,
    required AppAppearance appearance,
    required super.child,
  }) : super(notifier: appearance);

  static AppAppearance of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier ??
      AppAppearance.fallback;
}

ThemeData appTheme(AppPalette palette) {
  final dark = palette == AppPalette.black;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF786449),
        brightness: dark ? Brightness.dark : Brightness.light,
      ).copyWith(
        surface: dark ? Colors.black : const Color(0xFFF7F3EB),
        surfaceContainerLowest: dark ? Colors.black : const Color(0xFFFFFCF5),
        surfaceContainerLow: dark ? Colors.black : const Color(0xFFF0EAE0),
        surfaceContainer: dark
            ? const Color(0xFF111111)
            : const Color(0xFFECE4D7),
        surfaceContainerHigh: dark
            ? const Color(0xFF1A1A1A)
            : const Color(0xFFE5DCCD),
        onSurface: dark ? const Color(0xFFF2EEE7) : const Color(0xFF332F29),
        onSurfaceVariant: dark
            ? const Color(0xFFAAA69F)
            : const Color(0xFF716B60),
        primary: dark ? const Color(0xFFE0C69F) : const Color(0xFF796144),
        onPrimary: dark ? Colors.black : const Color(0xFFFFFCF7),
        primaryContainer: dark
            ? const Color(0xFF29241D)
            : const Color(0xFFEDE0C9),
        onPrimaryContainer: dark
            ? const Color(0xFFEADBC6)
            : const Color(0xFF51432F),
        outlineVariant: dark
            ? const Color(0xFF33312D)
            : const Color(0xFFDCD3C5),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
      ),
      headlineMedium: TextStyle(
        fontSize: 27,
        fontWeight: FontWeight.w700,
        letterSpacing: -.6,
      ),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      bodyMedium: TextStyle(height: 1.5),
    ),
  );
}
