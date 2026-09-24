import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag.dart';

/// Plays silent audio in a loop to keep the iOS app alive in background.
///
/// iOS suspends apps after ~30s in background unless they have an active
/// audio session. This service plays a short silent WAV on repeat so the
/// OS treats the app as an active audio player (same trick as WhatsApp,
/// Telegram, etc.).
///
/// On Android this is NOT needed — the foreground service (LanternService)
/// with a persistent notification handles keep-alive. This service only
/// activates on iOS when the user selects "Music Mode".
class BackgroundAudioService {
  BackgroundAudioService._();
  static final instance = BackgroundAudioService._();

  static const _channel = MethodChannel('com.lantern/audio');

  AudioPlayer? _player;
  bool _active = false;
  String _mode = 'keepAlive';
  Timer? _watchdog;

  bool get isActive => _active;
  String get mode => _mode;

  /// Read saved mode from prefs. Only starts audio on iOS + musicMode.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = prefs.getString('bgMode') ?? 'keepAlive';
    if (_mode == 'musicMode' && Platform.isIOS) {
      await start();
    }
  }

  /// Switch background mode. Starts/stops silent audio as needed.
  Future<void> setMode(String mode) async {
    _mode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bgMode', mode);
    if (mode == 'musicMode' && Platform.isIOS) {
      await start();
    } else {
      await stop();
    }
  }

  /// Start the silent audio loop.
  Future<void> start() async {
    if (_active) return;
    _active = true;
    DiagLog.add('audio', 'starting background audio keep-alive');

    try {
      // Configure iOS audio session for background playback
      if (Platform.isIOS) {
        try {
          await _channel.invokeMethod('enableBackgroundAudio');
        } catch (e) {
          DiagLog.add('audio', 'iOS audio session setup failed: $e');
          // Continue anyway — audioplayers may handle it
        }
      }

      await _createPlayer();
      _startWatchdog();
    } catch (e) {
      DiagLog.add('audio', 'start failed: $e');
      _active = false;
    }
  }

  /// Stop the silent audio loop.
  Future<void> stop() async {
    if (!_active && _player == null) return;
    _active = false;
    _watchdog?.cancel();
    _watchdog = null;
    DiagLog.add('audio', 'stopping background audio');

    try {
      await _player?.stop();
      await _player?.dispose();
    } catch (_) {}
    _player = null;

    // Deactivate iOS audio session
    if (Platform.isIOS) {
      try {
        await _channel.invokeMethod('disableBackgroundAudio');
      } catch (_) {}
    }
  }

  /// Dispose on app shutdown.
  Future<void> dispose() async {
    await stop();
  }

  /// Create and configure the audio player.
  Future<void> _createPlayer() async {
    _player?.dispose();
    _player = AudioPlayer();

    _player!.onPlayerStateChanged.listen((state) {
      if (_active && state == PlayerState.completed) {
        // Player finished — shouldn't happen with loop, but restart if it does
        DiagLog.add('audio', 'player completed unexpectedly, restarting');
        _restartPlayback();
      }
      if (_active && state == PlayerState.stopped) {
        // Unexpected stop — restart
        DiagLog.add('audio', 'player stopped unexpectedly, restarting');
        _restartPlayback();
      }
    });

    _player!.onLog.listen((msg) {
      if (msg.contains('error') || msg.contains('Error')) {
        DiagLog.add('audio', 'player error: $msg');
      }
    });

    // Set to loop and play the silent asset
    await _player!.setReleaseMode(ReleaseMode.loop);
    await _player!.setVolume(0.0);
    await _player!.play(AssetSource('audio/silence.wav'));
  }

  /// Restart playback (called when player dies unexpectedly).
  Future<void> _restartPlayback() async {
    if (!_active) return;
    try {
      await _player?.stop();
      await _player?.play(AssetSource('audio/silence.wav'));
    } catch (e) {
      DiagLog.add('audio', 'restart failed: $e');
      // Try recreating the player entirely
      try {
        await _createPlayer();
      } catch (_) {}
    }
  }

  /// Periodic watchdog: if the player isn't playing but should be, restart it.
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!_active) return;
      final state = _player?.state;
      if (state != PlayerState.playing) {
        DiagLog.add('audio', 'watchdog: player not playing (state=$state), restarting');
        await _restartPlayback();
      }
    });
  }
}
