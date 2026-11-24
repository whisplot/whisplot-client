import 'package:flutter/services.dart';

/// Native code owns the fixed HTTPS destination. No remote URL or credentials
/// cross this channel, and opening a page does not change participation state.
abstract final class AppActions {
  static const channel = MethodChannel('nearlink/app_actions');
  static Future<void> openUpdatePage() => channel
      .invokeMethod<void>('openUpdatePage')
      .timeout(const Duration(seconds: 10));
}
