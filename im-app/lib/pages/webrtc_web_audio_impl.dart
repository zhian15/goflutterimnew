import 'dart:html' as html;

/// Web 端实现：为每一路远端音频流创建隐藏的 <audio> 元素并挂流播放。
///
/// 为什么不用 RTCVideoView：
/// - 语音通话没有视频视图，远端音频流没有任何元素承载 → 无声；
/// - 视频通话远端视频（video 元素）已经会播音频，这里只在语音通话挂载，
///   否则会双重出声（调用方用 _video 标记区分）。
///
/// 自动播放策略：接听是用户手势，产生 sticky activation，
/// 之后异步到达的流调用 play() 允许出声，不需要额外解锁。
///
/// 实现说明：刻意不依赖 dart:js_util（web-only 库，原生 analyze 报
/// uri_does_not_exist）。dart:html 元素上未声明的属性（srcObject）用
/// dynamic 赋值，dart2js 下等价于直接设置 JS 属性。
class WebRtcWebAudio {
  static final Map<String, html.MediaElement> _els = {};

  static void attach(String peerId, dynamic stream) {
    detach(peerId);
    try {
      final el = html.document.createElement('audio') as html.MediaElement;
      el.id = 'webrtc-remote-audio-$peerId';
      el.autoplay = true;
      el.muted = false;
      // flutter_webrtc web 的 MediaStream 可能是包装对象（内含 jsMediaStream），
      // 兼容两种形态：取得到内层就用内层，取不到按原始对象处理。
      dynamic jsStream = stream;
      try {
        final inner = (stream as dynamic).jsMediaStream;
        if (inner != null) jsStream = inner;
      } catch (_) {}
      // MediaElement 未声明 srcObject 类型，dynamic 设置直通 JS 属性
      (el as dynamic).srcObject = jsStream;
      html.document.body?.append(el);
      el.play();
      _els[peerId] = el;
    } catch (_) {
      // 挂载失败退回无声（与旧行为一致），不影响信令层
    }
  }

  static void detach(String peerId) {
    final el = _els.remove(peerId);
    if (el == null) return;
    try {
      (el as dynamic).srcObject = null;
    } catch (_) {}
    el.remove();
  }

  static void detachAll() {
    for (final k in List<String>.from(_els.keys)) {
      detach(k);
    }
  }
}
