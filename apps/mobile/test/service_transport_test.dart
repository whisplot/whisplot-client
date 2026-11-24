import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/service_transport.dart';

typedef _Selector =
    Future<ServiceTransport> Function(String, Future<String?> Function(Uri));

Future<ApiClient> _api({
  String server = productionServiceOrigin,
  _Selector? select,
  http.Client? client,
  Future<String?> Function(Uri)? resolve,
}) async {
  final crypto = CryptoService();
  return ApiClient(
    server: server,
    identity: await crypto.identity(),
    crypto: crypto,
    registrationCode: 'test-only-access-code',
    client: client,
    transportSelector: select,
    proxyResolver: resolve ?? (_) async => 'DIRECT',
  );
}

String _origin(HttpServer server) => 'http://127.0.0.1:${server.port}';

Future<HttpServer> _server() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  return server;
}

Future<void> _json(HttpRequest request, Map<String, Object?> body) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

// Models a socket handshake whose underlying IO has already escaped immediate
// cancellation. The HTTP/WebSocket traffic is real loopback traffic; only the
// close timing is controlled so the late-success ownership path is exercised.
class _DelayedCloseTransport extends ServiceTransport {
  _DelayedCloseTransport(super.origin) : super(proxy: 'DIRECT');
  bool closeRequested = false;

  @override
  void close() => closeRequested = true;

  void disposeIo() => super.close();
}

class _ControlledHealthTransport extends ServiceTransport {
  _ControlledHealthTransport() : super('http://127.0.0.1:1', proxy: 'DIRECT');
  Future<void> Function() health = () async {};

  @override
  Future<void> checkHealth() => health();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final widgetOverrides = HttpOverrides.current;
  setUp(() => HttpOverrides.global = null);
  tearDown(() => HttpOverrides.global = widgetOverrides);

  testWidgets(
    'cold route selection can exceed five seconds; a hot health call remains bounded',
    (tester) async {
      final transport = _ControlledHealthTransport();
      final api = (await tester.runAsync(
        () => _api(
          select: (_, _) async {
            await Future<void>.delayed(const Duration(seconds: 6));
            return transport;
          },
        ),
      ))!;
      addTearDown(api.close);
      final coldCheck = expectLater(api.checkHealth(), completes);
      await tester.pump(const Duration(seconds: 6));
      await coldCheck;

      final stalledHealth = Completer<void>();
      transport.health = () => stalledHealth.future;
      final hotCheck = expectLater(
        api.checkHealth(),
        throwsA(isA<TimeoutException>()),
      );
      await tester.pump(const Duration(seconds: 5));
      await hotCheck;
      expect(transport.closed, isTrue);
      stalledHealth.complete();
      await tester.pump();
    },
  );

  test(
    'an alternate transport preserves the logical server and identity',
    () async {
      final backend = await _server();
      final seen = <HttpRequest>[];
      backend.listen((request) async {
        seen.add(request);
        await _json(request, {'ok': true, 'version': 1});
      });
      var selections = 0;
      final api = await _api(
        select: (logical, resolver) async {
          expect(logical, productionServiceOrigin);
          selections++;
          return ServiceTransport(_origin(backend), proxy: 'DIRECT');
        },
      );
      addTearDown(api.close);
      final identity = api.identity;
      await api.checkHealth();
      await api.request('POST', '/v1/test?cursor=1', {'value': 'opaque'});
      expect(api.server, productionServiceOrigin);
      expect(identical(api.identity, identity), isTrue);
      expect(selections, 1);
      expect(seen.map((request) => request.uri.path), ['/health', '/v1/test']);
      expect(seen.last.uri.query, 'cursor=1');
      expect(seen.last.headers.value('X-Device-Key'), identity.publicKey);
      expect(
        seen.last.headers.value('X-Registration-Code'),
        'test-only-access-code',
      );
      for (final name in [
        'X-Device-Key',
        'X-Signature',
        'X-Nonce',
        'X-Timestamp',
        'X-Registration-Code',
        'Authorization',
      ]) {
        expect(
          seen.first.headers.value(name),
          isNull,
          reason: 'health must not send $name',
        );
      }
    },
  );

