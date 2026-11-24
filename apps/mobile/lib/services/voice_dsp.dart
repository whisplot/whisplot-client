import 'dart:math' as math;
import 'dart:typed_data';

/// Local voice effects, not speaker anonymization. Speech rhythm and content
/// remain identifiable. No learned model or reference speaker is used.
const voiceSampleRate = 16000;
const voiceMaxSamples = voiceSampleRate * 30;
const voiceMaxPcmBytes = voiceMaxSamples * 2;

Float32List decodeVoicePcm(Uint8List pcm) {
  if (pcm.isEmpty || pcm.length.isOdd || pcm.length > voiceMaxPcmBytes) {
    throw const FormatException('录音必须是最长 30 秒的单声道 PCM16 音频');
  }
  final bytes = ByteData.sublistView(pcm);
  final samples = Float32List(pcm.length ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = bytes.getInt16(i * 2, Endian.little) / 32768;
  }
  return samples;
}

Uint8List encodeVoiceWav(Float32List samples) {
  if (samples.isEmpty || samples.length > voiceMaxSamples) {
    throw const FormatException('语音不能超过 30 秒，请重新录制');
  }
  final bytes = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, voiceSampleRate, Endian.little);
  data.setUint32(28, voiceSampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final sample = samples[i];
    if (!sample.isFinite) throw const FormatException('无效音频样本');
    data.setInt16(
      44 + i * 2,
      (sample.clamp(-1, 1) * 32767).round(),
      Endian.little,
    );
  }
  return bytes;
}

/// Strict canonical WAV validation before local preview/playback.
int voiceWavDurationMs(Uint8List wav) {
  if (wav.length < 46 ||
      wav.length > 44 + voiceMaxPcmBytes ||
      wav.length.isOdd) {
    throw const FormatException('无效的变声语音');
  }
  final b = ByteData.sublistView(wav);
  String tag(int at) => String.fromCharCodes(wav.sublist(at, at + 4));
  if (tag(0) != 'RIFF' ||
      tag(8) != 'WAVE' ||
      tag(12) != 'fmt ' ||
      tag(36) != 'data' ||
      b.getUint32(4, Endian.little) != wav.length - 8 ||
      b.getUint32(16, Endian.little) != 16 ||
      b.getUint16(20, Endian.little) != 1 ||
      b.getUint16(22, Endian.little) != 1 ||
      b.getUint32(24, Endian.little) != voiceSampleRate ||
      b.getUint32(28, Endian.little) != voiceSampleRate * 2 ||
      b.getUint16(32, Endian.little) != 2 ||
      b.getUint16(34, Endian.little) != 16 ||
      b.getUint32(40, Endian.little) != wav.length - 44) {
    throw const FormatException('无效的变声语音');
  }
  return ((wav.length - 44) * 1000 / (voiceSampleRate * 2)).ceil();
}

/// 64-tap Blackman-windowed sinc interpolation with a Nyquist low-pass.
/// Both rate conversion and pitch transposition use this anti-alias filter.
Float32List resampleVoice(Float32List input, double step, int length) {
  if (input.isEmpty ||
      !step.isFinite ||
      step <= 0 ||
      length <= 0 ||
      length > voiceMaxSamples * 2) {
    throw ArgumentError('Invalid resampling dimensions');
  }
  const taps = 64, phases = 256, half = taps ~/ 2;
  final cutoff = 0.45 / math.max(1, step);
  final table = List<Float64List>.generate(phases, (phase) {
    final coefficients = Float64List(taps);
    var sum = 0.0;
    for (var tap = 0; tap < taps; tap++) {
      final distance = tap - half + 1 - phase / phases;
      final window =
          0.42 +
          0.5 * math.cos(math.pi * distance / half) +
          0.08 * math.cos(2 * math.pi * distance / half);
      final sinc = distance.abs() < 1e-9
          ? 2 * cutoff
          : math.sin(2 * math.pi * cutoff * distance) / (math.pi * distance);
      coefficients[tap] = sinc * window;
      sum += coefficients[tap];
    }
    for (var tap = 0; tap < taps; tap++) {
      coefficients[tap] /= sum;
    }
    return coefficients;
  });
  final output = Float32List(length);
  for (var i = 0; i < length; i++) {
    final position = i * step;
    final base = position.floor();
    final weights =
        table[((position - base) * phases).floor().clamp(0, phases - 1)];
    var sample = 0.0;
    for (var tap = 0; tap < taps; tap++) {
      final source = (base + tap - half + 1).clamp(0, input.length - 1);
      sample += input[source] * weights[tap];
    }
    output[i] = sample;
  }
  return output;
}

