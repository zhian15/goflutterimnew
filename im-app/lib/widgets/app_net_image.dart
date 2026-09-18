import 'package:flutter/material.dart';

/// 通用网络图片。
///
/// 统一「加载中 / 空 URL / 加载失败」三种状态的缺省占位：
/// 浅底（surfaceContainerHighest）+ 居中图标，避免出现白块、半截灰块或破图。
/// 加载成功后直接显示（首帧到达前显示占位，不闪烁）。
///
/// 需要点击查看大图等交互时，把本组件包在 GestureDetector 里即可。
class AppNetImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? radius;

  /// 解码宽度上限（列表/网格里传值可显著降内存与解码耗时）
  final int? cacheWidth;

  final double iconSize;

  const AppNetImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.radius,
    this.cacheWidth,
    this.iconSize = 28,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasUrl = url.trim().isNotEmpty;
    Widget img = hasUrl
        ? Image.network(
            url,
            fit: fit,
            width: width,
            height: height,
            cacheWidth: cacheWidth,
            frameBuilder: (ctx, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) return child;
              return _placeholder(cs, Icons.image_outlined);
            },
            errorBuilder: (_, __, ___) =>
                _placeholder(cs, Icons.broken_image_outlined),
          )
        : _placeholder(cs, Icons.image_outlined);
    if (radius != null) {
      img = ClipRRect(borderRadius: radius!, child: img);
    }
    return img;
  }

  Widget _placeholder(ColorScheme cs, IconData icon) {
    return Container(
      width: width,
      height: height,
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(icon,
          size: iconSize, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
    );
  }
}
