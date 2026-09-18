import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../app_navigator.dart';
import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import 'api_client.dart';
import 'e2ee_service.dart';
import '../widgets/app_dialogs.dart';
import 'wallet_store.dart';

/// WebSocket 长连接（消息实时收发）
/// - 连接时带 token 鉴权
/// - 30s 心跳续期在线状态
/// - 断线自动重连（指数退避，最大 30s），重连成功后回调 onReconnected 触发补拉
class WsService {
  WsService(
      {required this.onMessage,
      required this.onRecall,
      this.onReconnected,
      this.onRead,
      this.onHistoryCleared,
      this.onWallet,
      this.onFriendRequest,
      this.onForceLogout,
      this.onE2eeRecover,
      this.onCallUpdate});

  /// 收到新消息：data = 服务端消息对象 Map
  final void Function(Map<String, dynamic> data) onMessage;

  /// 收到撤回通知：{conversationId, msgId, recalledBy}
  final void Function(Map<String, dynamic> data) onRecall;

  /// 通话记录改写通知（一通电话一条记录）：{conversationId, msgId, content}
  /// 服务端把结束态（done/rejected/missed + duration）写回 invite 消息后广播，
  /// 客户端按 msgId 找到本地气泡并原地替换 content。
  final void Function(Map<String, dynamic> data)? onCallUpdate;

  /// 收到余额变动通知：{balance, frozen}（B-24）
  /// 后台加款 / 红包被领 / 到期退回时服务端主动推，客户端收到即刷新，
  /// 不必再靠"切 tab"或"杀进程重进"才能看到新余额。
  final void Function(Map<String, dynamic> data)? onWallet;

  /// 收到已读事件：{conversationId, userId, msgId}
  final void Function(Map<String, dynamic> data)? onRead;

  /// 「删除双方聊天记录」事件（history.cleared）：data 带 conversationId /
  /// clearedMsgId / byUserId（均雪花字符串）。在线端实时清空本地聊天窗与缓存。
  final void Function(Map<String, dynamic> data)? onHistoryCleared;

  /// 收到好友申请/通过事件（需求6：通讯录红点）
  final void Function(Map<String, dynamic> data)? onFriendRequest;

  /// 服务端强制下线事件（后台禁用账号 / 踢人）：收到即清登录态并跳登录页
  final void Function(Map<String, dynamic> data)? onForceLogout;

  /// E2EE 跨设备恢复信令（2026-09-18）：
  /// action=request → 本设备作为「旧设备」收到恢复申请（弹审批窗）
  final void Function(Map<String, dynamic> data)? onE2eeRecover;

  /// 重连成功回调（用于按 lastSeq 补拉缺失消息）
  final void Function()? onReconnected;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _heartbeat;
  bool _closed = false;
  int _retry = 0;

  String? _token; // 重连/死连接检测需要
  String? _deviceId; // WS 握手 query 携带，服务端据此登记设备级在线并可「注销该设备」时定位断开
  DateTime _lastPong = DateTime.now(); // 最近一次收到服务端 pong（死连接检测用）
  bool _connected = false; // ready 成功后置 true，断线置 false
  bool _everConnected = false; // 区分「首次连接」与「重连」后的补拉回调
  static const _maxRetrySec = 30;
  static const _deadThreshold = Duration(seconds: 75); // 超过此时长无 pong 即判定连接已死

  /// [deviceId]：ApiClient 持久化的设备号（UUID，首次生成后复用）。
  /// 契约（im-server/doc/API.md 设备会话节）：WS 连接**必须**带 deviceId，
  /// 否则该连接无设备身份——不参与设备级在线统计，也无法被「注销该设备」断开。
  Future<void> connect(String token, {String? deviceId}) async {
    _closed = false;
    _retry = 0;
    _deviceId = deviceId;
    _open(token);
  }

  void _open(String token) {
    if (_closed) return;
    _token = token;
    try {
      final wsBase = AppConfig.instance.wsBase;
      final wsUrl = _resolveWsUrl(wsBase, token);
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _lastPong = DateTime.now();
      _connected = false;
      _sub = _channel!.stream.listen(
        (data) => _handleFrame(data),
        onDone: () => _scheduleReconnect(token),
        onError: (_) => _scheduleReconnect(token),
        cancelOnError: false,
      );
      // 真正连上（握手完成）才标记 connected 并触发补拉，
      // 避免「重连失败」也误以为连上 → 反复无效 sync（审查 #9）。
      _channel!.ready.then((_) {
        if (_closed) return;
        _connected = true;
        if (_everConnected) onReconnected?.call();
        _everConnected = true;
      }).catchError((_) {
        _connected = false;
      });
      _startHeartbeat();
    } catch (_) {
      _scheduleReconnect(token);
    }
  }

