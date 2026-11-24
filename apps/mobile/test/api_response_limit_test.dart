import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/services/api_client.dart';

class OversizedClient extends http.BaseClient {
  OversizedClient(this.declared);
  final bool declared;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.fromIterable([
          Uint8List(1024 * 1024),
          Uint8List(1024 * 1024 + 1),
        ]),
        200,
        contentLength: declared ? 2 * 1024 * 1024 + 1 : null,
      );
}

void main() {
  for (final declared in [true, false]) {
    test(
      'bounds ${declared ? 'declared' : 'streaming'} API response before parsing media',
      () async {
        final crypto = CryptoService();
        final client = ApiClient(
          server: 'https://example.test',
          identity: await crypto.identity(),
          crypto: crypto,
          client: OversizedClient(declared),
        );
        try {
          await expectLater(
            client.request('GET', '/v1/test'),
            throwsA(isA<ApiException>()),
          );
        } finally {
          client.close();
        }
      },
    );
  }
}
