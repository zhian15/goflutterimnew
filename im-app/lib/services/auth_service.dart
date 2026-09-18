import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';

import 'api_client.dart';
import '../l10n/app_locale.dart';

/// 需要邀请码（服务端 2003）：后台开启邀请码强制时，新游客未携带有效码。
/// 老游客同设备幂等复用不校验，调用方可据此「先静默登录、报此错再弹码」。
class InviteRequiredException implements Exception {
  const InviteRequiredException();
  @override
  String toString() => 'invite code required';
}

class AuthConfig {
  final String authMode; // none / sms / email
  final bool inviteCodeOn;
  final bool registerOn;
  final bool guestOn;

  /// 图形验证码开关（后端未部署该字段时缺失 → 兜底 false，不会崩）
  final bool captchaOn;
  // 品牌信息（后端 /auth/config 提供，前端用于登录/注册页 logo + 名称展示）
  final String appName;
  final String appLogo;
  final String brandName;
  final String brandLogo;

  AuthConfig.fromJson(Map<String, dynamic> j)
      : authMode = j['authMode'] ?? 'none',
        inviteCodeOn = j['inviteCodeOn'] ?? false,
        registerOn = j['registerOn'] ?? true,
        guestOn = j['guestOn'] ?? false,
        captchaOn = j['captchaOn'] ?? false,
        appName = (j['appName'] ?? j['app_name'] ?? 'ChatPulse').toString(),
        appLogo = (j['appLogo'] ?? j['app_logo'] ?? '').toString(),
        brandName =
            (j['brandName'] ?? j['brand_name'] ?? j['appName'] ?? 'ChatPulse')
                .toString(),
        brandLogo = (j['brandLogo'] ?? j['brand_logo'] ?? j['appLogo'] ?? '')
            .toString();
}

class Captcha {
  final String captchaId;
  final String imageBase64;

  Captcha.fromJson(Map<String, dynamic> j)
      : captchaId = j['captchaId'],
        imageBase64 = j['image'];
}

class AuthResult {
  final String accessToken;
  final String refreshToken;
  final Map<String, dynamic> user;
  final bool isNewGuest;

  AuthResult.fromJson(Map<String, dynamic> j)
      : accessToken = j['accessToken'],
        refreshToken = j['refreshToken'],
        user = j['user'] ?? {},
        isNewGuest = j['isNewGuest'] ?? false;
}

class AuthService {
  final Dio _dio = ApiClient.instance.dio;
  final _api = ApiClient.instance;

  // ===== 品牌配置缓存（2026-09-17：启动页预加载，登录页首帧即有 logo/名字）=====
  // 进程内静态缓存：启动页（main.dart _decide 转圈期）就触发 preloadConfig，
  // 网络回来前先落磁盘缓存（'authConfig' 键，about/me 页同款格式）——
  // 登录页 initState 直接读缓存渲染，不再「进页面才拉接口、logo 闪一下才出现」。
  static AuthConfig? cachedConfig;
  static Future<AuthConfig?>? _preloading;

  /// 预取品牌配置：磁盘缓存直出 → 网络刷新（失败保留缓存）。
  /// 重复调用共享同一个在途 Future，不会并发打多次接口。
  Future<AuthConfig?> preloadConfig() {
    return _preloading ??= _doPreload().whenComplete(() => _preloading = null);
  }

  Future<AuthConfig?> _doPreload() async {
    // 1) 磁盘缓存直出（冷启动首帧即有上次的品牌）
    if (cachedConfig == null) {
      try {
        final raw = await _api.readPref('authConfig');
        if (raw != null && raw.isNotEmpty) {
          final d = jsonDecode(raw);
          if (d is Map) {
            cachedConfig = AuthConfig.fromJson(Map<String, dynamic>.from(d));
          }
        }
      } catch (_) {}
    }
    // 2) 网络刷新并回写磁盘（失败静默，保留磁盘缓存）
    try {
      final r = await _api.get('/api/v1/auth/config');
      final d = (r.data['data'] as Map<String, dynamic>?);
      if (d != null && d.isNotEmpty) {
        cachedConfig = AuthConfig.fromJson(d);
        unawaited(
            _api.writePref('authConfig', jsonEncode(d)).catchError((_) {}));
      }
    } catch (_) {}
    return cachedConfig;
  }

  Future<AuthConfig> getConfig() async {
    final r = await _api.get('/api/v1/auth/config');
    return AuthConfig.fromJson(r.data['data']);
  }

  Future<Captcha> getCaptcha() async {
    final r = await _api.get('/api/v1/auth/captcha');
    return Captcha.fromJson(r.data['data']);
  }

  /// 账号可用性查询（公开接口 `GET /api/v1/auth/check-account`）。
  ///
  /// 注册页第 1 步点「下一步」时调用：返回 true 表示该用户名/邮箱/手机号可注册。
  /// 注意本项目**HTTP 恒 200、业务错误在 body.code**，所以必须走 [_check]。
  Future<bool> checkAccount(String account) async {
    final r = await _api
        .get('/api/v1/auth/check-account', query: {'account': account});
    _check(r);
    final data = r.data['data'] as Map<String, dynamic>? ?? {};
    return data['available'] == true;
  }

