import 'dart:async';

import 'package:flutter/services.dart';

import '../core/boot_log.dart';
import '../core/log.dart';

/// 「离开应用」的两个 Android 动作（V5 补充任务）。
///
/// ## 为什么走自建通道而不是现有插件
///
/// 本项目已有一条经过实机验证的原生通道 `feiniu/boot`
/// （见 `MainActivity.kt` 与 `LocalPaths` 的说明）—— 加两个方法即可，
/// 不为两个一行的小动作引入新插件（每多一个带原生实现的依赖，
/// 就多一份「在某个电视 ROM 上插件注册失败」的风险，而本机没有 adb）。
///
/// ## 两个动作的语义边界
///
/// - [moveToBackground]：只把 Activity/task 退到后台
///   （`Activity.moveTaskToBack(true)`）。**不** pause、**不** stop、
///   **不** dispose 任何播放资源 —— audio_service 的前台服务本来就不依赖
///   Activity 在前台，音频继续播，媒体键继续可用。
/// - [exitApp]：`finishAndRemoveTask()` 结束 Activity。
///   调用方必须**先**完成业务清理（停音源 / 停 MediaSession 会话 /
///   停遥控服务），再调用本方法 —— 顺序由 `app_shell._exitAndStop()` 保证。
///
/// ## 系统 Home 键的边界（如实说明）
///
/// 电视系统的 Home 键由系统 Launcher 处理，应用**收不到**该按键事件
/// （除非申请默认桌面权限，任务书明确禁止）。所以本功能只覆盖
/// 「App 内可控的离开入口」：首页按返回键 / 侧栏「返回桌面」入口。
///
/// ## 测试注入
///
/// 测试里用 Flutter 官方的假通道机制即可断言调用
/// （`TestDefaultBinaryMessengerBinding.defaultBinaryMessenger
///   .setMockMethodCallHandler(const MethodChannel('feiniu/boot'), ...)`），
/// 本类不为此提供任何钩子 —— `flutter_test` 不能出现在 `lib/` 里。
class AppExit {
  AppExit._();

  static const MethodChannel _channel = MethodChannel('feiniu/boot');

  /// 把应用退到后台（音频继续播放）。失败时静默 ——
  /// 「退到后台」失败不该产生任何用户可见的错误。
  static Future<void> moveToBackground() async {
    try {
      await _channel
          .invokeMethod<bool>('moveTaskToBack')
          .timeout(const Duration(seconds: 5));
      BootLog.mark('已退到后台（播放继续）');
    } catch (e) {
      // 测试环境没有平台通道；部分 ROM 上 moveTaskToBack 可能被系统拒绝。
      Log.w('MOVE_TO_BACKGROUND 失败（忽略）：$e');
    }
  }

  /// 结束 Activity（调用方须先完成播放/服务清理）。
  ///
  /// 通道失败时兜底 `SystemNavigator.pop()`（Flutter 官方的退出方式，
  /// 在 Android 上等价于 `finish()`），保证「退出」动作总是可达。
  static Future<void> exitApp() async {
    try {
      await _channel
          .invokeMethod<void>('exitApp')
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      Log.w('EXIT_APP 通道失败，退回 SystemNavigator.pop：$e');
      await SystemNavigator.pop().timeout(
            const Duration(seconds: 5),
            onTimeout: () => Log.w('EXIT_APP SystemNavigator 也超时（放弃重试）'),
          );
    }
  }
}
