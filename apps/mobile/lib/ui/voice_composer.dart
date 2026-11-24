import 'dart:async';
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';
import '../services/voice_capture.dart';
import '../services/voice_dsp.dart';
import '../services/voice_playback.dart';

/// Only [VoiceCapture.wav], produced by successful local DSP, can reach onSend.
class VoiceComposer extends StatefulWidget {
  const VoiceComposer({
    super.key,
    required this.onSend,
    this.capture,
    this.player,
  });
  final Future<void> Function(Uint8List wav) onSend;
  final VoiceCapture? capture;
  final VoicePlayer? player;
  @override
  State<VoiceComposer> createState() => _VoiceComposerState();
}

class _VoiceComposerState extends State<VoiceComposer>
    with WidgetsBindingObserver {
  late final VoiceCapture capture;
  late final VoicePlayer player;
  bool _previewed = false, _sending = false, _previewLoading = false;
  int _generation = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    capture = widget.capture ?? VoiceCapture();
    player = widget.player ?? VoicePlayback();
    capture.addListener(_changed);
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
    _previewed = false;
    unawaited(player.stop().catchError((Object _) {}));
    unawaited(capture.cancel(message: '已离开录音窗口，录音已取消。需要时请重新录制。'));
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    capture.removeListener(_changed);
    player.removeListener(_changed);
    capture.dispose();
    player.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    final generation = ++_generation;
    setState(() {
      _previewed = false;
      _error = null;
    });
    try {
      await player.stop();
      if (mounted && generation == _generation) await capture.start();
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = context.tr(
            '无法准备录音，请重试',
            'Could not prepare recording. Try again.',
          ),
        );
      }
    }
  }

  Future<void> _preview() async {
    final wav = capture.wav;
    if (wav == null) return;
    final generation = _generation;
    setState(() {
      _previewLoading = true;
      _error = null;
    });
    try {
      if (player.isPlaying) {
        await player.stop();
      } else {
        await player.play(wav);
        if (mounted &&
            generation == _generation &&
            identical(capture.wav, wav)) {
          _previewed = true;
        }
      }
    } on VoiceCancelled {
      // Closing or switching away cancels playback as well as recording.
    } catch (_) {
      if (mounted) {
        _error = context.tr(
          '无法播放预览，请重试',
          'Could not play the preview. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _previewLoading = false);
    }
  }

  Future<void> _send() async {
    final wav = capture.wav;
    if (!_previewed || wav == null || _sending) return;
    final generation = _generation;
    // Own the processed copy while lifecycle cancellation clears the composer.
    final outgoing = Uint8List.fromList(wav);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await player.stop();
      if (!mounted ||
          generation != _generation ||
          !identical(capture.wav, wav)) {
        return;
      }
      await widget.onSend(outgoing);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = context.tr(
            '发送未完成，请检查网络后重试',
            'Not sent. Check your connection and try again.',
          ),
        );
      }
    } finally {
      outgoing.fillRange(0, outgoing.length, 0);
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final state = capture.state;
    final busy =
        state == VoiceCaptureState.starting ||
        state == VoiceCaptureState.processing ||
        _sending;
    final ready = state == VoiceCaptureState.ready && capture.wav != null;
    final rawError = _error ?? capture.error;
    final error = rawError == null ? null : context.appText(rawError);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr('变声语音', 'Voice with effects'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                context.tr(
                  '在本机改变音高与音色，保留语气。原声不上传；变声仍可能被声纹、说话方式或内容关联到你。',
                  'Pitch and timbre change on this device while your expression is kept. Original audio is not uploaded. Your voice, speech or words may still identify you.',
                ),
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              if (state == VoiceCaptureState.recording) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    context.tr(
                      '正在录音 ${(capture.recordedMs / 1000).toStringAsFixed(1)} / 30 秒',
                      'Recording ${(capture.recordedMs / 1000).toStringAsFixed(1)} / 30 sec',
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: capture.finish,
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(context.tr('停止并变声', 'Stop and apply effect')),
                ),
              ] else if (busy) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                Text(
                  _sending
                      ? context.tr('正在发送变声语音…', 'Sending voice…')
                      : state == VoiceCaptureState.starting
                      ? context.tr('正在准备麦克风…', 'Preparing microphone…')
                      : context.tr(
                          '正在本机变声，原声不会上传…',
                          'Applying effect locally. Original audio stays here…',
                        ),
                  textAlign: TextAlign.center,
                ),
              ] else if (ready) ...[
                Text(
                  context.tr(
                    '变声完成 · ${(voiceWavDurationMs(capture.wav!) / 1000).toStringAsFixed(1)} 秒',
                    'Effect ready · ${(voiceWavDurationMs(capture.wav!) / 1000).toStringAsFixed(1)} sec',
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _previewLoading ? null : _preview,
                  icon: Icon(
                    player.isPlaying
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                  ),
                  label: Text(
                    player.isPlaying
                        ? context.tr('停止试听', 'Stop preview')
                        : context.tr('试听变声语音', 'Preview voice'),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _previewed && !_previewLoading ? _send : null,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(context.tr('发送变声语音', 'Send voice')),
                ),
                if (!_previewed)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      context.tr(
                        '请先试听变声效果，再决定是否发送。',
                        'Preview the effect before deciding to send.',
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                TextButton(
                  onPressed: _record,
                  child: Text(context.tr('重新录制', 'Record again')),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: _record,
                  icon: const Icon(Icons.mic_none_rounded),
                  label: Text(
                    context.tr('开始录音（最长 30 秒）', 'Record (up to 30 seconds)'),
                  ),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(error, style: TextStyle(color: colors.error)),
                ),
              TextButton(
                onPressed: _sending ? null : () => Navigator.of(context).pop(),
                child: Text(context.tr('取消', 'Cancel')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
