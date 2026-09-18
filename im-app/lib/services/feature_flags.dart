import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 功能开关（后台「系统配置 → 功能开关」配置，经 /auth/config 下发）。
/// 默认全开：后台未配置时不应影响现有功能。
class FeatureFlags {
  FeatureFlags._();
  static final FeatureFlags instance = FeatureFlags._();

  /// 是否开启零钱（关闭 → 聊天窗口不显示红包/转账入口、用户中心不显示我的钱包）
  final ValueNotifier<bool> walletOn = ValueNotifier<bool>(true);

  /// 是否开启邀请码（关闭 → 用户中心不显示我的邀请码）
  final ValueNotifier<bool> inviteOn = ValueNotifier<bool>(true);

  bool _loaded = false;

  /// 拉取一次配置（缓存生效；force=true 强制刷新）。
  /// 失败静默：保持上次/默认值，不打扰用户。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final r = await ApiClient.instance.get('/api/v1/auth/config');
      final j = r.data['data'];
      if (j is Map) {
        walletOn.value = j['walletOn'] != false && j['walletOn'] != 'false';
        inviteOn.value =
            j['inviteFeatureOn'] != false && j['inviteFeatureOn'] != 'false';
        _loaded = true;
      }
    } catch (_) {
      // 网络异常时保持默认值
    }
  }
}
