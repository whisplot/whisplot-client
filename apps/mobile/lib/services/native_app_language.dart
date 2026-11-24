import 'package:flutter/services.dart';

/// Mirrors a cosmetic preference for native notification text only.
/// Failure must not prevent switching the Flutter interface or loading identity.
Future<void> syncNativeAppLanguage(String languageCode) async {
  if (languageCode != 'en' && languageCode != 'zh') return;
  try {
    await const MethodChannel('nearlink/app_language').invokeMethod<void>(
      'setLanguage',
      {'language': languageCode},
    );
  } on MissingPluginException {
    // Tests and platforms without a native notification bridge.
  } on PlatformException {
    // The saved Flutter language remains authoritative.
  }
}
