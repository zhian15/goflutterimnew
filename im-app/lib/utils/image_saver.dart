import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/app_config.dart';

/// 网络图片保存到系统相册（朋友圈九宫格长按 / 大图页按钮共用）
class ImageSaver {
  ImageSaver._();

  /// 下载并保存图片，成功返回 true；失败返回 false / 抛异常（由调用方统一 toast）。
  ///
  /// 流程：Android 存储权限（≤12 需要，13+ 走 MediaStore 不需要）→
  /// Dio 下载 bytes（图片是 MinIO 完整地址，不经带 token 的 ApiClient）→
  /// ImageGallerySaverPlus.saveImage 写入相册。
  static Future<bool> saveNetworkImage(String url) async {
    // Web 无系统相册可写，直接跳过（dart:io Platform 在 Web 抛 Unsupported 报错崩页）
    if (kIsWeb) return false;
    // Android ≤12 写相册需要存储权限；13+ request() 直接返回 denied，不影响保存
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await Permission.storage.request();
      } catch (_) {
        // 权限插件异常不阻断保存（Android 13+ 无需权限也能写入 MediaStore）
      }
    }
    // 相对路径兜底：补全接口域名（正常图片 URL 已是完整地址）
    var full = url;
    if (!full.startsWith('http')) {
      final base = AppConfig.instance.apiBase;
      full = full.startsWith('/') ? '$base$full' : '$base/$full';
    }
    final resp = await Dio().get<List<int>>(
      full,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
      ),
    );
    final data = resp.data;
    if (data == null || data.isEmpty) return false;
    final bytes = Uint8List.fromList(data);
    final r = await ImageGallerySaverPlus.saveImage(bytes, quality: 100);
    // Android 返回 {isSuccess: bool, filePath: String}；iOS 返回保存路径字符串
    if (r is Map) {
      return r['isSuccess'] == true ||
          (r['filePath']?.toString().isNotEmpty ?? false);
    }
    return r != null && r.toString().isNotEmpty;
  }
}
