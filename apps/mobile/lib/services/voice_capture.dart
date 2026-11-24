import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'voice_dsp.dart';
import 'voice_pcm.dart';

abstract interface class VoiceRecorder {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> cancel();
  Future<void> dispose();
}

/// The microphone stream stays in memory. No original WAV/file is created.
class DeviceVoiceRecorder implements VoiceRecorder {
  AudioRecorder? _recorder;
  VoicePcmNormalizer? _normalizer;
  FormatException? _formatError;
  int _take = 0;
  AudioRecorder get _device => _recorder ??= AudioRecorder();
  @override
  Future<bool> hasPermission() => _device.hasPermission();
  @override
  Future<Stream<Uint8List>> start() async {
    final take = ++_take;
    _normalizer?.clear();
    final normalizer = _normalizer = VoicePcmNormalizer();
    _formatError = null;
    await _device.setOnConfigChanged((config) {
      if (take != _take ||
          !identical(_normalizer, normalizer) ||
          _formatError != null) {
        return;
      }
      try {
        normalizer.configure(
          sampleRate: config.sampleRate,
          channels: config.numChannels,
          pcm16: config.encoder == AudioEncoder.pcm16bits,
        );
      } on FormatException catch (error) {
        _formatError = error;
        unawaited(_device.cancel().catchError((Object _) {}));
      }
    });
    try {
      final stream = await _device.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: voiceSampleRate,
          numChannels: 1,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
          audioInterruption: AudioInterruptionMode.pause,
          audioRouteChange: AudioRouteChangeMode.stop,
        ),
      );
      return _normalize(stream, normalizer, take);
    } catch (_) {
      normalizer.clear();
      if (identical(_normalizer, normalizer)) _normalizer = null;
      rethrow;
    }
  }

  Stream<Uint8List> _normalize(
    Stream<Uint8List> stream,
    VoicePcmNormalizer normalizer,
    int take,
  ) async* {
    try {
      await for (final chunk in stream) {
        if (take != _take) return;
        if (_formatError != null) throw _formatError!;
        final mono = normalizer.add(chunk);
        if (mono.isNotEmpty) {
          try {
            yield mono;
          } finally {
            mono.fillRange(0, mono.length, 0);
          }
        }
      }
      if (take != _take) return;
      if (_formatError != null) throw _formatError!;
      normalizer.finish();
    } finally {
      normalizer.clear();
      if (identical(_normalizer, normalizer)) _normalizer = null;
    }
  }

  @override
  Future<void> stop() async {
    await _recorder?.stop();
  }

  @override
  Future<void> cancel() async {
    _take++;
    _normalizer?.clear();
    _normalizer = null;
    await _recorder?.cancel();
  }

  @override
  Future<void> dispose() async {
    _take++;
    _normalizer?.clear();
    _normalizer = null;
    await _recorder?.dispose();
  }
}

class VoiceCancelled implements Exception {
  const VoiceCancelled();
}

abstract interface class VoiceProcessor {
  Future<Uint8List> process(Uint8List pcm);
  void cancel();
}

void _transformInIsolate(List<Object> request) {
  final port = request[0] as SendPort;
  final pcm = (request[1] as TransferableTypedData).materialize().asUint8List();
  try {
    final wav = transformVoicePcm(pcm, semitones: request[2] as double);
    port.send(TransferableTypedData.fromList([wav]));
    wav.fillRange(0, wav.length, 0);
  } catch (_) {
    port.send('变声处理失败，请重新录制');
  } finally {
    pcm.fillRange(0, pcm.length, 0);
  }
}

/// A cancellable worker: leaving the composer kills in-flight DSP work as well
/// as discarding the main-isolate raw buffer. Memory clearing is best effort,
/// not a guarantee against OS-level memory capture.
class LocalVoiceProcessor implements VoiceProcessor {
  Isolate? _worker;
  ReceivePort? _resultPort;
  Completer<Uint8List>? _pending;
  int _generation = 0;

  @override
  Future<Uint8List> process(Uint8List pcm) async {
    cancel();
    final generation = _generation;
    final pending = _pending = Completer<Uint8List>();
    final port = _resultPort = ReceivePort();
    final random = Random.secure();
    final semitones =
        (3 + random.nextDouble() * 2) * (random.nextBool() ? 1 : -1);
    final transfer = TransferableTypedData.fromList([pcm]);
    pcm.fillRange(0, pcm.length, 0);
    // Attach the result/error consumer before spawn can complete or cancel.
    final answer = pending.future;
    final subscription = port.listen((result) {
      if (pending.isCompleted) return;
      if (result is TransferableTypedData) {
        pending.complete(result.materialize().asUint8List());
      } else {
        pending.completeError(const FormatException('变声处理失败，请重新录制'));
      }
    });
    try {
      final spawn = Isolate.spawn<List<Object>>(
        _transformInIsolate,
        [port.sendPort, transfer, semitones],
        onError: port.sendPort,
        errorsAreFatal: true,
      );
      // Keep cancellation observable while an isolate is being created.
      unawaited(
        spawn.then(
          (worker) {
            if (generation != _generation) {
              worker.kill(priority: Isolate.immediate);
            } else {
              _worker = worker;
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!pending.isCompleted) pending.completeError(error, stack);
          },
        ),
      );
      return await answer;
    } finally {
      await subscription.cancel();
      port.close();
      if (identical(_pending, pending)) {
        _worker?.kill(priority: Isolate.immediate);
        _worker = null;
        _resultPort = null;
        _pending = null;
      }
    }
  }

