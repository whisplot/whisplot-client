import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../core/models.dart';
import '../core/client_security.dart';
import '../core/crypto_service.dart';
import 'system_proxy.dart';
import 'service_transport.dart';

class TransportChangedException implements Exception {
  const TransportChangedException();
}

class ApiException implements Exception {
  const ApiException(this.message, {this.code = 'request_failed', this.status});
  final String message, code;
  final int? status;
  @override
  String toString() => message;
}

class StorageQuotaException extends ApiException {
  const StorageQuotaException()
    : super(
        '服务今日写入额度已用完，消息保存在本机，额度恢复后会自动重试',
        code: 'storage_quota_exceeded',
        status: 503,
      );
}

/// An admission failure, not a transient network error. Only a fresh verified
/// policy accepted by the controller may clear it; retries never do so.
class UpgradeRequiredException extends ApiException {
  const UpgradeRequiredException({
    String message = '请更新 Whisplot 后继续参与讨论。本机聊天记录和待发消息仍然保留。',
    this.policy,
    this.expired = false,
  }) : super(message, code: 'client_upgrade_required', status: 426);
  final Map<String, dynamic>? policy;
  final bool expired;
}

String normalizeServer(String input, {bool allowLocalHttp = false}) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException(
      '请输入完整服务地址，例如 https://nearlink.example.workers.dev',
    );
  }
  if (uri.scheme != 'https' && !(allowLocalHttp && uri.scheme == 'http')) {
    throw const FormatException('服务地址必须使用 HTTPS；本机 HTTP 仅限显式开启的调试构建');
  }
  return uri.replace(path: '').toString().replaceFirst(RegExp(r'/$'), '');
}

class ApiClient {
  ApiClient({
    required this.server,
    required this.identity,
    required this.crypto,
    this.registrationCode = '',
    http.Client? client,
    this.elapsedMilliseconds,
    DateTime Function()? wallClock,
    Future<String?> Function(Uri)? proxyResolver,
    Future<ServiceTransport> Function(String, Future<String?> Function(Uri))?
    transportSelector,
  }) : _providedClient = client,
       _wallClock = wallClock ?? DateTime.now,
       _proxyResolver = proxyResolver ?? SystemProxy.forUrl,
       _transportSelector = transportSelector ?? selectServiceTransport;
  static bool get allowsLocalHttp =>
      kDebugMode && const bool.fromEnvironment('ALLOW_LOCAL_HTTP');
  final String server, registrationCode;
  final Identity identity;
  final CryptoService crypto;
  static const clientBuild = AppSecurity.clientBuild,
      protocolVersion = AppSecurity.protocolVersion,
      privacyEpoch = AppSecurity.privacyEpoch;
  static const updatePage = AppSecurity.updateUrl;
  void Function()? ensureParticipation;
  void Function(UpgradeRequiredException)? onUpgradeRequired;
  UpgradeRequiredException? _participationBlock;
  final http.Client? _providedClient;
  final Future<String?> Function(Uri) _proxyResolver;
  final Future<ServiceTransport> Function(String, Future<String?> Function(Uri))
  _transportSelector;
  ServiceTransport? _transport;
  Future<ServiceTransport>? _selecting;
  final _transportChanges = StreamController<void>.broadcast(sync: true);
  int _generation = 0;
  bool _closed = false;
  final int Function()? elapsedMilliseconds;
  final DateTime Function() _wallClock;
  final Stopwatch _quotaClock = Stopwatch()..start();
  int _quotaUntil = 0;
  DateTime? _quotaWallUntil;
  int _manualQuotaProbeUntil = 0;
  DateTime? _manualQuotaProbeWallUntil;
  static const _quotaProbeInterval = Duration(minutes: 15);
  static const _manualQuotaProbeInterval = Duration(seconds: 30);

  int get _elapsed =>
      elapsedMilliseconds?.call() ?? _quotaClock.elapsedMilliseconds;
  Duration get quotaRetryAfter {
    final wallUntil = _quotaWallUntil;
    if (wallUntil == null) return Duration.zero;
    // Stopwatch can pause while the device sleeps. Wall time allows a quota
    // reset to expire during sleep; monotonic time bounds a clock rollback.
    // Once either expires, a subsequent clock adjustment must not revive it.
    final remaining = _remainingUntil(_quotaUntil, wallUntil);
    if (remaining == 0) {
      _quotaUntil = 0;
      _quotaWallUntil = null;
    }
    return Duration(milliseconds: remaining);
  }

