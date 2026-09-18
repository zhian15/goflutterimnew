import 'package:flutter/services.dart';

/// 桌面图标角标（未读红点）：把全局未读数同步到桌面图标。
///
/// - 数据源：UnreadStore.total（会话列表每次刷新/增量更新都会 update）；
/// - 通道：im_app/rom 的 setBadge（native 端各厂商逐一尝试、静默失败）；
/// - 语义：跟随未读总数实时设置，归零即清（登录登出/全部已读都会归零）。
/// 部分国产 ROM 无公开角标 API（OPPO 需白名单、小米跟通知走），
/// 这些机型上本接口无效果但不报错，离线推送的通知角标由系统自动维护。
class AppBadge {
  AppBadge._();
  static const MethodChannel _channel = MethodChannel('im_app/rom');

  static int _last = -1; // 去重：同一数值不重复发通道

  /// 同步未读总数到桌面角标（UnreadStore.update 里调用）
  static Future<void> sync(int unreadTotal) async {
    final n = unreadTotal < 0 ? 0 : unreadTotal;
    if (n == _last) return;
    _last = n;
    try {
      await _channel.invokeMethod('setBadge', n);
    } catch (_) {
      // 通道不可用（非 Android / 引擎未就绪）静默
    }
  }
}
