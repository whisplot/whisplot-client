import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/services/voice_dsp.dart';
import 'package:nearlink/ui/voice_bubble.dart';
import 'voice_composer_test.dart' show TestPlayer;

void main() {
  for (final background in [false, true]) {
    testWidgets(
      'late loader after ${background ? 'background' : 'dispose'} never plays and wipes copy',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final player = TestPlayer();
        final loaded = Completer<Uint8List>();
        final wav = encodeVoiceWav(
          Float32List.fromList(List.filled(8000, 0.2)),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VoiceBubble(
                durationMs: 500,
                loader: () => loaded.future,
                player: player,
              ),
            ),
          ),
        );
        await tester.tap(find.text('变声语音 · 0.5 秒'));
        await tester.pump();
        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        loaded.complete(wav);
        await tester.pump();
        expect(player.plays, 0);
        expect(wav.every((sample) => sample == 0), isTrue);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  }
}
