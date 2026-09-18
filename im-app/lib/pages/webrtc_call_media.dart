import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_media.dart';
import 'webrtc_web_audio.dart';

/// WebRTC 媒体引擎（开源方案，后台 call_engine=webrtc 时启用）。
///
/// - 1v1：P2P 直连（STUN 打洞 + TURN 中继兜底）；
/// - 群组：Mesh 全互连 —— 每对成员一条 PeerConnection，上限 4-6 人；
/// - 协商规则：收到 join(X) → 我向 X 发 offer（已建连则忽略）。
///   两名新成员同时加入会双向 offer（glare），按「userId 较小者让步转应答」消解，
///   两端判定一致，不会死锁。
/// - 信令：sdp/ice/leave 经 CallService 以 type=7 透传（服务端零逻辑）。
class WebRtcCallMedia implements CallMedia {
  WebRtcCallMedia({required this.iceServers});

  /// 后台下发的 STUN/TURN 列表（webrtc_ice_servers）
  final List<Map<String, dynamic>> iceServers;

  @override
  void Function(String userId)? onRemoteJoined;
  @override
  void Function(String userId)? onRemoteLeft;
  @override
  void Function(Map<String, dynamic> sig)? onSignalOut;

  MediaStream? _local;
  final Map<String, RTCPeerConnection> _pcs = {};
  final Map<String, MediaStream> _remotes = {};

  /// 对端未就绪时先缓存的 ICE 候选（setRemoteDescription 后统一应用）
  final Map<String, List<RTCIceCandidate>> _pendingIce = {};

  /// 已向对方发出 offer、尚等 answer（glare 判定用）
  final Set<String> _offerPending = {};

  /// 媒体未就绪（getUserMedia/权限中）时收到的信令缓存，join 完成后重放。
  /// 2026-09-17 视频通话「只看到自己画面」根因之一：被叫广播 join 早于主叫
  /// 本地媒体就绪，旧代码在 peerJoined 里直接丢弃 → 主叫永不发 offer。
  final List<Map<String, dynamic>> _earlySigs = [];

  /// _remotes 变化计数（远端视图监听它重绑流，防流晚于视图到达时黑屏）
  final ValueNotifier<int> remoteRevision = ValueNotifier(0);

  /// 本地流就绪通知（本地预览小窗监听）
  final ValueNotifier<MediaStream?> localStreamNotifier = ValueNotifier(null);

  String _myId = '';
  bool _video = false;
  bool _joined = false;

  @override
  bool get isReal => true;

