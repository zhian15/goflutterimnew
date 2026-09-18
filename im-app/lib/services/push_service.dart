import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:jpush_flutter/jpush_interface.dart'
    show NotificationSettingsIOS;

import '../app_navigator.dart';
import '../config/app_config.dart';
import '../pages/chat_page.dart';
import 'api_client.dart';
import 'conversation_service.dart';

/// 极光推送服务（离线消息兜底）
///
/// 设计：
///   - alias = 用户 ID 字符串。登录进首页后 setAlias(uid)，退出登录 deleteAlias；
///     服务端在接收方不在线时按 alias 下发系统通知（在线用户走 WS 长连接，不推）。
///   - 一台设备同一时刻只有一个 alias：换账号时先解绑旧的再绑新的。
///   - AppKey 走 AppConfig（dart-define / assets/config/app_config.json），
///     未配置时静默跳过，不影响其它功能。
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  final _api = ApiClient.instance;
  dynamic _jpush; // JPush 实例（jpush_flutter 3.x：JPush.newJPush()）
  bool _inited = false;
  String? _alias; // 当前绑定的 alias（= 用户 ID）
  String? _myId; // 缓存我的用户 ID（点击通知跳会话页需要）

  /// 登录态就绪后调用（HomeShell.initState，覆盖启动/登录/注册/扫码四条入口）。
  Future<void> start() async {
    if (kIsWeb) return; // 极光插件不支持 Web 平台
    // 未配置极光 AppKey（线上 config/app_config.json 无 jpushAppKey 字段）时
    // 必须直接跳过，绝不能带着空 AppKey 去初始化原生 SDK：
    // 极光在原生层校验 appKey，空值会抛未捕获异常直接崩进程，
    // Dart 的 try/catch 接不住（不是 PlatformException，是 JVM 层崩溃）。
    if (AppConfig.instance.jpushAppKey.isEmpty) {
      debugPrint('[PushService] jpushAppKey 未配置，跳过极光初始化');
      return;
    }
    try {
      // Android 13+ 通知权限由 KeepAliveService 统一申请（HomeShell 更早触发），
      // 这里不再重复弹框
      final p = await _api.get('/api/v1/user/profile');
      final data =
          (p.data as Map<String, dynamic>)['data'] as Map<String, dynamic>? ??
              {};
      final uid = data['id']?.toString() ?? '';
      if (uid.isEmpty) return;
      _myId = uid;
      final jpush = _ensure();
      if (jpush == null) return; // AppKey 缺失/初始化失败：静默跳过
      if (_alias == uid) return; // 已绑定同一账号
      if (_alias != null && _alias != uid) {
        // 换账号：先解绑旧 alias
        try {
          await jpush.deleteAlias();
        } catch (_) {}
      }
      await jpush.setAlias(uid);
      _alias = uid;
      debugPrint('[PushService] alias bound: $uid');
    } catch (_) {
      // profile 拉取失败 / 极光初始化失败：静默，下次进首页重试
    }
  }

  /// 退出登录：解绑 alias，避免注销后仍收到该账号的离线推送
  Future<void> stop() async {
    if (kIsWeb || _jpush == null) return;
    try {
      await _jpush.deleteAlias();
    } catch (_) {}
    _alias = null;
  }

  dynamic _ensure() {
    if (_inited) return _jpush;
    // 双重保险：_ensure 也可能被其它路径调用，空 AppKey 一律不初始化
    if (AppConfig.instance.jpushAppKey.isEmpty) return null;
    final jpush = JPush.newJPush();
    // 官方要求：addEventHandler 放在 setup 之前
    jpush.addEventHandler(
      onReceiveNotification: (Map<String, dynamic> message) async {},
      // 点击通知栏消息（App 在前台/后台被杀后点击拉起）
      onOpenNotification: (Map<String, dynamic> message) async {
        _openFromPush(message);
      },
      onReceiveMessage: (Map<String, dynamic> message) async {},
    );
    jpush.setup(
      appKey: AppConfig.instance.jpushAppKey,
      channel: 'default',
      production: !kDebugMode,
      debug: kDebugMode,
    );
    // iOS：申请推送权限（系统授权框只弹一次）
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      jpush.applyPushAuthority(
          NotificationSettingsIOS(sound: true, alert: true, badge: true));
      // 冷启动场景：点击系统通知拉起 App 的那条通知
      jpush.getLaunchAppNotification().then((launch) {
        if (launch is Map && launch.isNotEmpty) {
          _openFromPush(Map<String, dynamic>.from(launch));
        }
      }).catchError((_) => null);
    }
    _inited = true;
    _jpush = jpush;
    return jpush;
  }

  /// 解析推送 extras 并跳转到对应会话页
  /// 服务端 extras：conversationId / msgId / senderId / convType / convName
  void _openFromPush(Map<String, dynamic> message) {
    Map<String, dynamic> extras = {};
    final raw = message['extras'];
    if (raw is Map) {
      extras = Map<String, dynamic>.from(raw);
      // Android 自定义 extras 在 cn.jpush.android.EXTRA 子 Map 里，iOS 直接平铺
      final android = raw['cn.jpush.android.EXTRA'];
      if (android is Map) extras = Map<String, dynamic>.from(android);
    }
    final convId = extras['conversationId']?.toString() ?? '';
    if (convId.isEmpty || _myId == null || _myId!.isEmpty) return;
    final convType = int.tryParse(extras['convType']?.toString() ?? '') ?? 1;
    final item = ConvItem.fromJson({
      'conversation': {'id': convId, 'type': convType},
      'conversationName': extras['convName']?.toString() ?? '',
    });
    final nav = appNavigatorKey.currentState;
    if (nav != null) {
      nav.push(MaterialPageRoute(
          builder: (_) => ChatPage(conv: item, myId: _myId!)));
    }
  }
}
