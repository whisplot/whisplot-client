import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/media_service.dart';
import 'package:nearlink/services/media_wav.dart';

Uint8List wav({int milliseconds = 1000}) {
  final samples = 16 * milliseconds;
  final data = Uint8List(44 + samples * 2);
  final b = ByteData.sublistView(data);
  void tag(int offset, String text) =>
      data.setRange(offset, offset + text.length, ascii.encode(text));
  tag(0, 'RIFF');
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  tag(36, 'data');
  b.setUint32(4, data.length - 8, Endian.little);
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  b.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    b.setInt16(
      44 + 2 * i,
      (10000 * sin(2 * pi * 220 * i / 16000)).round(),
      Endian.little,
    );
  }
  return data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const group = Group(
    id: 'd20fa033-a476-48ab-9682-400a62c6847d',
    server: 'https://chat.example',
    name: 'Test',
    ownerId: 'owner',
  );
  late Directory root;
  late MediaService service;
  late ApiClient api;
  late Map<String, dynamic>? remote;
  late int uploads;
  final crypto = CryptoService();
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentor-media-test-');
    service = MediaService(directoryProvider: () async => root);
    remote = null;
    uploads = 0;
    api = ApiClient(
      server: group.server,
      identity: await crypto.identity(),
      crypto: crypto,
      client: MockClient((request) async {
        if (request.method == 'PUT') {
          uploads++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.keys.toSet(), {'v', 'ciphertext', 'sha256'});
          remote = {
            ...body,
            'mediaId': request.url.pathSegments.last,
            'size': unb64(body['ciphertext']).length,
          };
        }
        return http.Response(jsonEncode(remote), 200);
      }),
    );
  });
  tearDown(() async {
    api.close();
    await root.delete(recursive: true);
  });

  test(
    'offline queue persists ciphertext and survives service recreation',
    () async {
      final clear = wav(),
          attachment = await service.prepareVoice(group, wav());
      final files = await root
          .list(recursive: true)
          .where((e) => e is File)
          .cast<File>()
          .toList();
      expect(files, hasLength(1));
      final disk = await files.single.readAsBytes();
      expect(disk.length, clear.length + 16);
      expect(disk, isNot(orderedEquals(clear)));
      expect(await crypto.hash(disk), attachment.sha256);
      final restarted = MediaService(directoryProvider: () async => root);
      expect(await restarted.loadVoice(api, group, attachment), clear);
      expect(uploads, 0);
    },
  );

  test(
    'uploaded voice is verifiable by a fresh receiver and cache is encrypted',
    () async {
      final attachment = await service.prepareVoice(group, wav());
      await service.ensureUploaded(api, group, attachment);
      expect(uploads, 1);
      await service.markMessageStored(group, attachment);
      final receiverRoot = await Directory.systemTemp.createTemp(
        'mentor-media-receiver-',
      );
      try {
        final receiver = MediaService(
          directoryProvider: () async => receiverRoot,
        );
        expect(await receiver.loadVoice(api, group, attachment), wav());
        final files = await receiverRoot
            .list(recursive: true)
            .where((e) => e is File)
            .cast<File>()
            .toList();
        expect(await files.single.readAsBytes(), unb64(remote!['ciphertext']));
        expect(
          await Directory('${root.path}/voice-v1/pending').list().length,
          0,
        );
      } finally {
        await receiverRoot.delete(recursive: true);
      }
    },
  );

  test(
    'rejects changed ciphertext and wrong authenticated group without caching it',
    () async {
      final attachment = await service.prepareVoice(group, wav());
      await service.ensureUploaded(api, group, attachment);
      await service.discardPrepared(group, attachment);
      final wrongGroup = Group(
        id: '76bf70eb-9ed3-4076-bfeb-08f8352bac4c',
        server: group.server,
        name: 'Other',
        ownerId: 'owner',
      );
      await expectLater(
        service.loadVoice(api, wrongGroup, attachment),
        throwsA(anything),
      );
      final tampered = unb64(remote!['ciphertext']);
      tampered[0] ^= 1;
      remote!['ciphertext'] = b64(tampered);
      await expectLater(
        service.loadVoice(api, group, attachment),
        throwsFormatException,
      );
      expect(await Directory('${root.path}/voice-v1/cache').list().length, 0);
    },
  );

  test('rejects misleading duration and malformed or overlong audio', () async {
    final attachment = await service.prepareVoice(group, wav());
    final wrong = VoiceAttachment.fromJson({
      ...attachment.toJson(),
      'durationMs': 500,
    });
    await expectLater(
      service.loadVoice(api, group, wrong),
      throwsFormatException,
    );
    await expectLater(
      service.prepareVoice(group, wav(milliseconds: 30001)),
      throwsFormatException,
    );
    final malformed = wav();
    malformed[12] = 0;
    await expectLater(
      service.prepareVoice(group, malformed),
      throwsFormatException,
    );
    expect(MediaWav.durationMs(wav(milliseconds: 30000)), 30000);
  });

  test(
    'rejects another service before upload and discards only failed pending preparation',
    () async {
      final attachment = await service.prepareVoice(group, wav());
      final foreign = Group(
        id: group.id,
        server: 'https://other.example',
        name: 'Other',
        ownerId: 'owner',
      );
      await expectLater(
        service.ensureUploaded(api, foreign, attachment),
        throwsFormatException,
      );
      expect(uploads, 0);
      await service.discardPrepared(group, attachment);
      expect(await Directory('${root.path}/voice-v1/pending').list().length, 0);
    },
  );
}