  @override
  Future<String?> join({
    required String roomId,
    required String myId,
    required bool isVideo,
    Map<String, dynamic>? trtcSig,
  }) async {
    _myId = myId;
    _video = isVideo;
    try {
      _local = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': isVideo ? {'facingMode': 'user'} : false,
      });
    } catch (e) {
      // 采集整体失败（视频+音频一起请求时拒绝任一都会整体拒绝）→ 拆开降级：
      // 只采音频保住通话（仅接收对方画面 + 头像占位），音频也失败才真正报错
      try {
        _local = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
      } catch (e2) {
        _earlySigs.clear();
        return '采集麦克风/摄像头失败: $e2';
      }
    }
    localStreamNotifier.value = _local;
    _joined = true;
    // 重放媒体就绪前缓存的信令（join → 发 offer；sdp/ice → 正常协商）
    if (_earlySigs.isNotEmpty) {
      final early = List<Map<String, dynamic>>.of(_earlySigs);
      _earlySigs.clear();
      for (final sig in early) {
        _dispatchSig(sig);
      }
    }
    return null;
  }

  @override
  Future<void> leave() async {
    _joined = false;
    for (final pc in _pcs.values) {
      try {
        await pc.close();
      } catch (_) {}
    }
    _pcs.clear();
    _offerPending.clear();
    _pendingIce.clear();
    _earlySigs.clear();
    WebRtcWebAudio.detachAll();
    for (final s in _remotes.values) {
      try {
        await s.dispose();
      } catch (_) {}
    }
    _remotes.clear();
    remoteRevision.value++;
    try {
      await _local?.dispose();
    } catch (_) {}
    _local = null;
    localStreamNotifier.value = null;
  }

  @override
  Future<void> setMuted(bool muted) async {
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  @override
  Future<void> setCameraOn(bool on) async {
    for (final t in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = on;
    }
  }

  @override
  Future<void> switchCamera() async {
    try {
      final video = _local?.getVideoTracks().isNotEmpty == true
          ? _local!.getVideoTracks().first
          : null;
      if (video != null) await Helper.switchCamera(video);
    } catch (_) {}
  }

  @override
  Widget localVideo() => _WebRtcVideoView(
      // key 必须区分：大小窗互换时同类型 Widget 无 key 会被 Flutter 复用旧 State，
      // 渲染器不重绑导致小窗画面卡住（2026-09-17 实测）
      key: const ValueKey('webrtc-local'),
      streamNotifier: localStreamNotifier,
      mirror: true);

  @override
  Widget remoteVideo(String userId) => _WebRtcVideoView(
      key: ValueKey('webrtc-remote-$userId'), userId: userId, media: this);

  // ============================ 信令入口 ============================

  @override
  void onSignalIn(Map<String, dynamic> sig) {
    if (!_joined) {
      // 本地媒体未就绪：先缓存，join() 完成后重放（不再静默丢弃）
      _earlySigs.add(sig);
      return;
    }
    _dispatchSig(sig);
  }

  void _dispatchSig(Map<String, dynamic> sig) {
    switch (sig['action']?.toString()) {
      case 'sdp':
        _onSdp(sig);
        break;
      case 'ice':
        _onIce(sig);
        break;
      case 'join':
        // 对端媒体就绪 → 主动向其发 offer（CallService 转发单聊/群通话 join）
        peerJoined(
          sig['userId']?.toString() ?? sig['from']?.toString() ?? '',
          (sig['ts'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'leave':
        final uid = sig['userId']?.toString() ?? sig['from']?.toString() ?? '';
        if (uid.isNotEmpty) peerLeft(uid);
        break;
    }
  }

  @override
  void peerJoined(String userId, int joinTs) {
    if (!_joined || userId == _myId) return;
    if (_pcs.containsKey(userId) || _offerPending.contains(userId)) return;
    _offerTo(userId);
  }

  @override
  void peerLeft(String userId) async {
    _offerPending.remove(userId);
    _pendingIce.remove(userId);
    WebRtcWebAudio.detach(userId);
    final stream = _remotes.remove(userId);
    if (stream != null) remoteRevision.value++;
    try {
      await stream?.dispose();
    } catch (_) {}
    final pc = _pcs.remove(userId);
    try {
      await pc?.close();
    } catch (_) {}
    onRemoteLeft?.call(userId);
  }

  // ============================ 内部 ============================

  Future<RTCPeerConnection> _ensurePc(String peerId) async {
    final existing = _pcs[peerId];
    if (existing != null) return existing;
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pcs[peerId] = pc;
    // 本地轨道加入连接
    final local = _local;
    if (local != null) {
      for (final track in local.getTracks()) {
        await pc.addTrack(track, local);
      }
    }
    pc.onTrack = (event) {
      if (event.streams.isEmpty) return;
      final stream = event.streams.first;
      if (!_remotes.containsKey(peerId)) {
        _remotes[peerId] = stream;
        remoteRevision.value++;
        // Web 端语音通话：远端音频必须有 HTML 媒体元素承载才会出声
        //（原生端 SDK 自动播放）。视频通话远端视频元素已播音频，这里
        // 只在语音（!_video）挂载，避免双重出声（2026-09-17 H5 无声修复）。
        if (kIsWeb && !_video) {
          WebRtcWebAudio.attach(peerId, stream);
        }
        onRemoteJoined?.call(peerId);
      }
    };
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      onSignalOut?.call({
        'action': 'ice',
        'to': peerId,
        'candidate': {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        },
      });
    };
    // 连接失败兜底：视为对方离开（网络崩溃等极端情况）
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        peerLeft(peerId);
      }
    };
    return pc;
  }

  Future<void> _offerTo(String peerId) async {
    if (!_joined ||
        _pcs.containsKey(peerId) ||
        _offerPending.contains(peerId)) {
      return;
    }
    _offerPending.add(peerId);
    try {
      final pc = await _ensurePc(peerId);
      final offer = await pc.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': _video,
      });
      await pc.setLocalDescription(offer);
      onSignalOut?.call({
        'action': 'sdp',
        'to': peerId,
        'kind': 'offer',
        'sdp': offer.sdp,
      });
    } catch (e) {
      _offerPending.remove(peerId);
    }
  }

  Future<void> _onSdp(Map<String, dynamic> sig) async {
    if (!_joined) return;
    final from = sig['from']?.toString() ?? '';
    final kind = sig['kind']?.toString() ?? '';
    final sdp = sig['sdp']?.toString() ?? '';
    if (from.isEmpty || from == _myId || sdp.isEmpty) return;

    if (kind == 'offer') {
      // glare：我已向对方发过 offer 且未收到 answer。
      // 规则：userId 较小者让步（重建为应答方），较大者坚持 —— 两端判定一致。
      if (_offerPending.contains(from)) {
        if (_myId.compareTo(from) < 0) {
          _offerPending.remove(from);
          await _closePeer(from);
        } else {
          return; // 我坚持当 offerer，等对方让步
        }
      }
      final pc = await _ensurePc(from);
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      await _drainPendingIce(from);
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': _video,
      });
      await pc.setLocalDescription(answer);
      onSignalOut?.call({
        'action': 'sdp',
        'to': from,
        'kind': 'answer',
        'sdp': answer.sdp,
      });
    } else if (kind == 'answer') {
      final pc = _pcs[from];
      if (pc == null) return;
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _offerPending.remove(from);
      await _drainPendingIce(from);
    }
  }

  Future<void> _onIce(Map<String, dynamic> sig) async {
    if (!_joined) return;
    final from = sig['from']?.toString() ?? '';
    if (from.isEmpty || from == _myId) return;
    final c = sig['candidate'];
    if (c is! Map) return;
    final candidate = RTCIceCandidate(
      c['candidate']?.toString() ?? '',
      c['sdpMid']?.toString(),
      (c['sdpMLineIndex'] as num?)?.toInt() ?? 0,
    );
    final pc = _pcs[from];
    if (pc != null) {
      try {
        await pc.addCandidate(candidate);
      } catch (_) {}
    } else {
      // offer/answer 还没到，先缓存
      (_pendingIce[from] ??= []).add(candidate);
    }
  }

  Future<void> _drainPendingIce(String peerId) async {
    final pending = _pendingIce.remove(peerId);
    final pc = _pcs[peerId];
    if (pending == null || pc == null) return;
    for (final c in pending) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
  }

  Future<void> _closePeer(String peerId) async {
    WebRtcWebAudio.detach(peerId);
    final stream = _remotes.remove(peerId);
    if (stream != null) remoteRevision.value++;
    try {
      await stream?.dispose();
    } catch (_) {}
    final pc = _pcs.remove(peerId);
    try {
      await pc?.close();
    } catch (_) {}
  }
}

