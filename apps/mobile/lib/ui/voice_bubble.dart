import 'dart:async';
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';
import '../services/voice_capture.dart';
import '../services/voice_playback.dart';

class VoiceBubble extends StatefulWidget {
  const VoiceBubble({
    super.key,
    required this.durationMs,
    required this.loader,
    this.player,
  });
  final int durationMs;
  final Future<Uint8List> Function() loader;
  final VoicePlayer? player;
  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> with WidgetsBindingObserver {
  late final VoicePlayer player;
  bool loading = false;
  String? error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    player = widget.player ?? VoicePlayback();
    player.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _generation++;
    unawaited(player.stop().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    player.removeListener(_changed);
    player.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    final generation = ++_generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (player.isPlaying) {
        await player.stop();
      } else {
        final wav = await widget.loader();
        try {
          if (!mounted || generation != _generation) return;
          await player.play(wav);
        } finally {
          wav.fillRange(0, wav.length, 0);
        }
      }
    } on VoiceCancelled {
      // The view was closed or backgrounded while loading/playing.
    } catch (_) {
      if (mounted) {
        error = context.tr(
          '暂时无法播放，点击重试',
          'Cannot play right now. Tap to retry.',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton.icon(
        onPressed: loading ? null : _play,
        icon: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                player.isPlaying
                    ? Icons.stop_rounded
                    : Icons.play_arrow_rounded,
              ),
        label: Text(
          context.tr(
            '变声语音 · ${(widget.durationMs / 1000).toStringAsFixed(1)} 秒',
            'Voice with effects · ${(widget.durationMs / 1000).toStringAsFixed(1)} sec',
          ),
        ),
      ),
      if (error != null)
        Text(
          error!,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
    ],
  );
}