  @override
  void cancel() {
    _generation++;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _resultPort?.close();
    _resultPort = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const VoiceCancelled());
    }
  }
}

enum VoiceCaptureState { idle, starting, recording, processing, ready }

/// No method in this class sends or stores original audio. Only [wav], populated
/// after successful DSP and format validation, is exposed to the composer.
class VoiceCapture extends ChangeNotifier {
  VoiceCapture({VoiceRecorder? recorder, VoiceProcessor? processor})
    : _recorder = recorder ?? DeviceVoiceRecorder(),
      _processor = processor ?? LocalVoiceProcessor();
  final VoiceRecorder _recorder;
  final VoiceProcessor _processor;
  VoiceCaptureState state = VoiceCaptureState.idle;
  String? error;
  Uint8List? wav;
  int recordedMs = 0;
  final _raw = Uint8List(voiceMaxPcmBytes);
  int _used = 0, _generation = 0;
  bool _disposed = false, _collecting = false;
  Timer? _limit;
  StreamSubscription<Uint8List>? _stream;
  Future<void> _cleaning = Future.value();
  Future<void> _nativeTail = Future.value();

  Future<T> _native<T>(Future<T> Function() action) {
    final result = _nativeTail.then((_) => action());
    _nativeTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _clearBuffers() {
    _raw.fillRange(0, _raw.length, 0);
    _used = 0;
    recordedMs = 0;
    wav?.fillRange(0, wav!.length, 0);
    wav = null;
  }

  Future<void> start() async {
    if (_disposed ||
        state == VoiceCaptureState.starting ||
        state == VoiceCaptureState.recording ||
        state == VoiceCaptureState.processing) {
      return;
    }
    final generation = ++_generation;
    await _cleaning;
    if (_disposed || generation != _generation) return;
    _clearBuffers();
    error = null;
    state = VoiceCaptureState.starting;
    _changed();
    try {
      if (!await _recorder.hasPermission()) {
        throw const FormatException('需要麦克风权限才能录制变声语音，可在系统设置中开启');
      }
      if (_disposed || generation != _generation) return;
      final stream = await _native(() async {
        if (_disposed || generation != _generation) {
          throw const VoiceCancelled();
        }
        return _recorder.start();
      });
      if (_disposed || generation != _generation) {
        // cancel() queued native cleanup behind this start. Do not issue an
        // extra cancellation here: it could otherwise stop a newer take.
        return;
      }
      state = VoiceCaptureState.recording;
      _collecting = true;
      _stream = stream.listen(
        (bytes) {
          if (generation != _generation || !_collecting) return;
          final count = min(bytes.length, _raw.length - _used);
          _raw.setRange(_used, _used + count, bytes);
          _used += count;
          recordedMs = _used * 1000 ~/ (voiceSampleRate * 2);
          _changed();
          if (_used == _raw.length) unawaited(finish());
        },
        onError: (Object error) {
          if (generation == _generation) {
            unawaited(
              cancel(
                message: error is FormatException
                    ? error.message
                    : '录音中断，请重新录制',
              ),
            );
          }
        },
        onDone: () {
          if (generation == _generation &&
              state == VoiceCaptureState.recording) {
            unawaited(cancel(message: '录音设备已停止，请重新录制'));
          }
        },
      );
      _limit = Timer(const Duration(seconds: 30), () => unawaited(finish()));
      _changed();
    } catch (e) {
      if (generation == _generation && !_disposed) {
        await cancel(
          message: e is FormatException ? e.message : '无法启动麦克风，请检查系统权限',
        );
      }
    }
  }

  Future<void> finish() async {
    if (_disposed || state != VoiceCaptureState.recording) return;
    final generation = _generation;
    _limit?.cancel();
    _limit = null;
    state = VoiceCaptureState.processing;
    _changed();
    try {
      await _native(_recorder.stop);
      if (_disposed || generation != _generation) return;
      _collecting = false;
      await _stream?.cancel();
      _stream = null;
      if (_disposed || generation != _generation) return;
      if (_used < 3200 || _used.isOdd) {
        throw const FormatException('录音太短，请至少说一句话后再停止');
      }
      final raw = Uint8List.fromList(Uint8List.sublistView(_raw, 0, _used));
      _raw.fillRange(0, _raw.length, 0);
      _used = 0;
      Uint8List processed;
      try {
        processed = await _processor.process(raw);
      } finally {
        raw.fillRange(0, raw.length, 0);
      }
      if (_disposed || generation != _generation) {
        processed.fillRange(0, processed.length, 0);
        return;
      }
      voiceWavDurationMs(processed);
      wav = processed;
      state = VoiceCaptureState.ready;
      _changed();
    } on VoiceCancelled {
      // Expected when the sheet closes or the app loses foreground focus.
    } catch (e) {
      if (!_disposed && generation == _generation) {
        await cancel(
          message: e is FormatException ? e.message : '变声处理失败，请重新录制',
        );
      }
    }
  }

  Future<void> cancel({String? message}) {
    _generation++;
    _limit?.cancel();
    _limit = null;
    _collecting = false;
    _processor.cancel();
    _clearBuffers();
    state = VoiceCaptureState.idle;
    error = message;
    final stream = _stream;
    _stream = null;
    final previous = _cleaning;
    _cleaning = () async {
      await previous;
      try {
        await _native(_recorder.cancel);
      } catch (_) {
        /* Already stopped. */
      }
      await stream?.cancel();
    }();
    _changed();
    return _cleaning;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(cancel().whenComplete(_recorder.dispose));
    super.dispose();
  }
}