  int _remainingUntil(int monotonicUntil, DateTime wallUntil) => wallUntil
      .difference(_wallClock())
      .inMilliseconds
      .clamp(0, (monotonicUntil - _elapsed).clamp(0, 86400000));

  /// A user retry can recheck recovery before the estimated daily reset.
  /// A fresh server rejection still applies, and repeated clicks cannot turn
  /// quota recovery into a request loop. This never clears admission policy.
  bool prepareManualQuotaRetry() {
    final wallUntil = _manualQuotaProbeWallUntil;
    if (wallUntil != null) {
      if (_remainingUntil(_manualQuotaProbeUntil, wallUntil) > 0) return false;
      _manualQuotaProbeUntil = 0;
      _manualQuotaProbeWallUntil = null;
    }
    if (quotaRetryAfter == Duration.zero) return true;
    _manualQuotaProbeUntil =
        _elapsed + _manualQuotaProbeInterval.inMilliseconds;
    _manualQuotaProbeWallUntil = _wallClock().add(_manualQuotaProbeInterval);
    _quotaUntil = 0;
    _quotaWallUntil = null;
    return true;
  }

  void _checkQuota() {
    if (quotaRetryAfter > Duration.zero) throw const StorageQuotaException();
  }

  int get transportGeneration => _generation;

  void checkParticipation() {
    if (_participationBlock case final block?) throw block;
    ensureParticipation?.call();
  }

  void blockParticipation(UpgradeRequiredException error) {
    final newlyBlocked = _participationBlock == null;
    _participationBlock = error;
    if (newlyBlocked) resetTransport();
  }

  void acceptVerifiedPolicy() => _participationBlock = null;

  Never _upgrade(UpgradeRequiredException error) {
    blockParticipation(error);
    onUpgradeRequired?.call(error);
    throw error;
  }

  void _ensureCurrent(int generation) {
    if (_closed || generation != _generation) {
      throw const TransportChangedException();
    }
  }

