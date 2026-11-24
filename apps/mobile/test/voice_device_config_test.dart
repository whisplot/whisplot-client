import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/voice_capture.dart';
import 'voice_capture_test.dart' show TestProcessor;
import 'voice_pcm_test.dart' show pcm, values;

class RecordChannelProbe {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  static const codec = StandardMethodCodec();
  String id = '';
  int rate = 16000, channels = 2, cancellations = 0;

  RecordChannelProbe() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (call.method == 'create') {
          id = args['recorderId'] as String;
          for (final name in ['events', 'eventsRecord']) {
            messenger.setMockMethodCallHandler(
              MethodChannel('com.llfbandit.record/$name/$id'),
              (_) async => null,
            );
          }
        } else if (call.method == 'hasPermission') {
          return true;
        } else if (call.method == 'isRecording') {
          return false;
        } else if (call.method == 'startStream') {
          // Match the full effective-config callback emitted by record_android.
          await messenger.handlePlatformMessage(
            'com.llfbandit.record/configChanged/$id',
            codec.encodeMethodCall(
              MethodCall('onConfigChanged', {
                ...args,
                'sampleRate': rate,
                'numChannels': channels,
              }),
            ),
            null,
          );
        } else if (call.method == 'stop' || call.method == 'cancel') {
          if (call.method == 'cancel') cancellations++;
          await messenger.handlePlatformMessage(
            'com.llfbandit.record/eventsRecord/$id',
            null,
            null,
          );
        }
        return null;
      },
    );
  }

  Future<void> emit(Uint8List bytes) async {
    await messenger.handlePlatformMessage(
      'com.llfbandit.record/eventsRecord/$id',
      codec.encodeSuccessEnvelope(bytes),
      null,
    );
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'actual recorder Dart bridge accepts negotiated stereo and forwards mono',
    () async {
      final native = RecordChannelProbe();
      final processor = TestProcessor();
      final capture = VoiceCapture(processor: processor);
      await capture.start();
      expect(capture.state, VoiceCaptureState.recording);
      expect(native.cancellations, 0);
      final stereo = pcm(List.generate(3200, (i) => i.isEven ? 1000 : 3000));
      await native.emit(Uint8List.sublistView(stereo, 0, 3));
      await native.emit(Uint8List.sublistView(stereo, 3));
      expect(capture.recordedMs, 100);
      await capture.finish();
      expect(processor.snapshot!.length, 3200);
      expect(values(processor.snapshot!).every((v) => v == 2000), isTrue);
      expect(capture.state, VoiceCaptureState.ready);
      capture.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'negotiated unsupported rate stops and reports format instead of wrong duration',
    () async {
      final native = RecordChannelProbe()..rate = 44100;
      final processor = TestProcessor();
      final capture = VoiceCapture(processor: processor);
      await capture.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(native.cancellations, greaterThan(0));
      expect(capture.state, VoiceCaptureState.idle);
      expect(capture.error, contains('16 kHz'));
      expect(processor.calls, 0);
      expect(capture.wav, isNull);
      capture.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('incomplete negotiated stereo frame cannot reach DSP on stop', () async {
    final native = RecordChannelProbe();
    final processor = TestProcessor();
    final capture = VoiceCapture(processor: processor);
    await capture.start();
    await native.emit(pcm(List.filled(3200, 1000)));
    await native.emit(Uint8List.fromList([1, 2, 3]));
    await capture.finish();
    await Future<void>.delayed(Duration.zero);
    expect(capture.state, VoiceCaptureState.idle);
    expect(processor.calls, 0);
    expect(capture.error, contains('不完整'));
    capture.dispose();
    await Future<void>.delayed(Duration.zero);
  });
}
