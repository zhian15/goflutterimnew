import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/e2ee_service.dart'; // E2EE 登录后静默建钥/解锁（§36）
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/agreement_checkbox.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/lang_picker.dart';
import '../widgets/v2_avatars.dart';
import '../widgets/v2_kit.dart';
import 'home_shell.dart';
import 'policy_page.dart';
import 'register_page.dart';

/// 登录页（V2 复刻版：纯白底 + 近黑主按钮 + 灰色填充输入框）
///
/// 一屏改版（原独立游客引导页 GuestPage 已合并进本页）：
/// - 未登录启动直达本页；「一键注册登录」按钮仅在后端 guestOn 开启时显示
/// - 「找回账号密码」提示行与链接行已删除
/// - 顶部留白与表单间距整体压缩，保证一屏内显示完
///
/// 版式与尺寸全部来自 `UI-ref/DESIGN.md` —— 对目标 APK 真机截图做程序化取色与元素
/// bbox 测量得出（DPR=3，逻辑尺寸 420×1153），不是肉眼估的：
///
/// | 元素 | 尺寸（逻辑px） |
/// |---|---|
/// | 页面左右留白 | 51 |
/// | 输入框 | 高 69 / 圆角 16 / 填充 `#F1F2F4` |
/// | 主按钮（登录） | 高 65 / 填充 `#0C0D12` |
/// | 描边按钮（一键注册登录） | 高 64 |
/// | Logo | 118 圆角方形 |
/// | 应用名 | fontSize 32 / w800 |
///
/// 与旧版差异：去掉白色大卡片与品牌圆环加载动画（截图里没有），接口状态指示退居为
/// 左上角一个 6px 小点 + 10px 灰字（保留可观测性但不抢视觉），语言胶囊保留。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _accountCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _pwdFocus = FocusNode();
  bool _pwdVisible = false;
  bool _loading = false; // 密码登录中
  bool _quickLoading = false; // 一键注册登录中

  // ===== 后台下发品牌信息 =====
  AuthConfig? _cfg; // 完整配置（邀请码开关 inviteCodeOn 用）
  String _logoUrl = ''; // appLogo / brandLogo
  String _appName = ''; // appName / brandName（截图中 Logo 下方那行大字）
  bool _guestOn = false; // 一键注册登录开关（后端 /auth/config 的 guestOn）

  // ===== 协议勾选（App Store 审核合规）=====
  // 默认不勾（iOS 要求用户主动同意）；本地已同意过则默认勾上，免重复勾选。
  bool _agreeChecked = false;
  bool _agreeWarn = false; // 未勾选拦截提示态（淡红底 + 抖动）

  // ===== 接口状态指示（左上角：点 + 毫秒）=====
  // 0=检测中(灰) 1=正常(绿) 2=慢(黄) 3=不通(红)
  static const int _apiChecking = 0;
  static const int _apiOk = 1;
  static const int _apiSlow = 2;
  static const int _apiDown = 3;
  int _apiState = _apiChecking;
  int? _apiMs;
  Timer? _apiTimer;
  Dio? _apiProbe;

  final _svc = AuthService();

  @override
  void initState() {
    super.initState();
    // 恢复本地「已同意协议」状态（勾选一次后不再要求重复勾）
    _agreeChecked = AppSettings.instance.policyAgreed;
    _loadBrand();
    _probeApi();
    // 每 20 秒复测一次，保证离开页面进来说明是实时状态
    _apiTimer = Timer.periodic(const Duration(seconds: 20), (_) => _probeApi());
  }

  @override
  void dispose() {
    _apiTimer?.cancel();
    _apiProbe?.close();
    _accountCtrl.dispose();
    _pwdCtrl.dispose();
    _pwdFocus.dispose();
    super.dispose();
  }

  // ============================================================
  // 品牌信息
  // ============================================================
  Future<void> _loadBrand() async {
    // 首帧即用启动页预加载好的缓存（同步上屏），网络刷新回来再覆盖：
    // 消「进登录页 logo/名字先显示占位、接口回来才变一下」。
    final pre = AuthService.cachedConfig;
    if (pre != null) _applyCfg(pre);
    try {
      final cfg = await _svc.preloadConfig();
      if (!mounted || cfg == null) return;
      _applyCfg(cfg);
    } catch (_) {
      // 接口失败静默回退默认品牌占位，不影响登录
    }
  }

  void _applyCfg(AuthConfig cfg) {
    setState(() {
      _cfg = cfg;
      _logoUrl = cfg.appLogo.isNotEmpty ? cfg.appLogo : cfg.brandLogo;
      _appName = cfg.appName.isNotEmpty ? cfg.appName : cfg.brandName;
      _guestOn = cfg.guestOn;
    });
  }

  /// 显示用应用名。接口未返回时回落后端同款默认值（AuthConfig 里也是 ChatPulse）。
  String get _displayAppName => _appName.isNotEmpty ? _appName : 'ChatPulse';

  // ============================================================
  // 接口延迟探测
  // ============================================================
  /// GET /api/v1/health，独立轻量 Dio（3s 超时，不走鉴权拦截器）。
  /// 服务器有任何响应（含 4xx/5xx）都算"通"，只有连接失败/超时才算不通。
  Future<void> _probeApi() async {
    final sw = Stopwatch()..start();
    try {
      _apiProbe ??= Dio(BaseOptions(
        baseUrl: AppConfig.instance.apiBase,
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        // 服务器返回任何状态码都算连通（health 正常是 200，这里宽容处理）
        validateStatus: (_) => true,
      ));
      await _apiProbe!.get('/api/v1/health');
      sw.stop();
      if (!mounted) return;
      final ms = sw.elapsedMilliseconds;
      setState(() {
        _apiMs = ms;
        _apiState = ms > 1000 ? _apiSlow : _apiOk;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _apiState = _apiDown;
        _apiMs = null;
      });
    }
  }

  // ============================================================
  // 协议
  // ============================================================
  /// 勾选/取消协议（同步写本地持久化）
  Future<void> _toggleAgree(bool v) async {
    setState(() {
      _agreeChecked = v;
      _agreeWarn = false; // 勾选后立即解除红色提示态
    });
    await AppSettings.instance.setPolicyAgreed(v);
  }

  /// 未勾选拦截：Toast + 协议行淡红高亮 + 抖动（重复点击重复抖）
  void _flagAgreeWarn() {
    final t = AppLocalizations.of(context).t;
    AppDialogs.toast(context, t('termsAgreeRequired'));
    if (_agreeWarn) {
      // 已经处于提示态：先复位再下一帧重新触发，让抖动重放
      setState(() => _agreeWarn = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _agreeWarn = true);
      });
    } else {
      setState(() => _agreeWarn = true);
    }
  }

  /// 打开协议详情页（isPrivacy=false → 用户服务协议；true → 隐私政策）
  void _openPolicy({required bool isPrivacy}) {
    final t = AppLocalizations.of(context).t;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PolicyPage(
        title: t(isPrivacy ? 'mePrivacyPolicy' : 'meTermsOfService'),
        content: isPrivacy ? kPrivacyPolicy : kTermsOfService,
        appName: _appName,
      ),
    ));
  }

  // ============================================================
  // 登录
  // ============================================================
  Future<void> _doLogin() async {
    final t = AppLocalizations.of(context).t;
    // App Store 合规：未同意协议不得登录（淡红高亮 + 抖动 + Toast）
    if (!_agreeChecked) {
      _flagAgreeWarn();
      return;
    }
    final account = _accountCtrl.text.trim();
    if (account.isEmpty) {
      AppDialogs.toast(context, t('loginAccountRequired'));
      return;
    }
    if (account.length < 3) {
      AppDialogs.toast(context, t('loginAccountTooShort'));
      return;
    }
    // 登录侧只校验「非空」：密码强度规则归注册/改密管，这里再卡长度只会
    // 拦住历史短密码账号登录，属于纯误伤（后端仍会正常校验）。
    final password = _pwdCtrl.text.trim();
    if (password.isEmpty) {
      AppDialogs.toast(context, t('loginPwdRequired'));
      return;
    }

    setState(() => _loading = true);
    try {
      final r = await _svc.login(account, password);
      if (!mounted) return;
      await ApiClient.instance.saveToken(r.accessToken);
      await ApiClient.instance.saveRefresh(r.refreshToken);
      // E2EE（§36）：手里还有明文密码 → 静默建钥/解锁备份（首次登录自动开）。
      // 后台模式非 e2ee / 网络失败均静默跳过，不阻断登录。
      unawaited(E2eeService.instance.setupAfterLogin(password));
      if (!mounted) return;
      AppDialogs.toast(context, t('loginSuccess'));
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeShell()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      // 网络超时/连接失败不再 dump 原始 DioException，给可读提示
      AppDialogs.toast(context, _friendlyError(e, t));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 一键注册登录：按设备号幂等建号并直接进入（复用后端 `/auth/guest`）。
  /// 由原独立游客引导页 GuestPage 合并而来：后台开启游客登录（guestOn）时
  /// 才显示该按钮，对应文案「无需填写资料，直接创建正式账号」。
  Future<void> _doQuickRegister() async {
    final t = AppLocalizations.of(context).t;
    if (!_agreeChecked) {
      _flagAgreeWarn();
      return;
    }
    if (_quickLoading) return;
    if (!_guestOn) {
      AppDialogs.toast(context, t('loginQuickDisabled'));
      return;
    }
    setState(() => _quickLoading = true);
    try {
      final deviceId = await ApiClient.instance.getDeviceId();
      AuthResult r;
      try {
        // 先静默登录（2026-09-17 二次需求）：老游客同设备复用时服务端
        // 不校验邀请码 → 直接进，不再弹码；只有【新游客 + 后台开启
        // 邀请码强制】才报 2003，此时才弹必填弹窗。
        r = await _svc.guestRegister(
          deviceId: deviceId,
          deviceType: _deviceType,
        );
      } on InviteRequiredException {
        // 新设备首次创建游客：邀请码**必填**弹窗——服务端强制校验、
        // 不允许跳过（无效码 2003 弹窗内报错不关闭）。
        final got = await _showRequiredInviteDialog(deviceId);
        if (!mounted) return;
        if (got == null) return; // 弹窗不可关闭，仅页面销毁时为 null
        r = got;
      }
      await ApiClient.instance.saveToken(r.accessToken);
      await ApiClient.instance.saveRefresh(r.refreshToken);
      // E2EE（2026-09-18）：游客也建钥（§36 默认开启）。游客无登录密码，
      // setupForGuest 内部用一次性随机口令包裹备份 —— 同设备复用走本机私钥。
      unawaited(E2eeService.instance.setupForGuest());
      if (!mounted) return;
      // 新游客随机分配一张内置预设头像（二十批需求）。仅 isNewGuest 时执行：
      // 同设备复用老账号时不覆盖用户已选头像。做法与注册页一致（v2_avatars.dart
      // 顶部注释）：预设头像必须真上传成 URL —— 多端都按 URL 渲染头像，存本地
      // 路径会破图。失败静默降级，不阻断登录（可后续在个人资料里换）。
      if (r.isNewGuest) {
        // 头像上传改后台执行（三次紧凑同批）：两次 HTTP 不再阻塞进主页，
        // AppAvatar 无 URL 时有内置默认头像回落，中途不会破图。
        unawaited(_applyRandomAvatar());
      }
      AppDialogs.toast(context, t('loginQuickDone'));
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeShell()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      AppDialogs.toast(context, _friendlyError(e, t));
    } finally {
      if (mounted) setState(() => _quickLoading = false);
    }
  }

  /// 新游客随机头像（二十批 #2）：从 6 张内置预设里随机选一张，读字节直传
  /// `/upload` 成 URL 后 `PUT /user/profile` 写回（与注册页 `_applyAvatar`
  /// 同款链路）。任何失败都静默 —— 头像不是登录的必要条件。
  Future<void> _applyRandomAvatar() async {
    try {
      final i = Random().nextInt(kV2AvatarAssets.length);
      final data = await rootBundle.load(kV2AvatarAssets[i]);
      final bytes = data.buffer.asUint8List();
      final up = await ApiClient.instance
          .uploadBytes(bytes, 'avatar_${i + 1}.png', dir: 'avatar/');
      final url = (up['url'] ?? '').toString();
      if (url.isEmpty) return;
      final r = await ApiClient.instance
          .put('/api/v1/user/profile', data: {'avatar': url});
      final code = (r.data is Map ? r.data['code'] : null);
      if (code is num && code.toInt() != 0) return;
    } catch (_) {
      // 静默降级
    }
  }

  /// 游客登录**必填**邀请码弹窗（2026-09-17 需求）：后台开启 inviteCodeOn 时，
  /// 填码 → 直接调 `/auth/guest`（服务端强制校验，无效码 2003 弹窗内报错、
  /// 不关闭）。无「跳过」按钮、不可点外部关闭/返回键关闭。成功 pop 返回登录
  /// 结果（null 仅在页面被销毁时出现，调用方据此中止）。
  Future<AuthResult?> _showRequiredInviteDialog(String deviceId) async {
    final codeCtrl = TextEditingController();
    var loading = false;
    var err = '';
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    const primary = AppTheme.primary;
    return showDialog<AuthResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false, // 返回键也不允许跳过
        child: StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
            title: Text(t('guestInviteTitle')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t('guestInviteDesc'),
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                TextField(
                  controller: codeCtrl,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.5,
                      color: scheme.onSurface),
                  decoration: InputDecoration(
                    hintText: t('guestInviteInputHint'),
                    hintStyle: TextStyle(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                    prefixIcon: const Padding(
                      padding: EdgeInsets.only(left: 12, right: 8),
                      child: Icon(Icons.confirmation_number_outlined,
                          color: primary, size: 20),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 0, minHeight: 0),
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.5)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: primary, width: 1.6),
                    ),
                  ),
                ),
                if (err.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(err,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.danger)),
                ],
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: loading
                    ? null
                    : () async {
                        final code = codeCtrl.text.trim();
                        if (code.isEmpty) {
                          setSt(() => err = t('guestInviteInvalid'));
                          return;
                        }
                        setSt(() {
                          loading = true;
                          err = '';
                        });
                        try {
                          final r = await _svc.guestRegister(
                            deviceId: deviceId,
                            deviceType: _deviceType,
                            inviteCode: code,
                          );
                          if (!ctx.mounted) return;
                          Navigator.of(ctx).pop(r);
                        } catch (e) {
                          setSt(() {
                            loading = false;
                            err = e.toString().replaceFirst('Exception: ', '');
                          });
                        }
                      },
                child: Text(t('guestInviteConfirm')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int get _deviceType {
    // 设备类型与 im-server GuestRegister 对齐：1=Android 2=iOS 3=Web 4=Windows 5=macOS
    // 用 defaultTargetPlatform 替代 dart:io Platform（Web 上 dart:io Platform 抛
    // Unsupported operation: Platform._operatingSystem 直接崩页）。
    if (kIsWeb) return 3;
    if (defaultTargetPlatform == TargetPlatform.iOS) return 2;
    return 1; // Android 等默认
  }

  String _friendlyError(
      Object e, String Function(String, [Map<String, String>]) t) {
    final msg = e is DioException && ApiClient.isTransient(e)
        ? t('bootLoadFailed')
        : e.toString().replaceFirst('Exception: ', '');
    return msg.isEmpty ? t('unknownError') : msg;
  }

  void _goRegister() {
    // 用 push 而非 pushReplacement：截图里目标页顶部有返回箭头，允许退回登录页
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RegisterPage()),
    );
  }

  // ============================================================
  // 构建
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final isDark = context.v2IsDark;
    final screenW = MediaQuery.sizeOf(context).width;
    // 左右留白按截图 51；窄屏（<420 逻辑宽）按 12.2% 等比缩，否则 360 宽机型
    // 两侧各吃掉 51 会明显比设计稿瘦。
    final gutter = screenW <= 420
        ? (screenW * 0.122).clamp(18.0, AppTheme.v2Gutter)
        : AppTheme.v2Gutter;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        // 截图是纯白底（深色模式纯黑），不是旧的浅灰
        backgroundColor: context.v2Bg,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (ctx, c) {
              // 纵向自适应（见 v2_kit.v2VScale）：设计稿是按逻辑高 1153 的机型出的，
              // 那些绝对值直接搬到 800 高的屏上，「留白+Logo+应用名」会吃掉近一半屏。
              // 系数：屏高 ≥1150 → 1.0（与设计稿一致）；800 → 约 0.65；≤700 → 0.55。
              // 顶部留白上限整体压低（一屏改版：尽量不滚动即可见全表单）。
              // 2026-09-15 三次紧凑：Logo→名/名→表单上限减半（用户反馈名字上下留白太高）。
              final v = v2VScale(context);
              final topGap = (96 * v).clamp(10.0, 36.0); // SafeArea→Logo 留白
              final logoSize = (118 * v).clamp(72.0, 118.0); // Logo 边长
              final gapLogoName = (57 * v).clamp(5.0, 14.0); // Logo→应用名
              final gapNameForm = (70 * v).clamp(6.0, 16.0); // 应用名→表单
              final nameFontSize = (32 * v).clamp(26.0, 32.0); // 应用名字号
              return SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    // ── 顶栏：接口指示（退居）+ 语言切换（保留）──
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Row(
                        children: [
                          _buildApiStatusChip(t),
                          const Spacer(),
                          _buildLangChip(),
                        ],
                      ),
                    ),
                    SizedBox(height: topGap),
                    // Logo：截图是 118 圆角方形（旧版是圆 + 蓝色光晕，已去掉）
                    _brandLogo(size: logoSize),
                    SizedBox(height: gapLogoName),
                    // 应用名（后台配置名，接口未返回回落 ChatPulse）
                    Text(
                      _displayAppName,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: nameFontSize,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: gapNameForm),
                    // ── 表单区（无卡片，直接落在白底上）──
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: gutter),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _formChildren(t),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _formChildren(String Function(String, [Map<String, String>]) t) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final muted = context.v2MutedColor;
    return [
      // ① 账号
      V2Field(
        controller: _accountCtrl,
        hint: t('loginAccountHint'),
        icon: Icons.person_outline_rounded,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.username],
        onSubmitted: (_) => _pwdFocus.requestFocus(),
      ),
      const SizedBox(height: 12),
      // ② 密码（右侧睁眼/闭眼）
      V2Field(
        controller: _pwdCtrl,
        hint: t('loginPwdHint'),
        icon: Icons.lock_outline_rounded,
        focusNode: _pwdFocus,
        obscureText: !_pwdVisible,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.password],
        onSubmitted: (_) => _doLogin(),
        suffix: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _pwdVisible = !_pwdVisible),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              _pwdVisible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
              color: context.v2HintColor,
            ),
          ),
        ),
      ),
      const SizedBox(height: 18),
      // ③ 协议勾选行（plain：截图里是白底裸文字，没有灰底圆角块）
      AgreementCheckbox(
        checked: _agreeChecked,
        warn: _agreeWarn,
        onToggle: _toggleAgree,
        onOpenTerms: () => _openPolicy(isPrivacy: false),
        onOpenPrivacy: () => _openPolicy(isPrivacy: true),
        plain: true,
        checkColor: context.v2ActionBg,
      ),
      const SizedBox(height: 18),
      // ④ 主按钮（近黑填充）
      V2PrimaryButton(
        label: t('loginSubmit'),
        loading: _loading,
        onPressed: _doLogin,
      ),
      // ⑤ 一键注册登录区：后台开启游客登录（/auth/config 的 guestOn）才显示；
      //    未开启时整块（分隔线+按钮+说明）不渲染，登录页更紧凑。
      if (_guestOn) ...[
        const SizedBox(height: 14),
        V2OrDivider(label: t('loginOr')),
        const SizedBox(height: 14),
        V2OutlineButton(
          label: t('loginQuickRegister'),
          loading: _quickLoading,
          onPressed: _doQuickRegister,
        ),
        const SizedBox(height: 8),
        Text(
          t('loginQuickRegisterDesc'),
          textAlign: TextAlign.center,
          // 实测 15 字占 227.3 逻辑px → 15.2 ≈ 15
          style: TextStyle(fontSize: 15, color: muted),
        ),
      ],
      const SizedBox(height: 20),
      // ⑥ 底部：还没有账号？立即注册
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            t('loginNoAccount'),
            // 实测 9 字（含间隔）占 181.7 逻辑px → 单字步进 17.3 ≈ 17
            style: TextStyle(fontSize: 17, color: muted),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _goRegister,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                t('registerNow'),
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
    ];
  }

  // ========= 品牌 Logo（118 圆角方形；接口图片优先，失败回退占位） =========
  Widget _brandLogo({double size = 118}) {
    if (_logoUrl.isEmpty) return AppTheme.brandAvatar(size: size);
    final radius = BorderRadius.circular(size / 4);
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: radius,
        // 加载中 / 加载失败都露出底层品牌占位，避免白块
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppTheme.brandAvatar(size: size),
            Image.network(
              _logoUrl,
              fit: BoxFit.cover,
              frameBuilder: (ctx, child, frame, wasSync) =>
                  (wasSync || frame != null) ? child : const SizedBox.shrink(),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  // ========= 左上角接口状态指示（退居版：无胶囊底、无阴影，6px 点 + 10px 灰字） =========
  Widget _buildApiStatusChip(
    String Function(String, [Map<String, String>]) t,
  ) {
    late final Color dot;
    late final String label;
    switch (_apiState) {
      case _apiOk:
        dot = const Color(0xFF34C759); // 绿：正常
        label = '${_apiMs ?? 0}ms';
        break;
      case _apiSlow:
        dot = const Color(0xFFFFB020); // 黄：慢（>1000ms）
        label = '${_apiMs ?? 0}ms';
        break;
      case _apiDown:
        dot = const Color(0xFFE5484D); // 红：不通
        label = t('apiDown');
        break;
      default:
        dot = const Color(0xFF9E9E9E); // 灰：检测中
        label = t('apiChecking');
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: context.v2MutedColor,
            fontWeight: FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  // ========= 右上角语言入口（点击弹语言菜单，见 widgets/lang_picker.dart） =========
  Widget _buildLangChip() {
    // 显示当前语言；点开弹窗可四语切换或恢复跟随系统
    final cur = AppLocalizations.of(context).locale;
    final curLabel = AppLocalizations.langNativeName(cur);
    return Material(
      color: context.v2Fill,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => showLangPicker(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.language, size: 15, color: context.v2MutedColor),
              const SizedBox(width: 5),
              Text(
                curLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
