import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/media_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'delete_space_controller_test.dart'
    show newDeleteFixture, expectPurged, groupMediaFiles;
import 'group_departure_controller_test.dart'
    show DepartureBackend, archiveMessage;
import 'media_service_test.dart' show wav;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'late voice download cannot recreate cache after deletion even if the space is admitted again',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mentor-media-delete-race-',
      );
      addTearDown(() async => root.delete(recursive: true));
      final sourceRoot = Directory('${root.path}/source'),
          receiverRoot = Directory('${root.path}/receiver');
      await sourceRoot.create();
      await receiverRoot.create();
      final source = MediaService(directoryProvider: () async => sourceRoot);
      final receiver = MediaService(
        directoryProvider: () async => receiverRoot,
      );
      final crypto = CryptoService();
      const group = Group(
        id: '11111111-1111-4111-8111-111111111111',
        server: 'https://fixture.example',
        name: 'Race',
        ownerId: 'owner',
      );
      final samples = wav(milliseconds: 40);
      final voice = await source.prepareVoice(group, samples);
      final sourceFile =
          (await sourceRoot
                  .list(recursive: true)
                  .where((entry) => entry is File)
                  .cast<File>()
                  .toList())
              .single;
      final ciphertext = await sourceFile.readAsBytes();
      final entered = Completer<void>(), response = Completer<http.Response>();
      var requests = 0;
      final api = ApiClient(
        server: group.server,
        identity: await crypto.identity(),
        crypto: crypto,
        client: MockClient((request) async {
          expect(request.method, 'GET');
          requests++;
          if (!entered.isCompleted) entered.complete();
          return response.future;
        }),
      );
      addTearDown(api.close);
      final lateDownload = expectLater(
        receiver.loadVoice(api, group, voice),
        throwsStateError,
      );
      await entered.future;
      await receiver.deleteGroup(group);
      receiver.allowGroup(group);
      response.complete(
        http.Response(
          jsonEncode({
            'v': 1,
            'mediaId': voice.mediaId,
            'sha256': voice.sha256,
            'size': ciphertext.length,
            'ciphertext': b64(ciphertext),
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await lateDownload;
      expect(
        await receiverRoot
            .list(recursive: true)
            .where((entry) => entry is File)
            .toList(),
        isEmpty,
      );
      // The admission enables a new request; it does not resurrect the old one.
      expect(
        await receiver.loadVoice(api, group, voice),
        orderedEquals(samples),
      );
      expect(requests, 2);
      expect(
        await receiverRoot
            .list(recursive: true)
            .where((entry) => entry is File)
            .toList(),
        hasLength(1),
      );
    },
  );

  test(
    'startup resumes a deletion interrupted after database purge and before key or media cleanup',
    () async {
      final fixture = await newDeleteFixture(), f = fixture.f;
      final backend = DepartureBackend(f), original = f.group;
      await archiveMessage(f, 'removed during interrupted deletion');
      await f.store.saveKey(original, List.filled(32, 23), epoch: 2);
      final cached = await fixture.media.prepareVoice(
        original,
        wav(milliseconds: 40),
      );
      await fixture.media.markMessageStored(original, cached);
      await fixture.media.prepareVoice(original, wav(milliseconds: 50));
      final identitySeed = await f.store.readSecret('identity-seed');
      f.controller.dispose();
      await Future<void>.delayed(Duration.zero);
      const leaveId = '99999999-9999-4999-8999-999999999999';
      await f.store.markGroupDeleted(original, leaveId);
      expect(await f.store.messages(original), isEmpty);
      expect(await f.store.groupKey(original), isNotNull);
      expect(await groupMediaFiles(f, fixture.root, original), hasLength(2));
      expect(
        (await f.store
            .groupDepartures())[original.storageId]!['cleanupPending'],
        isTrue,
      );
      // Model process recreation: both controller and media service lose memory.
      f.media = MediaService(directoryProvider: () async => fixture.root);
      await f.start();
      await expectPurged(f, original);
      expect(await groupMediaFiles(f, fixture.root, original), isEmpty);
      expect(f.controller.groups, isEmpty);
      expect(f.controller.leftGroups, isEmpty);
      expect(await f.store.readSecret('identity-seed'), identitySeed);
      expect((await f.store.groupDepartures())[original.storageId], {
        'leaveId': leaveId,
        'groupId': original.id,
        'server': original.server,
        'pending': false,
        'deleted': true,
        'cleanupPending': false,
      });
      expect(backend.leaveIds.toSet(), {leaveId});
    },
  );
}
