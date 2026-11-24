import 'support/security_fixture.dart';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/default_connection.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/api_client.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:nearlink/services/media_service.dart';
import 'package:nearlink/services/rtc_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'alias_reaction_test.dart' show RotationStore;

class FixtureMedia extends MediaService {
  final log = <String>[];
  final uploads = <DateTime>[];
  bool failUpload = false, failCleanup = false, permanentFailure = false;
  ApiException? uploadError;
  Uint8List? observedWav;
  Completer<Uint8List>? delayedLoad;
  late VoiceAttachment attachment;
  @override
  Future<VoiceAttachment> prepareVoice(Group group, Uint8List wav) async {
    log.add('prepare');
    observedWav = Uint8List.fromList(wav);
    return attachment = VoiceAttachment(
      mediaId: '11111111-1111-4111-8111-111111111111',
      key: b64(List.filled(32, 1)),
      nonce: b64(List.filled(12, 2)),
      sha256: b64(List.filled(32, 3)),
      byteLength: 80,
      durationMs: 1000,
    );
  }

  @override
  Future<void> ensureUploaded(
    ApiClient client,
    Group group,
    VoiceAttachment voice, {
    void Function()? checkCurrent,
  }) async {
    checkCurrent?.call();
    log.add('upload');
    uploads.add(DateTime.now());
    if (uploadError != null) throw uploadError!;
    if (failUpload) {
      if (permanentFailure) {
        throw const ApiException('full', code: 'media_storage_full');
      }
      throw StateError('offline');
    }
  }

  @override
  Future<void> markMessageStored(Group group, VoiceAttachment voice) async {
    log.add('mark');
    if (failCleanup) throw StateError('cache unavailable');
  }

  @override
  Future<Uint8List> loadVoice(
    ApiClient client,
    Group group,
    VoiceAttachment voice,
  ) => delayedLoad!.future;
  @override
  Future<void> discardPrepared(Group group, VoiceAttachment voice) async =>
      log.add('discard');
}

