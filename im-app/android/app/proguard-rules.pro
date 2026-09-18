# mobile_scanner / ML Kit 条码识别：R8 full mode 会裁掉 ML Kit 通过反射
# 注册的组件，导致 release 包扫码崩溃（混淆名 NPE，如 r5.c r5.b.a(n5.b)）。
# 上游 issue: juliansteenbakker/mobile_scanner#1722 #1725
# 注意：必须用双星 ** （插件自带的单星 keep 规则是已知 bug，覆盖不到子包）
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }

# ===== 极光推送 JPush（jpush_flutter 3.5.6 不自带 proguard 规则）=====
# R8 会裁剪/混淆 cn.jpush / cn.jiguang 的类，导致 release 包
# 初始化或 setAlias 时 JVM 层崩溃（NoClassDefFoundError / NoSuchMethodError），
# Dart 的 try/catch 无法捕获。以下为极光官方 keep 规则。
-dontwarn cn.jpush.**
-keep class cn.jpush.** { *; }
-keep class * extends cn.jpush.android.service.JPushMessageReceiver { *; }
-dontwarn cn.jiguang.**
-keep class cn.jiguang.** { *; }
