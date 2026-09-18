import 'package:flutter/material.dart';

/// Web 占位（浏览器无摄像头权限，使用输入框兜底）
class ScanCamera extends StatelessWidget {
  final ValueChanged<String> onScan;
  const ScanCamera({super.key, required this.onScan});

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