  test(
    'a custom server keeps its exact origin and never selects production aliases',
    () async {
      final backend = await _server();
      var requests = 0;
      backend.listen((request) async {
        requests++;
        expect(request.uri.path, '/health');
        expect(request.headers.value('X-Registration-Code'), isNull);
        await _json(request, {'ok': true, 'version': 1});
      });
      final resolved = <Uri>[];
      final transport = await selectServiceTransport(_origin(backend), (
        uri,
      ) async {
        resolved.add(uri);
        return 'DIRECT';
      });
      addTearDown(transport.close);
      expect(transport.origin, _origin(backend));
      expect(resolved, [Uri.parse(_origin(backend))]);
      expect(
        requests,
        0,
        reason: 'selecting a custom route does not probe another service',
      );
      await transport.checkHealth();
      expect(requests, 1);
    },
  );

  test(
    'a generation keeps one proxy route and reset selects the current route',
    () async {
      final first = await _server();
      final second = await _server();
      final counts = [0, 0];
      first.listen((request) async {
        counts[0]++;
        expect(request.headers.host, 'custom-service.invalid');
        await _json(request, {'route': 1});
      });
      second.listen((request) async {
        counts[1]++;
        expect(request.headers.host, 'custom-service.invalid');
        await _json(request, {'route': 2});
      });
      var currentPort = first.port;
      var resolutions = 0;
      final api = await _api(
        server: 'http://custom-service.invalid',
        resolve: (_) async {
          resolutions++;
          return 'PROXY 127.0.0.1:$currentPort';
        },
      );
      addTearDown(api.close);
      expect((await api.request('GET', '/v1/test'))['route'], 1);
      currentPort = second.port;
      expect((await api.request('GET', '/v1/test'))['route'], 1);
      expect(resolutions, 1);
      api.resetTransport();
      expect(api.transportGeneration, 1);
      expect((await api.request('GET', '/v1/test'))['route'], 2);
      expect(resolutions, 2);
      expect(counts, [2, 1]);
      expect(api.server, 'http://custom-service.invalid');
    },
  );