  /// 发送验证码。channel: sms(短信) / email(邮箱)，为空时由后端按 AUTH_MODE 决定。
  /// 返回实际发送渠道（'sms' / 'email'），供 UI 提示"已发送至短信/邮箱"。
  /// 注意：必须检查响应 code，否则短信发送失败会被静默吞掉（用户看到"已发送"却收不到码）。
  Future<String> sendCode(String account, String captchaId, String captchaCode,
      {String countryCode = '+86', String channel = 'sms'}) async {
    final r = await _dio.post('/api/v1/auth/send-code', data: {
      'account': account,
      'countryCode': countryCode,
      'captchaId': captchaId,
      'captchaCode': captchaCode,
      'channel': channel,
    });
    _check(r);
    final data = r.data['data'];
    return (data is Map && data['channel'] is String)
        ? data['channel'] as String
        : channel;
  }

  Future<AuthResult> login(String account, String password,
      {String deviceId = ''}) async {
    // 登录 POST 幂等（重复提交无害）：走瞬时重试，服务端冷启动/首连慢时
    // 第一次 receive timeout 自动再试，不再让用户手动登第二次
    final r = await _api.postIdempotent('/api/v1/auth/login', data: {
      'account': account,
      'password': password,
      'deviceType': 1,
      'deviceId': deviceId,
    });
    _check(r);
    return AuthResult.fromJson(r.data['data']);
  }

  Future<AuthResult> register({
    required String account,
    required String password,
    String nickname = '',
    String? code,
    String? inviteCode,
    String? captchaId,
    String? captchaCode,
    String? channel,
  }) async {
    final data = <String, dynamic>{
      'account': account,
      'password': password,
      'nickname': nickname,
      'inviteCode': inviteCode,
      'deviceType': 1,
    };
    // 认证模式为 none 时不要带 channel/code：
    // 后端 `req.Channel != ""` 会强制走短信分支，拿空 code 去 Redis 比对必然报 2002
    // 「验证码错误或过期」，而这个报错与图形验证码开关无关。
    if (channel != null && channel.isNotEmpty) {
      data['channel'] = channel;
    }
    if (code != null && code.isNotEmpty) {
      data['code'] = code;
    }
    // 图形验证码（需要时才传）
    if (captchaId != null && captchaId.isNotEmpty) {
      data['captchaId'] = captchaId;
      data['captchaCode'] = captchaCode ?? '';
    }
    final r = await _dio.post('/api/v1/auth/register', data: data);
    _check(r);
    return AuthResult.fromJson(r.data['data']);
  }

  /// 绑定手机号：发送短信验证码（需登录 + 图形验证码）
  Future<void> sendBindPhoneCode(String phone, String countryCode,
      String captchaId, String captchaCode) async {
    final r = await _dio.post('/api/v1/user/bind-phone/send-code', data: {
      'phone': phone,
      'countryCode': countryCode,
      'captchaId': captchaId,
      'captchaCode': captchaCode,
    });
    _check(r);
  }

  /// 绑定手机号：校验短信验证码后写入
  Future<void> bindPhone(String phone, String countryCode, String code) async {
    final r = await _dio.post('/api/v1/user/bind-phone', data: {
      'phone': phone,
      'countryCode': countryCode,
      'code': code,
    });
    _check(r);
  }

  /// 游客注册/登录：按设备号幂等（后端处理）。返回登录态，用法同 login。
  /// [inviteCode]：后台开启邀请码开关时，**新游客**必填——服务端强制校验，
  /// 无效/为空抛 [InviteRequiredException]（2003）；老游客同设备幂等复用
  /// 不校验邀请码（2026-09-17 二次需求：再次登录不弹码直接进）。
  Future<AuthResult> guestRegister(
      {required String deviceId,
      int deviceType = 1,
      String inviteCode = ''}) async {
    final r = await _dio.post('/api/v1/auth/guest', data: {
      'deviceId': deviceId,
      'deviceType': deviceType,
      if (inviteCode.isNotEmpty) 'inviteCode': inviteCode,
    });
    final biz = r.data['code'];
    if (biz == 2003) throw const InviteRequiredException();
    _check(r);
    return AuthResult.fromJson(r.data['data']);
  }

  /// 登录后补填邀请码（游客/普通用户通用），复用后端现有邀请码逻辑自动加好友。
  Future<void> bindInviteCode(String code) async {
    final r = await _api.post('/api/v1/invite/bind', data: {
      'code': code,
    });
    _check(r);
  }

  /// 设置 / 修改支付密码。
  /// [oldPassword]：已设置过 → 必填（校验原密码）；首次设置可传 null/空。
  /// 后端按是否已设置自动分流到 SetPayPwd / ChangePayPwd。
  Future<void> setPayPwd(
      {String? oldPassword, required String newPassword}) async {
    final r = await _dio.post('/api/v1/user/paypwd/set', data: {
      if (oldPassword != null && oldPassword.isNotEmpty)
        'oldPassword': oldPassword,
      'newPassword': newPassword,
    });
    _check(r);
  }

  void _check(Response r) {
    final code = r.data['code'];
    if (code != 0) {
      throw Exception(
          r.data['message'] ?? AppLocalizations.instance.t('svcRequestFailed'));
    }
  }
}