  /// WS 地址解析：相对路径（H5 场景，如 /ws）→ 拼当前页面 origin 转 ws/wss
  String _resolveWsUrl(String wsBase, String token) {
    // deviceType：H5=3(web) / native=1(android)——用于在线状态多端登记
    final base = Uri.base;
    final deviceType =
        (base.scheme == 'http' || base.scheme == 'https') ? 3 : 1;
    // deviceId：设备身份（UUID 持久化于 ApiClient），服务端据此登记设备级在线
    final dev = _deviceId == null || _deviceId!.isEmpty
        ? ''
        : '&deviceId=$_deviceId';
    if (wsBase.startsWith('ws://') || wsBase.startsWith('wss://')) {
      return '$wsBase?token=$token&deviceType=$deviceType$dev';
    }
    if (base.scheme == 'http' || base.scheme == 'https') {
      final scheme = base.scheme == 'https' ? 'wss' : 'ws';
      return '$scheme://${base.authority}$wsBase?token=$token&deviceType=$deviceType$dev';
    }
    return '$wsBase?token=$token&deviceType=$deviceType$dev'; // native 未配置时回退
  }

  void _handleFrame(dynamic raw) {
    // 整体 try/catch：单条消息「解析失败」或「某个监听器抛异常」都不应击穿长连接
    // （原 cancelOnError:true + 无保护 → 任一异常都会让 stream 被取消、连接断开，审查 #3）。
    try {
      final Map<String, dynamic> frame;
      try {
        frame = jsonDecode(raw.toString()) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      switch (frame['type']) {
        case 'pong':
          _lastPong = DateTime.now(); // 收到 pong → 连接存活（死连接检测用）
          break;
        case 'message':
          final data = frame['data'];
          if (data is Map<String, dynamic>) onMessage(data);
          break;
        case 'recall':
          final data = frame['data'];
          if (data is Map<String, dynamic>) onRecall(data);
          break;
        case 'call_update':
          final data = frame['data'];
          if (data is Map<String, dynamic>) onCallUpdate?.call(data);
          break;
        case 'read':
          final data = frame['data'];
          if (data is Map<String, dynamic>) onRead?.call(data);
          break;
        case 'history.cleared':
          // 删除双方聊天记录（2026-09-18）：软删位点推进 → 在线端实时清空
          final data = frame['data'];
          if (data is Map<String, dynamic>) onHistoryCleared?.call(data);
          break;
        case 'friend.request':
        case 'friend.accepted':
        case 'friend.deleted':
          final data = frame['data'];
          if (data is Map<String, dynamic>) onFriendRequest?.call(data);
          break;
        case 'wallet':
          // B-24：余额/冻结变动（后台加款、红包被领、到期退回）→ 立即拉最新值
          final data = frame['data'];
          onWallet?.call(data is Map<String, dynamic> ? data : const {});
          break;
        case 'forceLogout':
          // 后台禁用账号等：服务端强制下线，清登录态并跳登录页
          final data = frame['data'];
          onForceLogout?.call(data is Map<String, dynamic> ? data : const {});
          break;
        case 'e2ee.recover':
          // E2EE 跨设备恢复信令（action=request：旧设备弹审批窗）
          final data = frame['data'];
          onE2eeRecover?.call(data is Map<String, dynamic> ? data : const {});
          break;
      }
    } catch (_) {
      // 单条消息异常吞掉，保活长连接
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      // 死连接检测：若 75s 内未收到任何服务端 pong（网络静默断开 / NAT 超时 /
      // 切后台被系统回收），主动重连，避免「连接看似在但其实已死、收不到消息」
      // 的情形（审查 #1）。正常的连接每 ~30s 必有一次 pong 续命。
      if (DateTime.now().difference(_lastPong) > _deadThreshold) {
        _scheduleReconnect(_token ?? '');
        return;
      }
      _channel?.sink.add(jsonEncode({'action': 'ping'}));
    });
  }

  void _scheduleReconnect(String token) {
    if (_closed) return;
    _connected = false; // 进入重连流程即标记断开，死连接检测与对外状态一致
    _heartbeat?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    final delay = (_retry * 2).clamp(1, _maxRetrySec);
    _retry++;
    Timer(Duration(seconds: delay), () {
      if (_closed) return;
      _open(token);
      // 注意：onReconnected 不再这里调用 —— 只有 _open 后 ready 真正成功才补拉
      // （见 _open 内 ready.then），避免「重连尚未成功」也反复触发无效 sync（审查 #9）。
    });
  }

