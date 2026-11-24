import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/system_text.dart';

void main() {
  test('quota notice is localized without translating user content', () {
    final message = const StorageQuotaException().message;
    expect(translateSystemText(message, english: false), message);
    expect(
      translateSystemText(message, english: true),
      contains('daily write limit'),
    );
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'quota cooldown suppresses writes and survives transport reset, then retries',
    () async {
      final crypto = CryptoService();
      var now = 0, requests = 0;
      final client = ApiClient(
        server: 'https://example.test',
        identity: await crypto.identity(),
        crypto: crypto,
        elapsedMilliseconds: () => now,
        wallClock: () => DateTime.utc(2000),
        client: MockClient((request) async {
          requests++;
          if (requests == 1) {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 'storage_quota_exceeded',
                  'retryAfterSeconds': 60,
                },
              }),
              503,
            );
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.request('POST', '/v1/test', {'keep': 'unchanged'}),
        throwsA(isA<StorageQuotaException>()),
      );
      client.resetTransport();
      await expectLater(
        client.request('GET', '/v1/groups'),
        throwsA(isA<StorageQuotaException>()),
      );
      await expectLater(
        client.watchSocket('room'),
        throwsA(isA<StorageQuotaException>()),
      );
      expect(requests, 1);
      expect(client.quotaRetryAfter, const Duration(minutes: 1));
      now = 60001;
      expect(await client.request('GET', '/v1/groups'), {'ok': true});
      expect(requests, 2);
    },
  );

  test(
    'quota is rechecked within 15 minutes and policy fetch remains available',
    () async {
      final crypto = CryptoService();
      var now = 0;
      final paths = <String>[];
      final client = ApiClient(
        server: 'https://example.test',
        identity: await crypto.identity(),
        crypto: crypto,
        elapsedMilliseconds: () => now,
        wallClock: () => DateTime.utc(2000),
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/client-policy') {
            return http.Response('{"payload":{},"signature":"test"}', 200);
          }
          return http.Response(
            '{"error":{"code":"storage_quota_exceeded","retryAfterSeconds":99999999}}',
            503,
          );
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.request('GET', '/v1/groups'),
        throwsA(isA<StorageQuotaException>()),
      );
      expect(client.quotaRetryAfter, const Duration(minutes: 15));
      expect((await client.fetchClientPolicy())['signature'], 'test');
      now = const Duration(minutes: 15).inMilliseconds;
      expect(client.quotaRetryAfter, Duration.zero);
      expect(paths, ['/v1/groups', '/client-policy']);
      await expectLater(
        client.request('GET', '/v1/groups'),
        throwsA(isA<StorageQuotaException>()),
      );
      expect(paths, ['/v1/groups', '/client-policy', '/v1/groups']);
      expect(client.quotaRetryAfter, const Duration(minutes: 15));
    },
  );

  test(
    'sleep expires quota even when monotonic time does not advance',
    () async {
      final crypto = CryptoService();
      // An intentionally incorrect UTC clock must still honor the relative
      // server delay, rather than interpreting retryAt with the device's skew.
      var wall = DateTime.utc(2000), requests = 0;
      final client = ApiClient(
        server: 'https://example.test',
        identity: await crypto.identity(),
        crypto: crypto,
        elapsedMilliseconds: () => 0,
        wallClock: () => wall,
        client: MockClient((request) async {
          requests++;
          if (requests == 1) {
            return http.Response(
              '{"error":{"code":"storage_quota_exceeded",'
              '"retryAfterSeconds":21600,"retryAt":1795392000000}}',
              503,
            );
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.request('GET', '/v1/groups'),
        throwsA(isA<StorageQuotaException>()),
      );
      expect(client.quotaRetryAfter, const Duration(minutes: 15));
      wall = wall.add(const Duration(hours: 9));
      expect(client.quotaRetryAfter, Duration.zero);
      // No process restart or transport reset is necessary after waking.
      expect(await client.request('GET', '/v1/groups'), {'ok': true});
      expect(requests, 2);
      wall = wall.subtract(const Duration(days: 1));
      expect(client.quotaRetryAfter, Duration.zero);
    },
  );

  test('clock rollback cannot extend the monotonic quota deadline', () async {
    final crypto = CryptoService();
    var wall = DateTime.utc(2000), elapsed = 0;
    final client = ApiClient(
      server: 'https://example.test',
      identity: await crypto.identity(),
      crypto: crypto,
      elapsedMilliseconds: () => elapsed,
      wallClock: () => wall,
      client: MockClient(
        (request) async => http.Response(
          '{"error":{"code":"storage_quota_exceeded","retryAfterSeconds":60}}',
          503,
        ),
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.request('GET', '/v1/groups'),
      throwsA(isA<StorageQuotaException>()),
    );
    wall = wall.subtract(const Duration(hours: 1));
    elapsed = 30000;
    expect(client.quotaRetryAfter, const Duration(seconds: 30));
    elapsed = 60000;
    expect(client.quotaRetryAfter, Duration.zero);
    wall = wall.subtract(const Duration(hours: 1));
    expect(client.quotaRetryAfter, Duration.zero);
  });

  test(
    'clock forward permits a probe but fresh server quota still applies',
    () async {
      final crypto = CryptoService();
      var wall = DateTime.utc(2000), requests = 0;
      final client = ApiClient(
        server: 'https://example.test',
        identity: await crypto.identity(),
        crypto: crypto,
        elapsedMilliseconds: () => 0,
        wallClock: () => wall,
        client: MockClient((request) async {
          requests++;
          return http.Response(
            '{"error":{"code":"storage_quota_exceeded","retryAfterSeconds":60}}',
            503,
          );
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.request('GET', '/v1/groups'),
        throwsA(isA<StorageQuotaException>()),
      );
      wall = wall.add(const Duration(hours: 1));
      await expectLater(
        client.request('GET', '/v1/groups'),
        throwsA(isA<StorageQuotaException>()),
      );
      expect(requests, 2);
      expect(client.quotaRetryAfter, const Duration(minutes: 1));
      await expectLater(
        client.request('GET', '/v1/groups'),
        throwsA(isA<StorageQuotaException>()),
      );
      expect(requests, 2);
    },
  );

  for (final sleep in [true, false]) {
    test(
      'manual quota retry is throttled across ${sleep ? 'sleep' : 'clock rollback'}',
      () async {
        final crypto = CryptoService();
        var wall = DateTime.utc(2000), elapsed = 0, requests = 0;
        final client = ApiClient(
          server: 'https://example.test',
          identity: await crypto.identity(),
          crypto: crypto,
          elapsedMilliseconds: () => elapsed,
          wallClock: () => wall,
          client: MockClient((request) async {
            requests++;
            return http.Response(
              '{"error":{"code":"storage_quota_exceeded","retryAfterSeconds":86400}}',
              503,
            );
          }),
        );
        addTearDown(client.close);
        Future<void> rejectProbe() => expectLater(
          client.request('GET', '/v1/groups'),
          throwsA(isA<StorageQuotaException>()),
        );
        await rejectProbe();
        expect(client.prepareManualQuotaRetry(), isTrue);
        // Repeated clicks must also be suppressed while a probe is in flight.
        expect(client.prepareManualQuotaRetry(), isFalse);
        await rejectProbe();
        expect(requests, 2);
        expect(client.quotaRetryAfter, const Duration(minutes: 15));
        expect(client.prepareManualQuotaRetry(), isFalse);
        if (sleep) {
          wall = wall.add(const Duration(seconds: 29));
        } else {
          wall = wall.subtract(const Duration(hours: 1));
          elapsed = 29000;
        }
        expect(client.prepareManualQuotaRetry(), isFalse);
        if (sleep) {
          wall = wall.add(const Duration(seconds: 1));
        } else {
          elapsed = 30000;
        }
        expect(client.prepareManualQuotaRetry(), isTrue);
        await rejectProbe();
        expect(requests, 3);
        expect(client.prepareManualQuotaRetry(), isFalse);

        // A manual quota probe never clears the independent participation gate.
        elapsed += 30000;
        wall = wall.add(const Duration(seconds: 30));
        client.blockParticipation(const UpgradeRequiredException());
        expect(client.prepareManualQuotaRetry(), isTrue);
        await expectLater(
          client.request('GET', '/v1/groups'),
          throwsA(isA<UpgradeRequiredException>()),
        );
        expect(requests, 3);
      },
    );
  }
}
