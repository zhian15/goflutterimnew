import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../theme/app_theme.dart';
import 'v2_avatars.dart' show kV2AvatarAssets;

/// 通用网络头像。
///
/// 解决的问题：原来各页面只在 `errorBuilder` 里回落占位，
/// 而 `Image.network` 在**加载期间什么都不画** → 消息列表/通讯录会先出现白色空头像，
/// 网络慢或图片挂了就是一片白，很难看。
///
/// 做法：底层永远铺一层「彩色底 + 首字」占位，
/// 真实头像在首帧到达后淡入覆盖；加载失败时自动露出占位。
/// 于是「加载中 / 无 URL / 加载失败」三种情况都有统一的缺省头像。
///
/// 2026-09-15 二十三批两处统一（此前各页自行处理，漏改的页面——用户中心/
/// 通讯录/编辑资料/消息列表——头像一直加载失败，用户实测反馈）：
/// 1. URL 统一过 [AppConfig.assetUrl]（幂等）：头像 URL 可能是相对路径或
///    127.0.0.1:9000 的 MinIO 本机地址，手机直连必挂；
/// 2. **个人头像（radius==null）无 URL 时回落内置默认头像**（按昵称哈希挑一张，
///    用户明确要求「没有头像就是默认头像」）；群头像（radius 非空）保持首字占位。
class AppAvatar extends StatelessWidget {
  /// 头像 URL；空字符串 = 没有头像，显示默认头像（个人）/首字占位（群）
  final String url;

  /// 昵称 / 群名：用于生成占位首字、以及未指定 [background] 时的底色
  final String name;

  final double size;

  /// null = 圆形头像；非 null = 圆角方形（群头像常用）
  final double? radius;

  /// 覆盖占位底色（不传则按 name 哈希取 [AppTheme.avatarColors]）
  final Color? background;

  /// name 为空时占位显示的字符
  final String emptyText;

  const AppAvatar({
    super.key,
    required this.url,
    required this.name,
    this.size = 48,
    this.radius,
    this.background,
    this.emptyText = '?',
  });

  @override
  Widget build(BuildContext context) {
    final seed = name.trim().isEmpty ? emptyText.trim() : name.trim();
    final bg = background ??
        AppTheme
            .avatarColors[seed.hashCode.abs() % AppTheme.avatarColors.length];
    // URL 统一修正（幂等）：相对路径换 API 同域、127.0.0.1/localhost 换真实主机
    final fixedUrl = AppConfig.assetUrl(url);
    final isPersonal = radius == null;
    // 个人头像无 URL → 内置默认头像（按昵称哈希在 6 张预设里确定性地挑一张，
    // 同一个人永远同一张默认头像）；群头像保持首字占位。
    final fallbackAsset = isPersonal
        ? kV2AvatarAssets[seed.hashCode.abs() % kV2AvatarAssets.length]
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? size / 2),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 底层占位：加载中 / 无 URL / 加载失败都会显示它（所以永远不会白块）
            Container(
              color: bg,
              alignment: Alignment.center,
              child: fallbackAsset != null
                  ? Image.asset(fallbackAsset,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Text(
                            _initial(seed),
                            style: TextStyle(
                              fontSize: size * 0.4,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ))
                  : Text(
                      _initial(seed),
                      style: TextStyle(
                        fontSize: size * 0.4,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
            ),
            if (fixedUrl.trim().isNotEmpty)
              Image.network(
                fixedUrl,
                fit: BoxFit.cover,
                // 【卡顿修复】头像原图整张解码是列表滚动的经典掉帧源：服务端头像
                // 可能是几千像素的原图，消息列表一屏几十个头像逐个全尺寸解码并
                // 塞进 ImageCache，滚动掉帧、内存暴涨。按「显示尺寸 × dpr」限制
                // 解码宽度（物理像素），48~512 封顶，视觉上无损。
                cacheWidth: ((size *
                            (MediaQuery.maybeOf(context)?.devicePixelRatio ??
                                3.0))
                        .round())
                    .clamp(48, 512),
                // 首帧到达前 opacity=0 → 露出底层占位；到达后 200ms 淡入
                frameBuilder: (ctx, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: child,
                  );
                },
                // 失败时不画任何东西 → 露出底层占位（不再灰块/白块）
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }

  /// 取首个字符（按 rune 取，避免 emoji/生僻字被截断成半个码元）
  static String _initial(String s) {
    final t = s.trim();
    if (t.isEmpty) return '?';
    return String.fromCharCode(t.runes.first);
  }
}