class VoiceApi extends ApiClient {
  VoiceApi(Identity identity, CryptoService crypto, this.log)
    : super(server: 'https://example.com', identity: identity, crypto: crypto);
  final List<String> log;
  int resets = 0, nextSeq = 7;
  List<Map<String, dynamic>> page = [];
  @override
  void resetTransport() {
    resets++;
    super.resetTransport();
  }

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    if (method == 'POST' && path.endsWith('/messages')) {
      log.add('post');
      return {'seq': nextSeq++, 'storedAt': 100};
    }
    if (path.contains('/messages?')) {
      return {'messages': page, 'nextCursor': 7, 'hasMore': false};
    }
    if (path.endsWith('/ack')) return {'ok': true};
    throw StateError('Unexpected fixture request');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late RotationStore store;
  late ChatController c;
  late FixtureMedia media;
  late Group group;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalStore.createSchema(db);
    store = RotationStore(db);
    media = FixtureMedia();
    c = PermittedController(
      store: store,
      media: media,
      defaultConnection: const DefaultConnection(),
      mediaRetryDelay: const Duration(milliseconds: 100),
    );
    await c.initialize();
    group = Group(
      keyEpoch: 1,
      protocolVersion: 2,
      privacyEpoch: 2,
      minClientBuild: 5,
      id: '22222222-2222-4222-8222-222222222222',
      server: 'https://example.com',
      name: 'voice',
      ownerId: c.identity.id,
    );
    await store.saveGroup(group);
    await store.saveKey(group, CryptoService().randomBytes(32));
    c.activeGroup = group;
    c.groups = [group];
  });
  tearDown(() async {
    c.dispose();
    await db.close();
  });
  test(
    'offline voice queues once, shares text budget and uploads before envelope',
    () async {
      await c.setAliasRotationLimit(10);
      await c.send('text');
      final text = (await store.outbox(group)).single;
      await store.markStored(group, text.messageId, 1, 50);
      await c.sendVoice(Uint8List.fromList([1, 2, 3]));
      expect(c.aliasMessagesUsed, 2);
      expect(c.messages.last.voice, isNotNull);
      expect(c.messages.last.text, '');
      final api = VoiceApi(c.identity, c.crypto, media.log);
      c.api = api;
      media.failUpload = true;
      await c.flushOutbox(group);
      expect((await store.outbox(group)).length, 1);
      expect(c.aliasMessagesUsed, 2);
      expect(media.log, isNot(contains('post')));
      media.failUpload = false;
      media.failCleanup = true;
      await c.flushOutbox(group);
      expect(await store.outbox(group), isEmpty);
      expect(c.aliasMessagesUsed, 2);
      expect(media.log.indexOf('upload'), lessThan(media.log.indexOf('post')));
      expect(media.log.last, 'mark');
    },
  );
  test(
    'blocked voice upload keeps its ciphertext queued while later text can send',
    () async {
      await c.sendVoice(Uint8List.fromList([1, 2, 3]));
      await c.send('later text');
      media.failUpload = true;
      media.permanentFailure = true;
      c.api = VoiceApi(c.identity, c.crypto, media.log);
      await c.flushOutbox(group);
      expect((await store.outbox(group)).length, 1);
      expect(c.messages.where((m) => m.voice == null).single.state, 'stored');
      expect(c.messages.where((m) => m.voice != null).single.state, 'pending');
      expect(media.log.where((item) => item == 'upload').length, 1);
      expect(media.log.where((item) => item == 'post').length, 1);
      expect(c.error, contains('语音保留在待发队列'));
    },
  );

  test(
    'media retry backs off without resetting healthy transport and later drains',
    () async {
      await c.sendVoice(Uint8List.fromList([1, 2, 3]));
      media.failUpload = true;
      media.permanentFailure = true;
      final api = VoiceApi(c.identity, c.crypto, media.log);
      c.api = api;
      c.online = true;
      c.connection = const ConnectionReport(socketOnline: true);
      final identity = c.identity.id, alias = c.displayName;
      await c.flushOutbox(group);
      // Normal traffic can pass the blocked attachment without bypassing its
      // independent retry delay, even while the WebSocket remains healthy.
      await c.send('text while voice is blocked');
      await c.flushOutbox(group);
      expect(media.uploads, hasLength(1));
      expect(c.messages.where((m) => m.voice == null).single.state, 'stored');
      Future<void> until(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(condition(), isTrue);
      }

      await until(() => media.uploads.length == 2);
      media.failUpload = false;
      await until(() => media.log.contains('mark'));
      await c.flushOutbox(group);
      expect(media.uploads, hasLength(3));
      expect(
        media.uploads[2].difference(media.uploads[1]).inMilliseconds,
        greaterThanOrEqualTo(190),
      );
      expect(api.resets, 0);
      expect(c.connection.socketOnline, isTrue);
      expect(c.online, isTrue);
      expect(c.identity.id, identity);
      expect(c.displayName, isNot(alias)); // Only the new text consumed an ID.
      expect(await store.outbox(group), isEmpty);
    },
  );
  test(
    'legacy media endpoint failure preserves voice and lets text proceed',
    () async {
      await c.sendVoice(Uint8List.fromList([1, 2, 3]));
      await c.send('old server text');
      media.uploadError = const ApiException(
        'Not found',
        code: 'not_found',
        status: 404,
      );
      c.api = VoiceApi(c.identity, c.crypto, media.log);
      await c.flushOutbox(group);
      expect((await store.outbox(group)).length, 1);
      expect(c.messages.where((m) => m.voice == null).single.state, 'stored');
      expect(c.error, contains('请管理员升级'));
    },
  );
  test(
    'transport failure stops the batch instead of trying every later message',
    () async {
      await c.sendVoice(Uint8List.fromList([1, 2, 3]));
      await c.send('later text');
      media.failUpload = true;
      c.api = VoiceApi(c.identity, c.crypto, media.log);
      await c.flushOutbox(group);
      expect((await store.outbox(group)).length, 2);
      expect(media.log.where((item) => item == 'upload').length, 1);
      expect(media.log, isNot(contains('post')));
    },
  );

  test(
    'sendVoice owns its queued buffer when the caller clears its copy',
    () async {
      final wav = Uint8List.fromList([1, 2, 3]);
      final queued = c.sendVoice(wav);
      wav.fillRange(0, wav.length, 0);
      await queued;
      expect(media.observedWav, [1, 2, 3]);
    },
  );

  test(
    'late playback after leaving group is rejected and decoded bytes are cleared',
    () async {
      await c.sendVoice(Uint8List.fromList([1, 2, 3]));
      c.api = VoiceApi(c.identity, c.crypto, media.log);
      media.delayedLoad = Completer<Uint8List>();
      final playing = c.loadVoice(c.messages.single);
      final rejected = expectLater(playing, throwsA(anything));
      await c.closeGroup();
      final decoded = Uint8List.fromList([4, 5, 6]);
      media.delayedLoad!.complete(decoded);
      await rejected;
      expect(decoded, [0, 0, 0]);
    },
  );

  test(
    'failed atomic voice enqueue discards prepared ciphertext without consuming alias',
    () async {
      final alias = c.displayName, state = await store.readAliasState();
      await db.execute(
        "CREATE TRIGGER fail_voice BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      await expectLater(c.sendVoice(Uint8List(1)), throwsA(anything));
      expect(await store.outbox(group), isEmpty);
      expect(c.displayName, alias);
      expect(await store.readAliasState(), state);
      expect(media.log, ['prepare', 'discard']);
    },
  );
  test(
    'mailbox confirmation after lost POST response releases pending voice only after commit',
    () async {
      await c.sendVoice(Uint8List(1));
      final envelope = (await store.outbox(group)).single;
      final api = VoiceApi(c.identity, c.crypto, media.log)
        ..page = [
          {...envelope.toJson(), 'seq': 7, 'storedAt': 100},
        ];
      c.api = api;
      await c.syncActive();
      expect(await store.outbox(group), isEmpty);
      expect(await store.cursor(group), 7);
      expect(media.log, ['prepare', 'mark']);
      expect(c.messages.single.voice, isNotNull);
      expect(c.messages.single.temporarySenderId, '已过期 ID');
    },
  );
}
