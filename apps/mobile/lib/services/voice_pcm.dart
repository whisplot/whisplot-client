import 'dart:typed_data';
import 'voice_dsp.dart';

/// Normalizes negotiated PCM16 microphone frames before duration accounting.
/// Native Android capture may negotiate stereo even when mono was requested.
/// Only the requested sample rate is accepted; a rate change is never relabelled.
class VoicePcmNormalizer {
  int _channels = 1;
  bool _received = false, _closed = false;
  final _carry = Uint8List(4);
  int _used = 0;

  void configure({
    required int sampleRate,
    required int channels,
    required bool pcm16,
  }) {
    if (_closed) throw StateError('PCM normalizer closed');
    if (!pcm16 ||
        sampleRate != voiceSampleRate ||
        (channels != 1 && channels != 2)) {
      clear();
      throw const FormatException('录音设备不支持 16 kHz 单声道或双声道 PCM16，请更换输入设备');
    }
    if (_received && channels != _channels) {
      clear();
      throw const FormatException('录音过程中输入格式发生变化，请重新录制');
    }
    _channels = channels;
  }

  Uint8List add(Uint8List input) {
    if (_closed) throw StateError('PCM normalizer closed');
    _received = _received || input.isNotEmpty;
    final frameBytes = _channels * 2;
    final output = Uint8List(((_used + input.length) ~/ frameBytes) * 2);
    final source = ByteData.sublistView(_carry);
    final destination = ByteData.sublistView(output);
    var position = 0, written = 0;
    while (position < input.length) {
      final remaining = frameBytes - _used;
      final count = remaining < input.length - position
          ? remaining
          : input.length - position;
      _carry.setRange(_used, _used + count, input, position);
      _used += count;
      position += count;
      if (_used == frameBytes) {
        final left = source.getInt16(0, Endian.little);
        final mono = _channels == 1
            ? left
            : ((left + source.getInt16(2, Endian.little)) / 2).round();
        destination.setInt16(written, mono.clamp(-32768, 32767), Endian.little);
        written += 2;
        _carry.fillRange(0, _carry.length, 0);
        _used = 0;
      }
    }
    return output;
  }

  void finish() {
    final partial = _used != 0;
    clear();
    if (partial) throw const FormatException('录音数据不完整，请重新录制');
  }

  void clear() {
    _carry.fillRange(0, _carry.length, 0);
    _used = 0;
    _closed = true;
  }
}
