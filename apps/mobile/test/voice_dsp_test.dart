import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/voice_capture.dart';
import 'package:nearlink/services/voice_dsp.dart';
import 'package:nearlink/services/media_wav.dart';

Float32List tone(double frequency, {int rate = 16000, int seconds = 2}) =>
    Float32List.fromList(
      List.generate(
        rate * seconds,
        (i) => 0.5 * math.sin(2 * math.pi * frequency * i / rate),
      ),
    );

double frequency(Float32List signal, int rate) {
  final start = rate ~/ 5, end = signal.length - rate ~/ 5;
  var crossings = 0;
  for (var i = start + 1; i < end; i++) {
    if (signal[i - 1] < 0 && signal[i] >= 0) crossings++;
  }
  return crossings * rate / (end - start);
}

double rms(Float32List signal) {
  var sum = 0.0;
  for (var i = 100; i < signal.length - 100; i++) {
    sum += signal[i] * signal[i];
  }
  return math.sqrt(sum / (signal.length - 200));
}

void main() {
  test('canonical WAV has exact duration, PCM format and maximum size', () {
    final wav = encodeVoiceWav(Float32List(voiceMaxSamples));
    expect(wav.length, 960044);
    expect(voiceWavDurationMs(wav), 30000);
    final wrongRate = Uint8List.fromList(wav);
    ByteData.sublistView(wrongRate).setUint32(24, 44100, Endian.little);
    expect(() => voiceWavDurationMs(wrongRate), throwsFormatException);
    expect(
      () => voiceWavDurationMs(Uint8List.fromList([...wav, 0, 0])),
      throwsFormatException,
    );
    expect(
      () => encodeVoiceWav(Float32List(voiceMaxSamples + 1)),
      throwsFormatException,
    );
    expect(
      () => encodeVoiceWav(Float32List.fromList([double.nan])),
      throwsFormatException,
    );
  });

  test('fractional milliseconds agree with encrypted attachment metadata', () {
    for (final length in [1, 17, 16001, voiceMaxSamples - 1, voiceMaxSamples]) {
      final wav = encodeVoiceWav(Float32List(length));
      expect(voiceWavDurationMs(wav), MediaWav.durationMs(wav));
      expect(voiceWavDurationMs(wav), greaterThanOrEqualTo(1));
      expect(voiceWavDurationMs(wav), lessThanOrEqualTo(30000));
    }
  });

  test('band-limited downsampling preserves speech band and rejects alias', () {
    final low = resampleVoice(tone(1000, rate: 48000), 3, 32000);
    final high = resampleVoice(tone(12000, rate: 48000), 3, 32000);
    expect(frequency(low, 16000), closeTo(1000, 1));
    expect(rms(low), greaterThan(0.3));
    expect(rms(high) / rms(low), lessThan(0.01));
  });

  for (final shift in [-5.0, -3.0, 3.0, 5.0]) {
    test('pitch shift $shift changes pitch while keeping duration', () {
      final original = encodeVoiceWav(tone(220));
      final pcm = Uint8List.sublistView(original, 44);
      final wav = transformVoicePcm(pcm, semitones: shift);
      expect(wav.length, original.length);
      expect(voiceWavDurationMs(wav), 2000);
      final output = decodeVoicePcm(Uint8List.sublistView(wav, 44));
      expect(
        frequency(output, 16000),
        closeTo(220 * math.pow(2, shift / 12), 3),
      );
      expect(rms(output), greaterThan(0.15));
      expect(wav, isNot(orderedEquals(original)));
      expect(
        output.every((sample) => sample.isFinite && sample.abs() <= 0.951),
        isTrue,
      );
    });
  }

  test('zero shift, malformed or oversized input never returns original', () {
    final pcm = Uint8List(3200);
    expect(() => transformVoicePcm(pcm, semitones: 0), throwsArgumentError);
    expect(
      () => transformVoicePcm(Uint8List(3), semitones: 4),
      throwsFormatException,
    );
    expect(
      () => transformVoicePcm(Uint8List(voiceMaxPcmBytes + 2), semitones: 4),
      throwsFormatException,
    );
    expect(
      () => transformVoicePcm(Uint8List(100), semitones: 4),
      throwsFormatException,
    );
  });

  test(
    'real isolate consumes raw buffer and returns changed canonical audio',
    () async {
      final original = encodeVoiceWav(tone(220));
      final raw = Uint8List.fromList(original.sublist(44));
      final processor = LocalVoiceProcessor();
      final wav = await processor.process(raw);
      expect(raw.every((value) => value == 0), isTrue);
      expect(voiceWavDurationMs(wav), 2000);
      expect(wav, isNot(orderedEquals(original)));
      processor.cancel();
    },
  );
}