  void sendPing() {
    _channel?.sink.add(jsonEncode({'action': 'ping'}));
  }

  void close() {
    _closed = true;
    _connected = false;
    _heartbeat?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
  }

  /// 连接是否健康（已 ready 且未关闭）—— 供 GlobalWs 判断是否需要重连。
  bool get isHealthy => _connected && !_closed;
}

/// 全局 WS 单例：登录后建立一条长连接，各页面（会话列表/通讯录/聊天页）共享
/// 需求7：消息列表实时接收推送，无需刷新
class GlobalWs {
  static final GlobalWs instance = GlobalWs._();
  GlobalWs._() {
    // 服务端强制下线分两类（data.reason 区分）：
    // - device_logged_out：本设备的活跃会话被「设备页-注销」吊销（device.logout）
    // - 其它（无 reason / 其他值）：后台禁用账号等账号级强制下线
    // 收到即弹提示，用户确认后清登录态并跳登录页。
    onForceLogout((data) async {
      // 设备级下线：deviceId 不一致说明踢的不是本机连接（理论上服务端只推给
      // 被注销的那条连接，这里防御一下，避免误清登录态）
      final isDeviceLogout = data['reason']?.toString() == 'device_logged_out';
      if (isDeviceLogout) {
        final kicked = data['deviceId']?.toString() ?? '';
        if (kicked.isNotEmpty) {
          final local = await ApiClient.instance.getDeviceId();
          if (kicked != local) return;
        }
      }
      final l = AppLocalizations.instance.t;
      final nav = appNavigatorKey.currentState;
      final ctx = nav?.context;
      if (ctx != null && ctx.mounted) {
        await showDialog<void>(
          context: ctx,
          barrierDismissible: false,
          builder: (c) => AlertDialog(
            title: Text(isDeviceLogout
                ? l('devDeviceKickedTitle')
                : l('accountBannedTitle')),
            content: Text(isDeviceLogout
                ? l('devDeviceKickedMsg')
                : l('accountBannedMsg')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(c).pop(),
                child: Text(l('accountBannedConfirm')),
              ),
            ],
          ),
        );
      }
      unawaited(ApiClient.instance.forceLogout());
      GlobalWs.instance.close();
    });

