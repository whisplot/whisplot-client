import 'dart:typed_data';

/// The wire format is deliberately one canonical, metadata-free WAV variant.
/// No original recording metadata, speaker tags or arbitrary file types travel
/// with transformed voice messages.
abstract final class MediaWav {
  static const sampleRate = 16000;
  static const maxDurationMs = 30000;
  static const maxEncryptedBytes = 1024 * 1024;

  static int durationMs(Uint8List bytes) {
    if (bytes.length < 46 || bytes.length + 16 > maxEncryptedBytes) {
      throw const FormatException('语音长度无效，变声语音最多 30 秒');
    }
    final b = ByteData.sublistView(bytes);
    bool tag(int at, String value) {
      for (var i = 0; i < value.length; i++) {
        if (bytes[at + i] != value.codeUnitAt(i)) return false;
      }
      return true;
    }

    final payloadLength = bytes.length - 44;
    if (!tag(0, 'RIFF') ||
        !tag(8, 'WAVE') ||
        !tag(12, 'fmt ') ||
        !tag(36, 'data') ||
        b.getUint32(4, Endian.little) != bytes.length - 8 ||
        b.getUint32(16, Endian.little) != 16 ||
        b.getUint16(20, Endian.little) != 1 ||
        b.getUint16(22, Endian.little) != 1 ||
        b.getUint32(24, Endian.little) != sampleRate ||
        b.getUint32(28, Endian.little) != sampleRate * 2 ||
        b.getUint16(32, Endian.little) != 2 ||
        b.getUint16(34, Endian.little) != 16 ||
        b.getUint32(40, Endian.little) != payloadLength ||
        payloadLength.isOdd) {
      throw const FormatException('语音不是受支持的音频格式');
    }
    final duration = (payloadLength * 1000 / (sampleRate * 2)).ceil();
    if (duration < 1 || duration > maxDurationMs) {
      throw const FormatException('变声语音超过 30 秒，请重新录制较短内容');
    }
    return duration;
  }
}
