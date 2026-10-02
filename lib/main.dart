import 'dart:async';

import 'package:flutter/material.dart';

import 'boot/boot_screen.dart';

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
/// 而启动窗口背景是纯黑，于是屏幕上**只有一片黑，连报错都没有**。
///
/// 现在的写法：
/// 1. 同步 `runApp(const BootApp())`，屏幕立刻有内容（引导页）；
/// 2. 初始化全部下沉到 [BootApp]，逐步 try/catch + 超时，可降级；
/// 3. 失败原因直接画在屏幕上，电视端无需 adb 也能取证。
///
/// `runZonedGuarded` 是最后一道兜底：任何逃逸到 Zone 顶层的异步异常
/// 都会被打印出来，而不是被静默吞掉。
void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();

      // 把框架内部错误也接出来，避免「界面白了/黑了但控制台什么都没有」。
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        debugPrint('[FeiNiuTV] FlutterError: ${details.exceptionAsString()}');
      };

      runApp(const BootApp());
    },
    (Object error, StackTrace stack) {
      debugPrint('[FeiNiuTV] 未捕获异常: $error\n$stack');
    },
  );
}
