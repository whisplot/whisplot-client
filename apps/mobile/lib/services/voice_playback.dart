import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'voice_capture.dart';
import 'voice_dsp.dart';

abstract class VoicePlayer extends ChangeNotifier {
  bool get isPlaying;
  Future<void> play(Uint8List wav);
  Future<void> stop();
}

/// Only transformed/decrypted voice enters this player. The temporary playback
/// file is removed when playback stops, finishes, or the widget is disposed.
class VoicePlayback extends VoicePlayer {
  static VoicePlayback? _current;
  static Future<void>? _startupCleanup;
  static final _activeDirectories = <String>{};

  /// Invoke after Flutter plugin initialization at app startup. Playback also
  /// awaits this cleanup, so a failed startup attempt can be retried safely.
  static Future<void> cleanupAbandonedFiles() {
    return _startupCleanup ??=
        (() async {
          final cache = await getTemporaryDirectory();
          await _removeAbandonedPlayback(cache);
        })().catchError((Object error, StackTrace stack) {
          _startupCleanup = null;
          Error.throwWithStackTrace(error, stack);
        });
  }

  AudioPlayer? _player;
  Directory? _directory;
  StreamSubscription<void>? _completion;
  bool _playing = false, _disposed = false;
  int _generation = 0;
  Future<void> _tail = Future.value();
  @override
  bool get isPlaying => _playing;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _clean() async {
    try {
      await _player?.stop();
    } finally {
      _playing = false;
      final directory = _directory;
      _directory = null;
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      if (directory != null) _activeDirectories.remove(directory.path);
      _changed();
    }
  }

  @override
  Future<void> play(Uint8List wav) {
    voiceWavDurationMs(wav);
    final generation = ++_generation;
    final previous = _current;
    final previousStopped = previous != null && previous != this
        ? previous.stop()
        : Future<void>.value();
    _current = this;
    return _serialize(() async {
      await previousStopped;
      await _clean();
      if (_disposed || generation != _generation || _current != this) {
        throw const VoiceCancelled();
      }
      final player = _player ??= AudioPlayer();
      _completion ??= player.onPlayerComplete.listen((_) {
        unawaited(stop().catchError((Object _) {}));
      });
      try {
        final cache = await getTemporaryDirectory();
        await cleanupAbandonedFiles();
        // The OS may also purge this cache after startup cleanup completed.
        await cache.create(recursive: true);
        if (_disposed || generation != _generation || _current != this) {
          throw const VoiceCancelled();
        }
        final directory = _directory = await cache.createTemp(
          'nearlink-voice-',
        );
        _activeDirectories.add(directory.path);
        final file = File('${directory.path}/changed.wav');
        await file.writeAsBytes(wav, flush: true);
        if (_disposed || generation != _generation || _current != this) {
          throw const VoiceCancelled();
        }
        await player.setReleaseMode(ReleaseMode.release);
        if (_disposed || generation != _generation || _current != this) {
          throw const VoiceCancelled();
        }
        await player.play(DeviceFileSource(file.path, mimeType: 'audio/wav'));
        if (_disposed || generation != _generation || _current != this) {
          throw const VoiceCancelled();
        }
        _playing = true;
        _changed();
      } catch (_) {
        await _clean();
        rethrow;
      }
    });
  }

  @override
  Future<void> stop() {
    _generation++;
    if (_current == this) _current = null;
    return _serialize(_clean);
  }

  static Future<void> _removeAbandonedPlayback(Directory cache) async {
    // path_provider may return a not-yet-created path on a fresh sandbox.
    await cache.create(recursive: true);
    await for (final entry in cache.list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('nearlink-voice-') &&
          !_activeDirectories.contains(entry.path) &&
          await FileSystemEntity.type(entry.path, followLinks: false) ==
              FileSystemEntityType.directory) {
        await Directory(entry.path).delete(recursive: true);
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(
      stop()
          .whenComplete(() async {
            await _completion?.cancel();
            await _player?.dispose();
          })
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}
