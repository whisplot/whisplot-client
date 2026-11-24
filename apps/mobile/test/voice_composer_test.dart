import 'dart:async';
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/voice_capture.dart';
import 'package:nearlink/services/voice_playback.dart';
import 'package:nearlink/ui/voice_composer.dart';
import 'voice_capture_test.dart' show TestRecorder, TestProcessor;

class TestPlayer extends VoicePlayer {
  bool playing = false;
  int plays = 0, stops = 0;
  Completer<void>? pendingPlay, pendingStop;
  @override
  bool get isPlaying => playing;
  @override
  Future<void> play(Uint8List wav) async {
    plays++;
    await pendingPlay?.future;
    playing = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
    await pendingStop?.future;
  }
}

Future<void> mountComposer(
  WidgetTester tester,
  VoiceCapture capture,
  TestPlayer player,
  Future<void> Function(Uint8List) send,
) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) =>
                  VoiceComposer(capture: capture, player: player, onSend: send),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> makeReady(WidgetTester tester, TestRecorder recorder) async {
  await tester.tap(find.text('开始录音（最长 30 秒）'));
  await tester.pumpAndSettle();
  recorder.stream.add(Uint8List.fromList(List.filled(16000, 9)));
  await tester.pump();
  await tester.tap(find.text('停止并变声'));
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('only a successfully previewed changed WAV can be sent', (
    tester,
  ) async {
    final recorder = TestRecorder(),
        processor = TestProcessor(),
        player = TestPlayer();
    final capture = VoiceCapture(recorder: recorder, processor: processor);
    Uint8List? sent;
    await mountComposer(tester, capture, player, (wav) async {
      sent = Uint8List.fromList(wav);
    });
    expect(find.textContaining('仍可能被声纹'), findsOneWidget);
    await makeReady(tester, recorder);
    final send = find.widgetWithText(FilledButton, '发送变声语音');
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    expect(sent, isNull);
    await tester.tap(find.text('试听变声语音'));
    await tester.pumpAndSettle();
    expect(player.plays, 1);
    await tester.tap(find.text('发送变声语音'));
    await tester.pumpAndSettle();
    expect(sent, orderedEquals(processor.output));
    expect(processor.raw!.every((b) => b == 0), isTrue);
    expect(find.byType(VoiceComposer), findsNothing);
  });

  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    testWidgets('$state cancels recording; returning never restarts it', (
      tester,
    ) async {
      final recorder = TestRecorder(), player = TestPlayer();
      final capture = VoiceCapture(
        recorder: recorder,
        processor: TestProcessor(),
      );
      var sends = 0;
      await mountComposer(tester, capture, player, (_) async {
        sends++;
      });
      await tester.tap(find.text('开始录音（最长 30 秒）'));
      await tester.pumpAndSettle();
      expect(capture.state, VoiceCaptureState.recording);
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
      expect(capture.state, VoiceCaptureState.idle);
      expect(capture.wav, isNull);
      expect(recorder.cancels, greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(recorder.starts, 1);
      expect(capture.state, VoiceCaptureState.idle);
      expect(sends, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  testWidgets(
    'late preview completion after focus loss cannot enable sending',
    (tester) async {
      final recorder = TestRecorder(), player = TestPlayer();
      final capture = VoiceCapture(
        recorder: recorder,
        processor: TestProcessor(),
      );
      var sends = 0;
      await mountComposer(tester, capture, player, (_) async {
        sends++;
      });
      await makeReady(tester, recorder);
      player.pendingPlay = Completer<void>();
      await tester.tap(find.text('试听变声语音'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      player.pendingPlay!.complete();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(capture.wav, isNull);
      expect(find.text('发送变声语音'), findsNothing);
      expect(sends, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('leaving during send preparation does not invoke onSend', (
    tester,
  ) async {
    final recorder = TestRecorder(), player = TestPlayer();
    final capture = VoiceCapture(
      recorder: recorder,
      processor: TestProcessor(),
    );
    var sends = 0;
    await mountComposer(tester, capture, player, (_) async {
      sends++;
    });
    await makeReady(tester, recorder);
    await tester.tap(find.text('试听变声语音'));
    await tester.pumpAndSettle();
    player.pendingStop = Completer<void>();
    await tester.tap(find.text('发送变声语音'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    player.pendingStop!.complete();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(sends, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('closing recording sheet cancels microphone without sending', (
    tester,
  ) async {
    final recorder = TestRecorder(), player = TestPlayer();
    final capture = VoiceCapture(
      recorder: recorder,
      processor: TestProcessor(),
    );
    var sends = 0;
    await mountComposer(tester, capture, player, (_) async {
      sends++;
    });
    await tester.tap(find.text('开始录音（最长 30 秒）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    expect(recorder.cancels, greaterThan(0));
    expect(recorder.disposals, 1);
    expect(sends, 0);
  });
}