    // E2EE 跨设备恢复申请（2026-09-18）：本设备作为「旧设备」收到申请。
    // 只有本机私钥就绪（真的能解旧消息）才弹审批；否则静默忽略（申请方
    // 轮询超时自然结束）。
    onE2eeRecover((data) async {
      if ((data['action'] ?? '').toString() != 'request') return;
      if (!E2eeService.instance.isReady) return;
      final l = AppLocalizations.instance.t;
      final nav = appNavigatorKey.currentState;
      final ctx = nav?.context;
      if (ctx == null || !ctx.mounted) return;
      final requestId = (data['requestId'] ?? '').toString();
      final newPub = (data['newPub'] ?? '').toString();
      final deviceName = (data['deviceName'] ?? '').toString();
      if (requestId.isEmpty || newPub.isEmpty) return;
      final approve = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          title: Text(l('devRecoverAskTitle')),
          content: Text(l('devRecoverAskMsg').replaceAll('{device}', deviceName)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: Text(l('devRecoverReject')),
            ),
            TextButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: Text(l('devRecoverApprove')),
            ),
          ],
        ),
      );
      if (approve == null) return; // 弹窗被系统销毁：不动，等过期
      final ok = await E2eeService.instance.respondRecovery(requestId, newPub, approve);
      if (ok && approve && ctx.mounted) {
        AppDialogs.toast(ctx, l('devRecoverApproved'));
      }
    });
  }

  WsService? _ws;
  bool _connecting = false;

  final List<void Function(Map<String, dynamic>)> _messageListeners = [];
  final List<void Function(Map<String, dynamic>)> _recallListeners = [];
  final List<void Function(Map<String, dynamic>)> _callUpdateListeners = [];
  final List<void Function(Map<String, dynamic>)> _readListeners = [];
  final List<void Function(Map<String, dynamic>)> _historyClearedListeners = [];
  final List<void Function(Map<String, dynamic>)> _friendListeners = [];
  final List<void Function(Map<String, dynamic>)> _forceLogoutListeners = [];
  final List<void Function(Map<String, dynamic>)> _e2eeRecoverListeners = [];
  final List<void Function()> _reconnectedListeners = [];

  /// 建立全局连接（登录成功后调用；已有连接则复用）
  Future<void> ensureConnected() async {
    if (_ws != null || _connecting) return;
    _connecting = true;
    try {
      final token = await ApiClient.instance.readToken();
      if (token == null) return;
      // WS 握手必须带 deviceId（设备会话契约）：UUID 持久化，首次生成后复用
      final deviceId = await ApiClient.instance.getDeviceId();
      _ws = WsService(
        onMessage: (m) => _notify(_messageListeners, m),
        onRecall: (m) => _notify(_recallListeners, m),
        onCallUpdate: (m) => _notify(_callUpdateListeners, m),
        onRead: (m) => _notify(_readListeners, m),
        onHistoryCleared: (m) => _notify(_historyClearedListeners, m),
        onFriendRequest: (m) => _notify(_friendListeners, m),
        onForceLogout: (m) => _notify(_forceLogoutListeners, m),
        // E2EE 跨设备恢复申请（2026-09-18）：旧设备收到后弹审批窗
        onE2eeRecover: (m) => _notify(_e2eeRecoverListeners, m),
        // B-24：余额变动是**全局**事件，与当前停在哪个页面无关，
        // 所以不走页面监听器列表，直接刷 WalletStore（valueNotifier 会自动驱动 UI）。
        onWallet: (_) => unawaited(WalletStore.instance.refresh()),
        onReconnected: () {
          // 断线期间可能漏收余额变动，重连后补拉一次兜底
          unawaited(WalletStore.instance.refresh());
          for (final cb in _reconnectedListeners) {
            cb();
          }
        },
      );
      await _ws!.connect(token, deviceId: deviceId);
    } finally {
      _connecting = false;
    }
  }

  void _notify(
      List<void Function(Map<String, dynamic>)> list, Map<String, dynamic> m) {
    for (final cb in List.of(list)) {
      cb(m);
    }
  }

  /// 注册消息监听，返回取消函数
  VoidCallback onMessage(void Function(Map<String, dynamic>) cb) {
    _messageListeners.add(cb);
    return () => _messageListeners.remove(cb);
  }

  VoidCallback onRecall(void Function(Map<String, dynamic>) cb) {
    _recallListeners.add(cb);
    return () => _recallListeners.remove(cb);
  }

  /// 注册通话记录改写监听（call_update），返回取消函数
  VoidCallback onCallUpdate(void Function(Map<String, dynamic>) cb) {
    _callUpdateListeners.add(cb);
    return () => _callUpdateListeners.remove(cb);
  }

  VoidCallback onRead(void Function(Map<String, dynamic>) cb) {
    _readListeners.add(cb);
    return () => _readListeners.remove(cb);
  }

  /// 注册「删除双方聊天记录」事件监听（history.cleared），返回取消函数
  VoidCallback onHistoryCleared(void Function(Map<String, dynamic>) cb) {
    _historyClearedListeners.add(cb);
    return () => _historyClearedListeners.remove(cb);
  }

  VoidCallback onFriend(void Function(Map<String, dynamic>) cb) {
    _friendListeners.add(cb);
    return () => _friendListeners.remove(cb);
  }

  /// 注册强制下线监听，返回取消函数
  VoidCallback onForceLogout(void Function(Map<String, dynamic>) cb) {
    _forceLogoutListeners.add(cb);
    return () => _forceLogoutListeners.remove(cb);
  }

  /// 注册 E2EE 跨设备恢复信令监听，返回取消函数
  VoidCallback onE2eeRecover(void Function(Map<String, dynamic>) cb) {
    _e2eeRecoverListeners.add(cb);
    return () => _e2eeRecoverListeners.remove(cb);
  }

  VoidCallback onReconnected(void Function() cb) {
    _reconnectedListeners.add(cb);
    return () => _reconnectedListeners.remove(cb);
  }

  /// App 回到前台：若全局连接已死 / 未建立则重建（审查 #1）。
  /// 连接健康（已 ready 且未关闭）时直接跳过，避免反复打断。
  void reconnectIfNeeded() {
    if (_ws != null && _ws!.isHealthy) return;
    if (_connecting) return; // 正在建立，勿打断
    _restart();
  }

  void _restart() {
    _ws?.close();
    _ws = null;
    unawaited(ensureConnected());
  }

  /// 全局连接是否健康（供外部查询）。
  bool get isAlive => _ws != null && _ws!.isHealthy;

  void close() {
    _ws?.close();
    _ws = null;
    _messageListeners.clear();
    _recallListeners.clear();
    _callUpdateListeners.clear();
    _readListeners.clear();
    _friendListeners.clear();
    _forceLogoutListeners.clear();
    _reconnectedListeners.clear();
  }
}
