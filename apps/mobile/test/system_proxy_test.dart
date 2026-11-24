import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/system_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final widgetHttpOverrides = HttpOverrides.current;
  // These are real loopback transport tests, not widget HTTP stubs.
  setUp(() => HttpOverrides.global = null);
  tearDown(() => HttpOverrides.global = widgetHttpOverrides);

  test(
    'Signed HTTP and WebSocket traffic both use the selected proxy',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final requests = <String>[];
      final codes = <String?>[];
      final peers = <WebSocket>[];
      addTearDown(() async {
        for (final peer in peers) {
          await peer.close();
        }
      });
      proxy.listen((request) async {
        requests.add(request.uri.path);
        codes.add(request.headers.value('X-Registration-Code'));
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final peer = await WebSocketTransformer.upgrade(request);
          peers.add(peer);
          peer.listen(peer.add);
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'ok': true}));
          await request.response.close();
        }
      });
      final crypto = CryptoService();
      final resolved = <Uri>[];
      final api = ApiClient(
        server: 'http://proxy-test.invalid',
        identity: await crypto.identity(),
        crypto: crypto,
        registrationCode: 'public-test-code',
        proxyResolver: (uri) async {
          resolved.add(uri);
          return 'PROXY 127.0.0.1:${proxy.port}';
        },
      );
      addTearDown(api.close);
      expect(
        (await api.request('POST', '/v1/test', {'ping': true}))['ok'],
        true,
      );
      final socket = await api.socket('group');
      final echo = socket.first;
      socket.add('signed socket test');
      expect(await echo, 'signed socket test');
      await socket.close();
      expect(requests, ['/v1/test', '/v1/groups/group/socket']);
      expect(codes, ['public-test-code', 'public-test-code']);
      expect(resolved.map((uri) => uri.scheme), everyElement('http'));
      // HTTP and WebSocket share the immutable route selected for this network
      // generation. A reset selects a new route rather than mutating a pool.
      expect(resolved.length, 1);
    },
  );

  test(
    'A WebSocket redirect cannot forward signed headers to another origin',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final hosts = <String>[];
      proxy.listen((request) async {
        hosts.add(request.headers.host!);
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://another-origin.invalid/collect',
        );
        await request.response.close();
      });
      final crypto = CryptoService();
      final api = ApiClient(
        server: 'http://proxy-test.invalid',
        identity: await crypto.identity(),
        crypto: crypto,
        registrationCode: 'public-test-code',
        proxyResolver: (_) async => 'PROXY 127.0.0.1:${proxy.port}',
      );
      addTearDown(api.close);
      await expectLater(api.socket('group'), throwsA(isA<HttpException>()));
      expect(hosts, ['proxy-test.invalid']);
    },
  );

  test(
    'An unsupported Mac system proxy does not silently connect directly',
    () async {
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests++;
        request.response.write('{"ok":true}');
        await request.response.close();
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemProxy.channel, (_) async {
        throw PlatformException(code: 'unsupported_system_proxy');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemProxy.channel, null),
      );
      final crypto = CryptoService();
      final api = ApiClient(
        server: 'http://127.0.0.1:${server.port}',
        identity: await crypto.identity(),
        crypto: crypto,
      );
      addTearDown(api.close);
      await expectLater(api.request('GET', '/health'), throwsFormatException);
      expect(requests, 0);
    },
    skip: !Platform.isMacOS,
  );
}
