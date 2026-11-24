import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/voice_pcm.dart';

Uint8List pcm(List<int> values) {
  final bytes = Uint8List(values.length * 2),
      view = ByteData(values.length * 2);
  for (var i = 0; i < values.length; i++) {
    view.setInt16(i * 2, values[i], Endian.little);
  }
  bytes.setAll(0, view.buffer.asUint8List());
  return bytes;
}

List<int> values(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  return List.generate(
    bytes.length ~/ 2,
    (i) => view.getInt16(i * 2, Endian.little),
  );
}

void main() {
  test(
    'negotiated stereo is averaged at unchanged sample rate and duration',
    () {
      final converter = VoicePcmNormalizer()
        ..configure(sampleRate: 16000, channels: 2, pcm16: true);
      final source = pcm([
        -32768,
        -32768,
        32767,
        32767,
        20000,
        -20000,
        10000,
        30000,
      ]);
      final output = converter.add(source);
      expect(values(output), [-32768, 32767, 0, 20000]);
      expect(output.length, source.length ~/ 2);
      expect(
        values(source).first,
        -32768,
      ); // Borrowed platform buffer is untouched.
      converter.finish();
    },
  );

  test('stereo frames split at every byte boundary preserve alignment', () {
    final source = pcm([1000, 3000, -1000, -3000, 32767, -32768, 0, 4000]);
    for (var width = 1; width <= 9; width++) {
      final converter = VoicePcmNormalizer()
        ..configure(sampleRate: 16000, channels: 2, pcm16: true);
      final joined = BytesBuilder();
      for (var i = 0; i < source.length; i += width) {
        final end = i + width < source.length ? i + width : source.length;
        joined.add(converter.add(Uint8List.sublistView(source, i, end)));
      }
      converter.finish();
      expect(values(joined.takeBytes()), [
        2000,
        -2000,
        -1,
        2000,
      ], reason: 'chunk width $width');
    }
  });

  test('mono remains byte-exact even with odd chunk boundaries', () {
    final converter = VoicePcmNormalizer();
    final source = pcm([-32768, -1, 0, 1, 32767]), joined = BytesBuilder();
    for (final byte in source) {
      joined.add(converter.add(Uint8List.fromList([byte])));
    }
    converter.finish();
    expect(joined.takeBytes(), orderedEquals(source));
  });

  test(
    'unsupported rate, channel count, or codec cannot be relabelled mono',
    () {
      for (final config in [
        (44100, 2, true),
        (48000, 1, true),
        (16000, 3, true),
        (16000, 1, false),
      ]) {
        final converter = VoicePcmNormalizer();
        expect(
          () => converter.configure(
            sampleRate: config.$1,
            channels: config.$2,
            pcm16: config.$3,
          ),
          throwsFormatException,
        );
        expect(() => converter.add(pcm([1, 1])), throwsStateError);
      }
    },
  );

  test('mid-take format change and incomplete frame fail closed', () {
    final converter = VoicePcmNormalizer();
    converter.add(pcm([100]));
    expect(
      () => converter.configure(sampleRate: 16000, channels: 2, pcm16: true),
      throwsFormatException,
    );
    final partial = VoicePcmNormalizer()
      ..configure(sampleRate: 16000, channels: 2, pcm16: true);
    expect(partial.add(Uint8List.fromList([1, 2, 3])), isEmpty);
    expect(partial.finish, throwsFormatException);
    expect(() => partial.add(Uint8List.fromList([4])), throwsStateError);
  });

  test('cancel discards carry; a new take starts on a fresh frame', () {
    final old = VoicePcmNormalizer()
      ..configure(sampleRate: 16000, channels: 2, pcm16: true);
    old.add(Uint8List.fromList([255, 127, 255]));
    old.clear();
    expect(() => old.add(Uint8List.fromList([127])), throwsStateError);
    final next = VoicePcmNormalizer()
      ..configure(sampleRate: 16000, channels: 2, pcm16: true);
    expect(values(next.add(pcm([1000, 3000]))), [2000]);
    next.finish();
  });
}