  /// Cancel a caller promptly on a network change, even while platform proxy
  /// discovery/route probes are still pending. Late results remain observed;
  /// subscriptions are removed after completion instead of accumulating.
  Future<T> _duringGeneration<T>(int generation, Future<T> task) {
    _ensureCurrent(generation);
    final result = Completer<T>();
    final subscription = _transportChanges.stream.listen((_) {
      if (!result.isCompleted) {
        result.completeError(const TransportChangedException());
      }
    });
    unawaited(
      task.then<void>(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    return result.future.whenComplete(subscription.cancel);
  }

  Future<ServiceTransport> _getTransport(int generation) {
    _ensureCurrent(generation);
    final selection = _selecting ??= _transportSelector(server, _proxyResolver)
        .then((value) {
          if (_closed || generation != _generation) {
            value.close();
            throw const TransportChangedException();
          }
          _transport = value;
          return value;
        })
        .catchError((Object error) {
          _ensureCurrent(generation);
          _selecting = null;
          throw error;
        });
    return _duringGeneration(generation, selection);
  }

  void _discard(ServiceTransport? value) {
    value?.close();
    if (identical(value, _transport)) {
      _transport = null;
      _selecting = null;
    }
  }

  /// Keep identity, logical origin, storage namespace and unexpired ICE
  /// credentials; discard sockets and endpoint choices from the old network.
  void resetTransport() {
    if (_closed) return;
    _generation++;
    _transportChanges.add(null);
    _icePending = null;
    _transport?.close();
    _transport = null;
    _selecting = null;
  }

  Future<void> checkHealth() async {
    checkParticipation();
    final generation = _generation;
    _ensureCurrent(generation);
    // A cold selection may spend 5s probing direct paths, then resolve and
    // validate an optional system proxy. Do not cancel that fallback at 5s.
    final budget = _transport == null && _providedClient == null
        ? const Duration(seconds: 20)
        : const Duration(seconds: 5);
    ServiceTransport? transport;
    try {
      await _duringGeneration(
        generation,
        (() async {
          if (_providedClient != null) {
            final request = http.Request('GET', Uri.parse('$server/health'))
              ..followRedirects = false;
            final response = await http.Response.fromStream(
              await _providedClient.send(request),
            );
            final body = jsonDecode(response.body);
            if (response.statusCode != 200 ||
                body is! Map ||
                body['ok'] != true) {
              throw const HttpException('Service health check failed');
            }
          } else {
            transport = await _getTransport(generation);
            await transport!.checkHealth();
          }
        })().timeout(budget),
      );
      _ensureCurrent(generation);
      checkParticipation();
    } catch (_) {
      if (transport != null) _discard(transport);
      _ensureCurrent(generation);
      rethrow;
    }
  }

  Map<String, dynamic>? _iceCache;
  DateTime? _iceValidUntil;
  Future<Map<String, dynamic>>? _icePending;
  Future<Map<String, dynamic>> iceConfiguration() async {
    checkParticipation();
    if (_iceCache != null && _iceValidUntil!.isAfter(DateTime.now())) {
      return _iceCache!;
    }
    if (_icePending != null) return _icePending!;
    final generation = _generation;
    late final Future<Map<String, dynamic>> pending;
    pending = request('POST', '/v1/ice', {})
        .then((value) {
          _ensureCurrent(generation);
          _iceCache = value;
          final expires = value['expiresAt'];
          final expiry = expires is num
              ? DateTime.fromMillisecondsSinceEpoch(expires.toInt())
              : DateTime.now().add(const Duration(minutes: 10));
          _iceValidUntil = expiry.subtract(const Duration(minutes: 5));
          return value;
        })
        .whenComplete(() {
          if (identical(_icePending, pending)) _icePending = null;
        });
    _icePending = pending;
    return pending;
  }

  Future<Map<String, String>> signedHeaders(
    String method,
    String path,
    String body,
  ) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = const Uuid().v4();
    final preimage =
        'nearlink-request-v2\n$method\n$path\n$timestamp\n$nonce\n${await crypto.hash(utf8.encode(body))}\n$clientBuild\n$protocolVersion\n$privacyEpoch';
    return {
      'Content-Type': 'application/json',
      'X-Device-Key': identity.publicKey,
      'X-Timestamp': timestamp,
      'X-Nonce': nonce,
      'X-Client-Build': '$clientBuild',
      'X-Protocol-Version': '$protocolVersion',
      'X-Privacy-Epoch': '$privacyEpoch',
      'X-Signature': await crypto.sign(identity, preimage),
      if (registrationCode.isNotEmpty) 'X-Registration-Code': registrationCode,
    };
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    checkParticipation();
    _checkQuota();
    final generation = _generation;
    _ensureCurrent(generation);
    final body = payload == null ? '' : jsonEncode(payload);
    final transport = _providedClient == null
        ? await _getTransport(generation)
        : null;
    _ensureCurrent(generation);
    checkParticipation();
    final req = http.Request(
      method,
      Uri.parse('${transport?.origin ?? server}$path'),
    );
    req.followRedirects =
        false; // Never forward an access code or signed headers to a redirected origin.
    req.headers.addAll(await signedHeaders(method, path, body));
    _ensureCurrent(generation);
    checkParticipation();
    req.body = body;
    late http.Response response;
    try {
      // One attempt only. A timeout may already have committed remotely; do
      // not regenerate IDs or automatically replay arbitrary POST requests.
      response = await _duringGeneration(
        generation,
        (() async {
          final stream = await (_providedClient ?? transport!.client).send(req);
          const maximum = 2 * 1024 * 1024;
          if ((stream.contentLength ?? 0) > maximum) {
            throw const ApiException('服务响应超过大小限制');
          }
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in stream.stream) {
            if (bytes.length + chunk.length > maximum) {
              throw const ApiException('服务响应超过大小限制');
            }
            bytes.add(chunk);
          }
          return http.Response.bytes(
            bytes.takeBytes(),
            stream.statusCode,
            headers: stream.headers,
            request: stream.request,
            reasonPhrase: stream.reasonPhrase,
          );
        })().timeout(const Duration(seconds: 20)),
      );
      _ensureCurrent(generation);
    } catch (_) {
      if (transport != null) _discard(transport);
      _ensureCurrent(generation);
      rethrow;
    }
    dynamic json;
    try {
      json = jsonDecode(response.body);
    } catch (_) {
      throw ApiException(
        '服务返回了无法识别的响应（${response.statusCode}）',
        status: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = json is Map ? json['error'] : null;
      if (response.statusCode == 503 &&
          error is Map &&
          error['code'] == 'storage_quota_exceeded') {
        final supplied = error['retryAfterSeconds'];
        final seconds = supplied is int
            ? supplied
            : int.tryParse(response.headers['retry-after'] ?? '') ?? 60;
        // The daily reset time is an estimate, not a guarantee of when the
        // service will recover. Recheck at a low rate instead of locking the
        // app out for another day after a rejection just after UTC midnight.
        final delay = Duration(
          seconds: seconds.clamp(1, _quotaProbeInterval.inSeconds),
        );
        _quotaUntil = _elapsed + delay.inMilliseconds;
        // Anchor the server's relative delay to the receipt time, so a device
        // clock that already differs from UTC does not change the cooldown.
        _quotaWallUntil = _wallClock().add(delay);
        throw const StorageQuotaException();
      }
      if (response.statusCode == 426 &&
          error is Map &&
          error['code'] == 'client_upgrade_required') {
        _upgrade(
          UpgradeRequiredException(
            policy: error['policy'] is Map
                ? Map<String, dynamic>.from(error['policy'] as Map)
                : null,
          ),
        );
      }
      throw ApiException(
        error is Map ? (error['message']?.toString() ?? '请求失败') : '请求失败',
        code: error is Map
            ? (error['code']?.toString() ?? 'request_failed')
            : 'request_failed',
        status: response.statusCode,
      );
    }
    if (json is! Map<String, dynamic>) throw const ApiException('服务响应格式错误');
    checkParticipation();
    return json;
  }

  /// The only network operation permitted while participation is blocked.
  /// This carries no identity/access headers and never follows redirects.
  Future<Map<String, dynamic>> fetchClientPolicy() async {
    final generation = _generation;
    final transport = _providedClient == null
        ? await _getTransport(generation)
        : null;
    _ensureCurrent(generation);
    final request = http.Request(
      'GET',
      Uri.parse('${transport?.origin ?? server}/client-policy'),
    )..followRedirects = false;
    final result = await _duringGeneration(
      generation,
      (() async {
        final response = await (_providedClient ?? transport!.client).send(
          request,
        );
        if (response.statusCode != 200) {
          throw ApiException('无法获取有效的参与政策', status: response.statusCode);
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 32 * 1024) {
            throw const ApiException('参与政策响应过大');
          }
          bytes.add(chunk);
        }
        final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('参与政策格式无效');
        }
        return decoded;
      })().timeout(const Duration(seconds: 15)),
    );
    _ensureCurrent(generation);
    return result;
  }

  Future<WebSocket> socket(String groupId) =>
      _openSocket('/v1/groups/$groupId/socket');

  Future<WebSocket> watchSocket(String groupId) =>
      _openSocket('/v1/groups/$groupId/watch');

  Future<WebSocket> _openSocket(String path) async {
    checkParticipation();
    _checkQuota();
    final generation = _generation;
    final transport = await _getTransport(generation);
    _ensureCurrent(generation);
    checkParticipation();
    final httpUri = Uri.parse('${transport.origin}$path');
    // Uri has no default port for ws/wss. Keep the HTTPS/HTTP port explicit so
    // the upgrade's HTTP URI has the same origin, including through a proxy.
    final uri = httpUri.replace(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
      port: httpUri.port,
    );
    final headers = await signedHeaders('GET', path, '');
    _ensureCurrent(generation);
    checkParticipation();
    var abandoned = false;
    final connecting = WebSocket.connect(
      uri.toString(),
      headers: headers,
      customClient: transport.io,
    );
    unawaited(
      connecting.then<void>((socket) {
        if (abandoned || _closed || generation != _generation) {
          unawaited(socket.close().then<void>((_) {}, onError: (Object _) {}));
        }
      }, onError: (Object _) {}),
    );
    try {
      final socket = await _duringGeneration(
        generation,
        connecting.timeout(const Duration(seconds: 20)),
      );
      if (_closed || generation != _generation) {
        await socket.close();
        throw const TransportChangedException();
      }
      try {
        checkParticipation();
      } catch (_) {
        await socket.close();
        rethrow;
      }
      return socket;
    } catch (_) {
      abandoned = true;
      _discard(transport);
      _ensureCurrent(generation);
      rethrow;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _generation++;
    _transportChanges.add(null);
    unawaited(_transportChanges.close());
    _icePending = null;
    _iceCache = null;
    _providedClient?.close();
    _transport?.close();
    _transport = null;
    _selecting = null;
  }
}
