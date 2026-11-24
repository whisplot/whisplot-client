import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/voice_capture.dart';
import 'package:nearlink/services/voice_dsp.dart';

class TestRecorder implements VoiceRecorder {
  final stream = StreamController<Uint8List>();
  Completer<bool>? permission;
  Completer<void>? starting;
  bool allowed = true;
  int starts = 0, stops = 0, cancels = 0, disposals = 0;
  @override
  Future<bool> hasPermission() async => permission?.future ?? allowed;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    await starting?.future;
    return stream.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    await stream.close();
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class TestProcessor implements VoiceProcessor {
  Uint8List? raw, snapshot;
  Completer<Uint8List>? pending;
  int calls = 0, cancels = 0;
  bool fail = false;
  final output = encodeVoiceWav(Float32List.fromList(List.filled(8000, 0.2)));
  @override
  Future<Uint8List> process(Uint8List pcm) async {
    calls++;
    raw = pcm;
    snapshot = Uint8List.fromList(pcm);
    if (fail) throw StateError('DSP failed');
    return pending?.future ?? Uint8List.fromList(output);
  }

  @override
  void cancel() {
    cancels++;
  }
}

Future<void> deliver(TestRecorder recorder, [int bytes = 16000]) async {
  recorder.stream.add(Uint8List.fromList(List.filled(bytes, 5)));
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'permission is requested only on start; denial exposes no audio',
    () async {
      final recorder = TestRecorder()..allowed = false;
      final processor = TestProcessor();
      final capture = VoiceCapture(recorder: recorder, processor: processor);
      expect(recorder.starts, 0);
      await capture.start();
      expect(recorder.starts, 0);
      expect(capture.error, contains('麦克风权限'));
      expect(capture.wav, isNull);
      expect(processor.calls, 0);
      capture.dispose();
    },
  );

  test(
    'cancellation during permission prompt never starts microphone later',
    () async {
      final recorder = TestRecorder()..permission = Completer<bool>();
      final capture = VoiceCapture(
        recorder: recorder,
        processor: TestProcessor(),
      );
      final starting = capture.start();
      await Future<void>.delayed(Duration.zero);
      await capture.cancel();
      recorder.permission!.complete(true);
      await starting;
      expect(recorder.starts, 0);
      expect(capture.state, VoiceCaptureState.idle);
      capture.dispose();
    },
  );

  test(
    'late native start after cancel is stopped and cannot collect samples',
    () async {
      final recorder = TestRecorder()..starting = Completer<void>();
      final capture = VoiceCapture(
        recorder: recorder,
        processor: TestProcessor(),
      );
      final starting = capture.start();
      await Future<void>.delayed(Duration.zero);
      final cancelling = capture.cancel();
      recorder.starting!.complete();
      await starting;
      await cancelling;
      expect(recorder.cancels, 1);
      expect(capture.state, VoiceCaptureState.idle);
      expect(capture.wav, isNull);
      capture.dispose();
    },
  );

  test('only successful processed output is exposed; raw is cleared', () async {
    final recorder = TestRecorder();
    final processor = TestProcessor();
    final capture = VoiceCapture(recorder: recorder, processor: processor);
    await capture.start();
    await deliver(recorder);
    expect(capture.wav, isNull);
    await capture.finish();
    expect(recorder.stops, 1);
    expect(processor.calls, 1);
    expect(processor.snapshot!.any((value) => value != 0), isTrue);
    expect(processor.raw!.every((value) => value == 0), isTrue);
    expect(capture.wav, orderedEquals(processor.output));
    expect(capture.state, VoiceCaptureState.ready);
    final preview = capture.wav!;
    await capture.cancel();
    expect(preview.every((value) => value == 0), isTrue);
    expect(capture.wav, isNull);
    capture.dispose();
  });

  test(
    'new start waits for stale native start cleanup and is not cancelled',
    () async {
      final recorder = TestRecorder()..starting = Completer<void>();
      final capture = VoiceCapture(
        recorder: recorder,
        processor: TestProcessor(),
      );
      final oldStart = capture.start();
      await Future<void>.delayed(Duration.zero);
      final cancelled = capture.cancel();
      final newStart = capture.start();
      await Future<void>.delayed(Duration.zero);
      expect(recorder.starts, 1);
      recorder.starting!.complete();
      await Future.wait([oldStart, cancelled, newStart]);
      expect(recorder.starts, 2);
      expect(recorder.cancels, 1);
      expect(capture.state, VoiceCaptureState.recording);
      await deliver(recorder);
      expect(capture.recordedMs, 500);
      capture.dispose();
    },
  );

  test('DSP error never falls back to sending original recording', () async {
    final recorder = TestRecorder();
    final processor = TestProcessor()..fail = true;
    final capture = VoiceCapture(recorder: recorder, processor: processor);
    await capture.start();
    await deliver(recorder);
    await capture.finish();
    expect(capture.wav, isNull);
    expect(processor.raw!.every((value) => value == 0), isTrue);
    expect(capture.error, contains('变声处理失败'));
    capture.dispose();
  });

  test('cancellation during DSP rejects and wipes its late result', () async {
    final recorder = TestRecorder();
    final processor = TestProcessor()..pending = Completer<Uint8List>();
    final capture = VoiceCapture(recorder: recorder, processor: processor);
    await capture.start();
    await deliver(recorder);
    final finishing = capture.finish();
    await Future<void>.delayed(Duration.zero);
    await capture.cancel();
    final late = Uint8List.fromList(processor.output);
    processor.pending!.complete(late);
    await finishing;
    expect(capture.wav, isNull);
    expect(capture.state, VoiceCaptureState.idle);
    expect(late.every((value) => value == 0), isTrue);
    expect(processor.raw!.every((value) => value == 0), isTrue);
    capture.dispose();
  });

  test(
    'recording hard limit bounds memory and stops capture automatically',
    () async {
      final recorder = TestRecorder();
      final processor = TestProcessor();
      final capture = VoiceCapture(recorder: recorder, processor: processor);
      await capture.start();
      await deliver(recorder, voiceMaxPcmBytes + 100);
      await Future<void>.delayed(Duration.zero);
      expect(recorder.stops, 1);
      expect(processor.snapshot!.length, voiceMaxPcmBytes);
      expect(capture.state, VoiceCaptureState.ready);
      capture.dispose();
    },
  );

  test(
    'disposing an active capture cancels the recorder and drops raw input',
    () async {
      final recorder = TestRecorder();
      final processor = TestProcessor();
      final capture = VoiceCapture(recorder: recorder, processor: processor);
      await capture.start();
      await deliver(recorder);
      capture.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(recorder.cancels, greaterThanOrEqualTo(1));
      expect(recorder.disposals, 1);
      expect(processor.calls, 0);
      expect(capture.wav, isNull);
    },
  );
}
