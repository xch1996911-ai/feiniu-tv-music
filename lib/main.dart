import 'dart:async';

import 'package:flutter/material.dart';

import 'boot/boot_screen.dart';
import 'core/boot_log.dart';

/// 应用入口。
///
/// ## 铁律：`runApp` 之前不允许出现任何 `await`
///
/// 真实故障复盘（Android TV 安装后点开**纯黑屏，什么都不显示**）：
/// 旧版 `main()` 在这里 `await` 了两步初始化：
///
/// ```dart
/// final handler = await MediaSessionService.init(); // audio_service 起前台服务
/// await auth.restore();                             // flutter_secure_storage / Keystore
/// runApp(App(...));
/// ```
///
/// 这两步在电视盒子上都不可靠（Keystore 不可用、前台服务被 ROM 拒绝、
/// 或服务绑定不回调导致永久挂起）。任一步出问题，`runApp` 就永远不执行；
/// 而启动窗口背景原先是纯黑，于是屏幕上**只有一片黑，连报错都没有**。
///
/// 现在的写法：
/// 1. 同步 `runApp(const BootApp())`，屏幕立刻有内容（引导页）；
/// 2. 初始化全部下沉到 [BootApp]，逐步 try/catch + 超时，可降级；
/// 3. 失败原因直接画在屏幕上，电视端无需 adb 也能取证；
/// 4. [BootLog] 把每个节点同步落盘到原生文件 —— 黑屏/闪退后仍可回看。
///
/// `runZonedGuarded` 是最后一道兜底：任何逃逸到 Zone 顶层的异步异常
/// 都会写进日志，而不是被静默吞掉。
void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();

      // 同步启动日志（内部不 await 原生成败）。必须在 runApp 之前，
      // 这样即使后续崩在引擎/插件层，日志里也已经有 Dart 启动的痕迹。
      BootLog.start();

      // 启动路径必须留下逐点痕迹，否则在无 adb 的电视上无法区分
      // 「Dart 没跑起来」「runApp 没执行」「第一帧没画出来」这三种完全不同的故障。
      BootLog.mark('Dart main() entered');

      // 把框架内部错误也接出来，避免「界面白了/黑了但控制台什么都没有」。
      FlutterError.onError = (FlutterErrorDetails details) {
        BootLog.mark('FlutterError: ${details.exceptionAsString()}');
        FlutterError.presentError(details);
      };

      BootLog.mark('runApp before');
      runApp(const BootApp());
      BootLog.mark('runApp after');

      // 「runApp 被调用」≠「第一帧已经交出去」。首帧回调才是渲染真正开始的证据：
      // 日志里有 `runApp after` 却没有 `first frame callback`
      // ⇒ 卡在引擎 / 渲染层，与业务代码无关。
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        BootLog.mark('first frame callback');
      });
    },
    (Object error, StackTrace stack) {
      BootLog.mark('未捕获异常: $error\n$stack');
      debugPrint('[FeiNiuTV] 未捕获异常: $error\n$stack');
    },
  );
}
