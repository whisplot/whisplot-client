import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// These two first-party ingress points reach the same Worker and Durable
/// Objects. They never replace the logical service stored in invitations/DBs.
const productionServiceOrigin =
    'https://nearlink-api.nearlink-lovelyjhwsb.workers.dev';
const productionDirectOrigins = [
  'https://hello-mentor-entry.pages.dev',
  productionServiceOrigin,
];

class ServiceTransport {
  ServiceTransport(this.origin, {String? proxy}) {
    final expected = Uri.parse(origin).origin;
    io = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (target) {
        // Also guards WebSocket.connect's internal redirect handling. Each
        // connection pool has one immutable origin and proxy route.
        if (target.origin != expected) {
          throw const HttpException(
            'Refusing a redirect to a different origin',
          );
        }
        return proxy ?? HttpClient.findProxyFromEnvironment(target);
      };
    client = IOClient(io);
  }

  final String origin;
  late final HttpClient io;
  late final http.Client client;
  bool closed = false;

  Future<void> checkHealth() async {
    final request = http.Request('GET', Uri.parse('$origin/health'))
      ..followRedirects = false;
    final response = await http.Response.fromStream(
      await client.send(request),
    ).timeout(const Duration(seconds: 5));
    final body = jsonDecode(response.body);
    if (response.statusCode != 200 ||
        body is! Map ||
        body['ok'] != true ||
        body['version'] != 1) {
      throw const HttpException('Service health check failed');
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    client.close();
    io.close(force: true);
  }
}

/// Only the fixed production origin receives aliases. Custom servers keep
/// their own origin and configured proxy behavior. No credential is probed.
Future<ServiceTransport> selectServiceTransport(
  String logicalServer,
  Future<String?> Function(Uri) proxyResolver,
) async {
  if (logicalServer != productionServiceOrigin) {
    return ServiceTransport(
      logicalServer,
      proxy: await proxyResolver(Uri.parse(logicalServer)),
    );
  }
  final candidates = [
    for (final origin in productionDirectOrigins)
      ServiceTransport(origin, proxy: 'DIRECT'),
  ];
  final winner = Completer<ServiceTransport>();
  var failures = 0;
  for (final candidate in candidates) {
    unawaited(() async {
      try {
        await candidate.checkHealth().timeout(const Duration(seconds: 5));
        if (!winner.isCompleted) {
          winner.complete(candidate);
          for (final other in candidates) {
            if (!identical(candidate, other)) other.close();
          }
        } else {
          candidate.close();
        }
      } catch (_) {
        candidate.close();
        failures++;
        if (failures == candidates.length && !winner.isCompleted) {
          winner.completeError(
            const SocketException('Direct service routes unavailable'),
          );
        }
      }
    }());
  }
  try {
    return await winner.future;
  } on SocketException {
    // A configured system proxy is optional fallback, never a requirement for
    // the direct Pages route. Do not turn PAC/SOCKS errors into silent DIRECT.
    final route = await proxyResolver(Uri.parse(logicalServer));
    final effective =
        route ?? HttpClient.findProxyFromEnvironment(Uri.parse(logicalServer));
    if (!effective.contains('PROXY ')) {
      throw const SocketException('当前网络暂时无法连接服务，正在自动重试');
    }
    final fallback = ServiceTransport(logicalServer, proxy: effective);
    try {
      await fallback.checkHealth().timeout(const Duration(seconds: 5));
      return fallback;
    } catch (_) {
      fallback.close();
      rethrow;
    }
  }
}