/// Waveform-similarity overlap-add, implemented from the algorithm, not copied
/// from a third-party library. See Roelands & Verhelst, Eurospeech 1993, 337–340:
/// https://www.isca-archive.org/eurospeech_1993/roelands93_eurospeech.html
Float32List _stretch(Float32List input, double factor) {
  const hop = 320, window = hop * 2, search = 128;
  final length = (input.length * factor).round();
  final output = Float32List(length + window);
  final first = math.min(window, input.length);
  output.setRange(0, first, input);
  for (var out = hop; out < length; out += hop) {
    final expected = (out / factor).round();
    var best = expected.clamp(0, math.max(0, input.length - window)).toInt();
    var bestScore = -double.infinity;
    final low = math.max(0, expected - search);
    final high = math.min(input.length - window, expected + search);
    for (var candidate = low; candidate <= high; candidate += 2) {
      var correlation = 0.0, energy = 1e-12;
      for (var i = 0; i < hop; i += 4) {
        final value = input[candidate + i];
        correlation += output[out + i] * value;
        energy += value * value;
      }
      // Small tie-breaker prevents silence/periodic signals from drifting.
      final score =
          correlation / math.sqrt(energy) - (candidate - expected).abs() * 1e-8;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    for (var i = 0; i < window && out + i < output.length; i++) {
      final source = best + i;
      final value = source < input.length ? input[source] : 0.0;
      if (i < hop) {
        final mix = 0.5 - 0.5 * math.cos(math.pi * i / hop);
        output[out + i] = output[out + i] * (1 - mix) + value * mix;
      } else {
        output[out + i] = value;
      }
    }
  }
  output.fillRange(length, output.length, 0);
  return Float32List.sublistView(output, 0, length);
}

/// Keeps duration and local prosody while shifting pitch AND spectral envelope.
/// This is a voice effect; it does not defeat speaker recognition.
Uint8List transformVoicePcm(Uint8List pcm, {required double semitones}) {
  if (!semitones.isFinite || semitones.abs() < 3 || semitones.abs() > 5) {
    throw ArgumentError('Voice pitch shift must be between 3 and 5 semitones');
  }
  final input = decodeVoicePcm(pcm);
  Float32List? stretched, output;
  try {
    if (input.length < 1600) throw const FormatException('录音太短，请重新录制');
    final factor = math.pow(2, semitones / 12).toDouble();
    stretched = _stretch(input, factor);
    output = resampleVoice(stretched, factor, input.length);
    // DC/rumble removal + mild low-pass; never amplify a quiet recording.
    final hp = math.exp(-2 * math.pi * 90 / voiceSampleRate);
    final lp = 1 - math.exp(-2 * math.pi * 5800 / voiceSampleRate);
    var previous = 0.0, high = 0.0, low = 0.0, peak = 0.0;
    for (var i = 0; i < output.length; i++) {
      final sample = output[i];
      high = hp * (high + sample - previous);
      previous = sample;
      low += lp * (high - low);
      final edge = math.min(1.0, math.min(i, output.length - i - 1) / 80);
      output[i] = low * edge;
      peak = math.max(peak, output[i].abs());
    }
    if (peak > 0.95) {
      final gain = 0.95 / peak;
      for (var i = 0; i < output.length; i++) {
        output[i] *= gain;
      }
    }
    return encodeVoiceWav(output);
  } finally {
    input.fillRange(0, input.length, 0);
    stretched?.fillRange(0, stretched.length, 0);
    output?.fillRange(0, output.length, 0);
  }
}
