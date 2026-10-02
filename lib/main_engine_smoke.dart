// 引擎冒烟测试入口 —— **不是业务入口**。
//
// 用途：在一台「疑似连 Flutter 第一帧都画不出来」的电视（海信 E7N Pro / VIDDA）
// 上，把「Flutter 引擎 + 渲染后端」从「业务代码 + 插件」里彻底剥离出来单独验证。
//
// 硬约束（刻意为之，不要为了「顺便多做点事」而破坏它）：
//   · 只依赖 Flutter SDK（material / services），不 import 任何第三方包；
//   · 不 import BootLog —— 业务侧的启动日志初始化本身就是可疑点之一；
//   · 不碰飞牛 API / Provider / audio_service / just_audio /
//     flutter_secure_storage / 网络 / Repository / MediaSession；
//   · 屏幕上只回答一个问题：这台电视能不能显示 Flutter 的第一帧。
//
// 运行方式（CI 里由 tools/diag/make_variant.py 驱动）：
//   flutter build apk --debug -t lib/main_engine_smoke.dart
//
// 结果判读：
//   能看到 "FLUTTER ENGINE OK" ⇒ 引擎与渲染链路正常，问题在业务/插件/启动时序；
//   仍是深蓝一片或直接闪退 ⇒ 问题在引擎/渲染/ABI 层，与业务代码无关。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 诊断标签，由 `--dart-define=DIAG_TAG=xxx` 注入，用于在电视上区分是哪个 APK。
const String kDiagTag =
    String.fromEnvironment('DIAG_TAG', defaultValue: 'engine-smoke');

/// 与原生共用的取证通道（`MainActivity` / `DiagSmokeActivity` 都注册它）。
///
/// 注意：MethodChannel **不是插件**，注册它不经过 GeneratedPluginRegistrant，
/// 因此在「不注册任何插件」的诊断版本里依然可用。
const MethodChannel _traceChannel = MethodChannel('feiniu/boot');

/// 落盘一行启动痕迹。
///
/// 刻意「发完就走」：不 `await`，也不让它有机会抛异常影响渲染 ——
/// 本入口连日志都不能成为新的失败点，所以异常一律吞掉。
void _mark(String message) {
  try {
    _traceChannel
        .invokeMethod<void>('log', <String, dynamic>{'msg': '[smoke] $message'})
        .catchError((Object _) {});
  } catch (_) {
    // 通道不可用（例如纯 Dart 测试环境）不影响冒烟测试本身。
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _mark('Dart main() entered');
  _mark('DIAG_TAG=$kDiagTag');
  _mark('runApp before');
  runApp(const EngineSmokeApp());
  _mark('runApp after');
}

/// 冒烟页：深蓝底 + 一行大字，刻意做到「不可能画不出来」的程度。
class EngineSmokeApp extends StatefulWidget {
  const EngineSmokeApp({super.key, this.maxFrames = 5});

  /// 最多渲染多少帧后停下。
  ///
  /// 要**多帧**而不是一帧：把「只有第一帧能画、后续 GPU 就挂」这种情况也区分出来。
  /// 又必须**停下**：否则测试环境里会一直刷帧、日志爆掉。
  final int maxFrames;

  @override
  State<EngineSmokeApp> createState() => _EngineSmokeAppState();
}

class _EngineSmokeAppState extends State<EngineSmokeApp> {
  int _frames = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_onFrame);
  }

  void _onFrame(Duration _) {
    if (!mounted) {
      return;
    }
    _frames++;
    _mark(_frames == 1 ? 'first frame callback' : 'frame $_frames rendered');
    setState(() {});
    if (_frames < widget.maxFrames) {
      WidgetsBinding.instance.addPostFrameCallback(_onFrame);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF14213D),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Text(
                'FLUTTER ENGINE OK',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'DIAG_TAG=$kDiagTag\n已渲染 $_frames 帧',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
