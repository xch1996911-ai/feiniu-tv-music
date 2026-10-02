import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 启动日志 + 启动健康度。
///
/// ## 为什么需要它（真实故障复盘）
///
/// Android TV 上装了 APK，点开后「黑屏 → 闪退」，而电视盒子通常**没有 adb**，
/// `flutter run` / `logcat` / `dart:developer` 全都拿不到输出 —— 等于零信息。
/// 反复猜测渲染后端或插件兼容性，代价是用户每轮都要「下载 APK → 拷 U 盘 →
/// 装到电视 → 观察」，成本极高。
///
/// 所以启动路径上的每一步都通过本类**落盘**到原生文件：
/// - Dart 侧写 `[dart] xxx`（本类）；
/// - 原生侧在 `MainActivity` 装 `UncaughtExceptionHandler`，崩溃堆栈直接写同一文件。
///
/// 只要进程还活着过一瞬间，日志文件里就会留下「最后走到哪一步」。
/// 若连一行 `[dart]` 都没有，则说明问题在 Flutter 引擎/渲染层（Dart 尚未执行）。
///
/// ## 启动计数 → 自动安全模式
///
/// 原生在 `onCreate` 里把 `boot_attempts` 加一并持久化；Dart 侧启动全部走完后
/// 调用 [markBootOk] 清零。因此：
/// - `boot_attempts >= 2` ⇒ 上一次启动**没走完**（大概率崩在原生层），
///   本次自动进入[安全模式][safeMode]，跳过所有可能触发原生崩溃的步骤，
///   优先保证「能看到界面」。
class BootLog {
  BootLog._();

  static const MethodChannel _channel = MethodChannel('feiniu/boot');

  /// 内存中的最近日志（供引导页直接显示，用户拍照即可）。
  static final List<String> _lines = <String>[];

  /// 内存日志上限，防止长时间运行后无限增长。
  static const int _maxLines = 400;

  static String _path = '(解析中…)';
  static int _bootAttempts = 0;
  static bool _channelUsable = true;
  static Future<void>? _syncFuture;

  /// 原生侧日志文件的绝对路径（显示在引导页上，便于用户/文件管理器定位）。
  static String get path => _path;

  /// 最近日志（只读快照）。
  static List<String> get lines => List<String>.unmodifiable(_lines);

  /// 原生记录的连续启动尝试次数。
  static int get bootAttempts => _bootAttempts;

  /// 安全模式：上次启动未走完，本次跳过所有原生插件相关步骤。
  static bool get safeMode => _bootAttempts >= 2;

  /// 与原生同步的 Future（读启动计数与日志路径）。必须在 `main()` 里同步调用
  /// [start] 之后才有效；未启动时返回已完成的 Future。
  static Future<void> get synced => _syncFuture ?? Future<void>.value();

  /// 开始记录。**必须是同步调用**（`runApp` 之前不允许 `await`）。
  static void start() {
    _syncFuture ??= _syncWithNative();
    mark('======== App 启动 ========');
    mark('Dart ${_dartVersion()}');
    mark('系统 ${_osVersion()}');
  }

  /// 记录一行日志：内存 + debugPrint + 原生文件（尽力而为，绝不抛异常）。
  static void mark(String message) {
    _lines.add('${_stamp()} $message');
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
    debugPrint('[FeiNiuTV] $message');
    if (_channelUsable) {
      unawaited(_sendToNative(message));
    }
  }

  /// 启动全部完成 —— 通知原生把崩溃计数清零。
  static Future<void> markBootOk() async {
    mark('启动流程完成，清零崩溃计数');
    try {
      await _channel.invokeMethod<void>('markBootOk');
    } catch (_) {
      // 清零失败只影响「下次是否进安全模式」，不影响本次运行。
    }
  }

  /// 读取原生持久化的 deviceId（32 位小写 hex）。
  ///
  /// 走原生 `SharedPreferences` 而非 `flutter_secure_storage`：部分电视 ROM 上
  /// `EncryptedSharedPreferences` 会在**原生层直接崩溃**（Keystore 不可用），
  /// Dart 的 `try/catch` 根本拦不住。而 deviceId 是随机标识、非机密，
  /// 不值得为它冒崩溃风险。
  static Future<String?> nativeDeviceId() async {
    try {
      return await _channel.invokeMethod<String>('deviceId');
    } catch (_) {
      return null;
    }
  }

  static Future<void> _syncWithNative() async {
    try {
      _bootAttempts = await _channel.invokeMethod<int>('bootAttempts') ?? 0;
      _path = await _channel.invokeMethod<String>('logPath') ?? _path;
      mark('原生启动尝试次数 = $_bootAttempts');
      if (safeMode) {
        mark('上次启动未走完 → 本次进入安全模式（跳过原生插件步骤）');
      }
      mark('日志文件 = $_path');
    } catch (e) {
      _channelUsable = false;
      mark('无法连接原生日志通道（$e），日志仅保留在内存');
    }
  }

  static Future<void> _sendToNative(String message) async {
    try {
      await _channel.invokeMethod<void>('log', <String, dynamic>{'msg': message});
    } catch (_) {
      // 通道不可用（例如纯 Dart 测试环境）：降级为仅内存日志。
      _channelUsable = false;
    }
  }

  static String _stamp() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  static String _dartVersion() {
    try {
      return Platform.version.split(' ').first;
    } catch (_) {
      return '(未知)';
    }
  }

  static String _osVersion() {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return '(未知)';
    }
  }
}
