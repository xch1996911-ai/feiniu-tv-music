import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/boot_log.dart';
import '../core/log.dart';

/// 本地文件路径解析。
///
/// 曲库索引这类**非敏感元数据**不能塞进 `flutter_secure_storage`
/// （需求 §三-B.4：那会让启动卡顿，且每条都要走 Keystore）。
/// 它需要一个「应用私有目录」—— 原生侧通过已有通道提供 `filesDir`。
///
/// 凭据（密码哈希 / token / deviceId）**仍然只走** [SecureStore]，
/// 两者不混用：
/// - 敏感 → 安全存储（Keystore / Keychain）；
/// - 非敏感但量大 → 私有目录下的普通文件。
class LocalPaths {
  LocalPaths._();

  static const MethodChannel _channel = MethodChannel('feiniu/boot');

  static Directory? _cached;

  /// 应用私有数据目录。失败 / 非 Android 环境返回 null（调用方按「无缓存」降级）。
  ///
  /// ⚠️ 必须带超时：通道对端不返回时 `invokeMethod` **既不返回也不抛异常**。
  static Future<Directory?> dataDir() async {
    final Directory? cached = _cached;
    if (cached != null) return cached;
    try {
      final String? path = await _channel
          .invokeMethod<String>('dataDir')
          .timeout(const Duration(seconds: 5));
      if (path == null || path.isEmpty) return null;
      final Directory dir = Directory(path);
      _cached = dir;
      return dir;
    } catch (e) {
      Log.w('LOCAL_PATHS 无法获取应用数据目录（本次运行不落盘索引）：$e');
      BootLog.mark('数据目录不可用：$e');
      return null;
    }
  }

  /// 覆盖数据目录（仅测试使用）。
  static void overrideForTest(Directory? dir) => _cached = dir;
}
