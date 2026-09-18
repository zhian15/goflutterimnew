import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';

/// 全局语音播放状态，气泡据此高亮进度条 / 切换播放-暂停图标。
class VoicePlaybackState {
  final String? msgId; // 正在播放的消息 id（null = 空闲）
  final int positionMs;
  final int durationMs;
  final bool playing;

  const VoicePlaybackState({
    this.msgId,
    this.positionMs = 0,
    this.durationMs = 0,
    this.playing = false,
  });
}

/// 语音播放服务（单例）：同一时刻只播一条；点击正在播放的同一条则停止。
///
/// 原生播放 .m4a（aacMp4）与 .webm（opusWebM，H5 录制）均走平台媒体引擎；
/// H5 录制件在原生端若解码失败，[toggle] 会捕获异常并复位（气泡回到待播态）。
class VoicePlayerService {
  VoicePlayerService._();
  static final instance = VoicePlayerService._();

  final FlutterSoundPlayer _player = FlutterSoundPlayer();
  bool _open = false;
  String? _curMsgId;
  StreamSubscription<PlaybackDisposition>? _progressSub;

  /// 当前播放状态（气泡订阅）。
  final ValueNotifier<VoicePlaybackState> state =
      ValueNotifier(const VoicePlaybackState());

  Future<void> _ensureOpen() async {
    if (_open) return;
    await _player.openPlayer();
    // 进度回调走 onProgress 流（startPlayer 没有 onProgress 命名参数），
    // 必须先 setSubscriptionDuration 才发事件；该流是单订阅流，整个生命周期只监听一次。
    await _player.setSubscriptionDuration(const Duration(milliseconds: 100));
    _progressSub = _player.onProgress?.listen(_onProgress);
    _open = true;
  }

  void _onProgress(PlaybackDisposition d) {
    if (_curMsgId == null) return;
    state.value = VoicePlaybackState(
      msgId: _curMsgId,
      playing: true,
      durationMs: d.duration.inMilliseconds,
      positionMs: d.position.inMilliseconds,
    );
  }

  /// 点击气泡：同一 msgId 正在播 → 停止；否则切到该条从头播。
  Future<void> toggle(String url, String msgId) async {
    await _ensureOpen();
    if (_player.isPlaying && _curMsgId == msgId) {
      await _stop();
      return;
    }
    if (_player.isPlaying) {
      try {
        await _player.stopPlayer();
      } catch (_) {}
    }
    _curMsgId = msgId;
    state.value = VoicePlaybackState(msgId: msgId, playing: true, positionMs: 0);
    try {
      await _player.startPlayer(
        fromURI: url,
        whenFinished: () => _reset(),
      );
    } catch (_) {
      // 解码失败（如原生端播放 H5 录制的 webm/opus）：复位，气泡回到待播。
      _reset();
    }
  }

  Future<void> _stop() async {
    try {
      if (_player.isPlaying) await _player.stopPlayer();
    } catch (_) {}
    _reset();
  }

  void _reset() {
    _curMsgId = null;
    state.value = const VoicePlaybackState();
  }

  Future<void> dispose() async {
    await _progressSub?.cancel();
    _progressSub = null;
    try {
      if (_player.isPlaying) await _player.stopPlayer();
    } catch (_) {}
    if (_open) {
      try {
        await _player.closePlayer();
      } catch (_) {}
      _open = false;
    }
  }
}