  test('signed HTTP redirects are not followed to another origin', () async {
    final source = await _server();
    final destination = await _server();
    var destinationRequests = 0;
    destination.listen((request) async {
      destinationRequests++;
      await _json(request, {'unexpected': true});
    });
    source.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        '${_origin(destination)}/collect',
      );
      await _json(request, {
        'error': {'message': 'redirect'},
      });
    });
    final transport = ServiceTransport(_origin(source), proxy: 'DIRECT');
    final api = await _api(select: (_, _) async => transport);
    addTearDown(api.close);
    await expectLater(
      api.request('POST', '/v1/test', {'private': 'test fixture'}),
      throwsA(
        isA<ApiException>().having((error) => error.status, 'status', 302),
      ),
    );
    await expectLater(
      transport.io.getUrl(Uri.parse('${_origin(destination)}/collect')),
      throwsA(isA<HttpException>()),
    );
    expect(destinationRequests, 0);
  });

  test(
    'reset rejects a completed old HTTP response and permits new work',
    () async {
      final started = Completer<void>();
      final late = Completer<http.Response>();
      var requests = 0;
      final api = await _api(
        client: MockClient((request) async {
          requests++;
          if (requests == 1) {
            started.complete();
            return late.future;
          }
          return http.Response('{"generation":"new"}', 200);
        }),
      );
      addTearDown(api.close);
      final old = api.request('GET', '/v1/test');
      final rejected = expectLater(
        old,
        throwsA(isA<TransportChangedException>()),
      );
      await started.future;
      api.resetTransport();
      expect((await api.request('GET', '/v1/test'))['generation'], 'new');
      late.complete(http.Response('{"generation":"old"}', 200));
      await rejected;
      expect(requests, 2);
    },
  );

  test(
    'an old pending route closes without replacing the new generation',
    () async {
      final oldBackend = await _server();
      final newBackend = await _server();
      var oldRequests = 0;
      var newRequests = 0;
      oldBackend.listen((request) async {
        oldRequests++;
        await _json(request, {'route': 'old'});
      });
      newBackend.listen((request) async {
        newRequests++;
        await _json(request, {'route': 'new'});
      });
      final oldRoute = ServiceTransport(_origin(oldBackend), proxy: 'DIRECT');
      addTearDown(oldRoute.close);
      final selected = Completer<void>();
      final late = Completer<ServiceTransport>();
      var selections = 0;
      final api = await _api(
        select: (_, _) async {
          selections++;
          if (selections == 1) {
            selected.complete();
            return late.future;
          }
          return ServiceTransport(_origin(newBackend), proxy: 'DIRECT');
        },
      );
      addTearDown(api.close);
      final old = api.request('GET', '/v1/test');
      final rejected = expectLater(
        old,
        throwsA(isA<TransportChangedException>()),
      );
      await selected.future;
      api.resetTransport();
      expect((await api.request('GET', '/v1/test'))['route'], 'new');
      late.complete(oldRoute);
      await rejected;
      expect(oldRoute.closed, isTrue);
      expect((await api.request('GET', '/v1/test'))['route'], 'new');
      expect(selections, 2);
      expect(oldRequests, 0);
      expect(newRequests, 2);
    },
  );

  test(
    'a business POST failure is returned without automatic replay',
    () async {
      final backend = await _server();
      var posts = 0;
      var selections = 0;
      backend.listen((request) async {
        expect(request.method, 'POST');
        posts++;
        await request.drain<void>();
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await _json(request, {
          'error': {'code': 'test_failure', 'message': 'already attempted'},
        });
      });
      final api = await _api(
        select: (_, _) async {
          selections++;
          return ServiceTransport(_origin(backend), proxy: 'DIRECT');
        },
      );
      addTearDown(api.close);
      await expectLater(
        api.request('POST', '/v1/groups', {'groupId': 'stable-test-id'}),
        throwsA(
          isA<ApiException>().having((error) => error.status, 'status', 503),
        ),
      );
      expect(posts, 1);
      expect(selections, 1);
    },
  );

  test('a POST transport exception is not silently sent again', () async {
    var attempts = 0;
    final api = await _api(
      client: MockClient((request) async {
        attempts++;
        expect(request.method, 'POST');
        throw http.ClientException('connection lost after possible commit');
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.request('POST', '/v1/groups', {'groupId': 'stable-test-id'}),
      throwsA(isA<http.ClientException>()),
    );
    expect(attempts, 1);
  });

  test(
    'an old selector failure cannot invalidate the newly selected route',
    () async {
      final backend = await _server();
      backend.listen((request) => _json(request, {'route': 'new'}));
      final selectingOld = Completer<void>();
      final oldSelection = Completer<ServiceTransport>();
      var selections = 0;
      final api = await _api(
        select: (_, _) async {
          selections++;
          if (selections == 1) {
            selectingOld.complete();
            return oldSelection.future;
          }
          return ServiceTransport(_origin(backend), proxy: 'DIRECT');
        },
      );
      addTearDown(api.close);
      final old = api.request('GET', '/v1/test');
      final rejected = expectLater(
        old,
        throwsA(isA<TransportChangedException>()),
      );
      await selectingOld.future;
      api.resetTransport();
      expect((await api.request('GET', '/v1/test'))['route'], 'new');
      oldSelection.completeError(
        const SocketException('old network unavailable'),
      );
      await rejected;
      expect((await api.request('GET', '/v1/test'))['route'], 'new');
      expect(selections, 2);
    },
  );

  test(
    'reset immediately abandons a stalled selector and new requests can proceed',
    () async {
      final backend = await _server();
      backend.listen((request) => _json(request, {'route': 'new'}));
      final selectingOld = Completer<void>();
      final stalledSelection = Completer<ServiceTransport>();
      var selections = 0;
      final api = await _api(
        select: (_, _) async {
          selections++;
          if (selections == 1) {
            selectingOld.complete();
            return stalledSelection.future;
          }
          return ServiceTransport(_origin(backend), proxy: 'DIRECT');
        },
      );
      addTearDown(api.close);
      final pending = api.request('GET', '/v1/test');
      final rejected = expectLater(
        pending,
        throwsA(isA<TransportChangedException>()),
      );
      await selectingOld.future;
      api.resetTransport();
      // Complete the caller while the original selector is still unresolved.
      await rejected.timeout(const Duration(seconds: 1));
      expect(stalledSelection.isCompleted, isFalse);
      expect((await api.request('GET', '/v1/test'))['route'], 'new');
      expect(selections, 2);
      stalledSelection.completeError(
        const SocketException('late old selector failure'),
      );
      await Future<void>.delayed(Duration.zero);
    },
  );

  for (final oldResult in ['success', 'failure']) {
    test(
      'late ICE $oldResult cannot replace or clear new-network ICE work',
      () async {
        final firstStarted = Completer<void>();
        final secondStarted = Completer<void>();
        final oldResponse = Completer<http.Response>();
        final newResponse = Completer<http.Response>();
        var attempts = 0;
        final api = await _api(
          client: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/v1/ice');
            attempts++;
            if (attempts == 1) {
              firstStarted.complete();
              return oldResponse.future;
            }
            if (attempts == 2) {
              secondStarted.complete();
              return newResponse.future;
            }
            throw StateError(
              'An old completion incorrectly cleared current ICE work',
            );
          }),
        );
        addTearDown(api.close);
        final old = api.iceConfiguration();
        final rejected = expectLater(
          old,
          throwsA(isA<TransportChangedException>()),
        );
        await firstStarted.future;
        api.resetTransport();
        final current = api.iceConfiguration();
        // A fresh network must not wait for the still-hanging old credential call.
        await secondStarted.future.timeout(const Duration(seconds: 3));
        final expires = DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch;
        if (oldResult == 'success') {
          oldResponse.complete(
            http.Response(
              jsonEncode({
                'route': 'old',
                'iceServers': [],
                'expiresAt': expires,
              }),
              200,
            ),
          );
        } else {
          oldResponse.completeError(
            http.ClientException('old network disconnected'),
          );
        }
        await rejected;
        final sharedCurrent = api.iceConfiguration();
        final results = Future.wait([current, sharedCurrent]);
        newResponse.complete(
          http.Response(
            jsonEncode({
              'route': 'new',
              'iceServers': [],
              'expiresAt': expires,
            }),
            200,
          ),
        );
        expect((await results).map((value) => value['route']), ['new', 'new']);
        expect(attempts, 2);
        expect((await api.iceConfiguration())['route'], 'new');
        api.resetTransport();
        expect((await api.iceConfiguration())['route'], 'new');
        expect(attempts, 2, reason: 'a valid ICE cache survives network reset');
      },
    );
  }

  for (final action in ['close', 'reset']) {
    test(
      'a WebSocket that completes after $action is actively closed',
      () async {
        final backend = await _server();
        final arrived = Completer<void>();
        final allowUpgrade = Completer<void>();
        final peerClosed = Completer<void>();
        final peers = <WebSocket>[];
        backend.listen((request) async {
          expect(WebSocketTransformer.isUpgradeRequest(request), isTrue);
          arrived.complete();
          await allowUpgrade.future;
          final peer = await WebSocketTransformer.upgrade(request);
          peers.add(peer);
          peer.listen(
            (_) {},
            onDone: () {
              if (!peerClosed.isCompleted) peerClosed.complete();
            },
          );
        });
        final transport = _DelayedCloseTransport(_origin(backend));
        final api = await _api(select: (_, _) async => transport);
        addTearDown(() async {
          api.close();
          transport.disposeIo();
          if (!allowUpgrade.isCompleted) allowUpgrade.complete();
          for (final peer in peers) {
            await peer.close();
          }
        });
        final pending = api.socket('test-group');
        final rejected = expectLater(
          pending,
          throwsA(isA<TransportChangedException>()),
        );
        await arrived.future.timeout(const Duration(seconds: 3));
        if (action == 'close') {
          api.close();
        } else {
          api.resetTransport();
        }
        expect(transport.closeRequested, isTrue);
        allowUpgrade.complete();
        await rejected;
        await peerClosed.future.timeout(const Duration(seconds: 3));
        expect(peers.single.readyState, WebSocket.closed);
      },
    );
  }
}
