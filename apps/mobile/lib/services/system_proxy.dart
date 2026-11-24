import 'dart:io';

import 'package:flutter/services.dart';

/// Uses the Mac's existing HTTP(S) proxy and bypass rules. This does not change
/// system settings, load proxy credentials, or weaken TLS verification.
class SystemProxy {
  static const channel = MethodChannel('nearlink/network_proxy');

  static Future<String?> forUrl(Uri url) async {
    if (!Platform.isMacOS) return null;
    try {
      final route = await channel
          .invokeMethod<String>('proxyForUrl', {'url': url.toString()})
          .timeout(const Duration(seconds: 5));
      if (route == null || route.isEmpty) {
        throw const FormatException('Mac 系统代理没有返回有效网络路径');
      }
      return route;
    } on PlatformException catch (error) {
      if (error.code == 'unsupported_system_proxy') {
        throw const FormatException(
          '当前系统代理类型暂不支持；请使用系统 HTTP/HTTPS 代理或可直连服务的网络',
        );
      }
      throw const FormatException('暂时无法读取 Mac 系统代理，请重新连接');
    } on MissingPluginException {
      throw const FormatException('Mac 网络组件尚未就绪，请重新打开应用');
    }
  }
}