/// WebRTC 视频渲染视图。
/// - 本地：监听 localStreamNotifier（流晚于视图就绪也能自动绑上）；
/// - 远端：由 media._remotes 取流（onRemoteJoined 触发后页面才建视图，一般已就绪）。
class _WebRtcVideoView extends StatefulWidget {
  final ValueNotifier<MediaStream?>? streamNotifier;
  final String? userId;
  final WebRtcCallMedia? media;
  final bool mirror;
  const _WebRtcVideoView(
      {super.key,
      this.streamNotifier,
      this.userId,
      this.media,
      this.mirror = false});

  @override
  State<_WebRtcVideoView> createState() => _WebRtcVideoViewState();
}

class _WebRtcVideoViewState extends State<_WebRtcVideoView> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  MediaStream? _bound;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _renderer.initialize();
    if (!mounted) return;
    _bind();
    widget.streamNotifier?.addListener(_bind);
    // 远端视图：流晚于视图到达（时序竞争）时也能自动补绑
    if (widget.streamNotifier == null && widget.media != null) {
      widget.media!.remoteRevision.addListener(_bind);
    }
  }

  void _bind() {
    MediaStream? s;
    if (widget.streamNotifier != null) {
      s = widget.streamNotifier!.value;
    } else {
      s = widget.media?._remotes[widget.userId];
    }
    if (s != null && !identical(s, _bound)) {
      _bound = s;
      _renderer.setSrcObject(stream: s);
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    widget.streamNotifier?.removeListener(_bind);
    widget.media?.remoteRevision.removeListener(_bind);
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RTCVideoView(
      _renderer,
      mirror: widget.mirror,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      placeholderBuilder: (_) => Container(color: const Color(0xFF1A1A1A)),
    );
  }
}
