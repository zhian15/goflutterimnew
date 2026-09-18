import 'api_client.dart';

/// 版本更新：本地基准版本 + 后台最新版本配置
///
/// - 本地基准版本（currentVersion）由 tool/apply_config.dart 自动同步自
///   config/app_build.json 的 versionName，【不要手改】。
/// - 后台配置项（sys_config）：app_version / update_log / android_url / ios_url。
/// - 检查更新走 versionName 字符串对比；versionCode 仅用于系统覆盖安装判断。
class UpdateService {
  /// 当前 App 版本（与打包 versionName 一致，apply_config 自动同步）
  static const currentVersion = '1.3.0';

  /// 拉取后台版本配置；网络失败返回 null（调用方静默处理，不打扰用户）
  static Future<UpdateInfo?> fetch() async {
    try {
      final r = await ApiClient.instance.get('/api/v1/auth/config');
      final body = r.data as Map<String, dynamic>;
      final d = (body['data'] as Map?) ?? {};
      return UpdateInfo(
        version: d['appVersion']?.toString() ?? '',
        log: d['updateLog']?.toString() ?? '',
        androidUrl: d['androidUrl']?.toString() ?? '',
        iosUrl: d['iosUrl']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 后台版本配置快照
class UpdateInfo {
  final String version; // 后台配置的最新版本（appVersion）
  final String log; // 更新内容（updateLog）
  final String androidUrl; // 安卓 APK 下载地址
  final String iosUrl; // iOS 下载地址

  const UpdateInfo({
    required this.version,
    required this.log,
    required this.androidUrl,
    required this.iosUrl,
  });

  /// 后台配置了与本地不同的版本 → 有新版本
  bool get hasNew =>
      version.isNotEmpty && version != UpdateService.currentVersion;

  /// 是否配置了下载地址（有新版本时用它判断能否引导下载）
  bool get hasUrl => androidUrl.isNotEmpty || iosUrl.isNotEmpty;

  /// 下载地址：安卓优先
  String get downloadUrl => androidUrl.isNotEmpty ? androidUrl : iosUrl;
}
