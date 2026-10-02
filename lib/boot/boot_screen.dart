import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../app/theme.dart';
import '../core/log.dart';
import '../playback/media_session_service.dart';
import '../playback/playback_engine.dart';
import '../repositories/auth_repository.dart';
import '../repositories/music_repository.dart';
import '../repositories/playback_repository.dart';

/// 启动引导页 —— **必须是屏幕上最先出现的东西**。
///
/// ## 为什么需要它（真实故障复盘）
///
/// 旧版 `main()` 是这样写的：
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   final handler = await MediaSessionService.init();   // ← 可能抛异常 / 永久挂起
///   final auth = AuthRepository();
///   await auth.restore();                              // ← 可能抛异常
///   runApp(App(...));
/// }
/// ```
/// 在 Android TV 盒子上这两步都不可靠：
/// - `auth.restore()` → `flutter_secure_storage` → Android Keystore，
///   部分电视/盒子 ROM 的 Keystore 不可用，直接抛异常；
/// - `MediaSessionService.init()` → `audio_service` 要起前台服务，
///   厂商 ROM 可能拒绝，或绑定一直不回调（既不抛错也不完成）。
///
/// 任一种情况发生，`runApp` 就**永远不执行**；而
/// `android/app/src/main/res/drawable/launch_background.xml` 是纯黑，
/// 于是屏幕上表现为「安装后点开直接黑屏，什么都不显示」，
/// 且电视上通常没有 adb，拿不到任何错误信息。
///
/// ## 现在的策略
///
/// 1. `main()` 里**同步** `runApp(const BootApp())`，屏幕立刻有内容；
/// 2. 三步初始化在本页内异步执行，**每步独立 try/catch + 超时**：
///    能降级就降级（MediaSession 失败 → 退回本地播放引擎；
///    安全存储失败 → 按未登录继续），不因为一个可选能力拖死整个 App；
/// 3. 任何失败都**画在屏幕上**（含异常原文与堆栈），电视端可以直接拍照取证；
/// 4. 同时打印环境信息（Dart 版本 / 系统版本），便于判断是否是 ROM 兼容问题。
class BootApp extends StatefulWidget {
  const BootApp({super.key});

  @override
  State<BootApp> createState() => _BootAppState();
}

/// 单个初始化步骤的状态。
enum BootStepStatus { running, ok, degraded, failed }

/// 单个初始化步骤。
class BootStep {
  BootStep(this.title);

  final String title;
  BootStepStatus status = BootStepStatus.running;
  String? note;
}

class _BootAppState extends State<BootApp> {
  final List<BootStep> _steps = <BootStep>[
    BootStep('初始化媒体会话（audio_service / MediaSession）'),
    BootStep('读取设备标识并恢复登录会话（安全存储）'),
    BootStep('装配播放与数据仓库'),
  ];

  /// 初始化全部完成后置位，届时本页被真实 App 替换。
  App? _ready;

  /// 致命错误（无法继续启动）。显示在屏幕上供电视端取证。
  String? _fatal;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  void _mark(int index, BootStepStatus status, [String? note]) {
    _steps[index].status = status;
    _steps[index].note = note;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _boot() async {
    _ready = null;
    _fatal = null;

    // ── 步骤 1：媒体会话。失败降级为本地播放引擎
    //    （App 内仍可正常播放，只是没有后台播放与遥控媒体键）。
    final handler = await _initAudio();
    if (handler == null) {
      return; // _initAudio 已写好 _fatal 并刷新过界面
    }

    // ── 步骤 2：安全存储 + 会话恢复。失败按「未登录」继续，不阻断启动。
    final auth = AuthRepository();
    try {
      await auth.restore().timeout(const Duration(seconds: 12));
      _mark(1, BootStepStatus.ok, auth.isLoggedIn ? '已恢复登录态' : '无历史会话，需要登录');
    } catch (e, st) {
      Log.e('恢复会话失败（安全存储不可用？），按未登录继续', e, st);
      _mark(1, BootStepStatus.degraded, '安全存储不可用，已按未登录继续：$e');
    }

    // ── 步骤 3：装配仓库。前两步都可降级，这一步只做内存装配，
    //    失败即视为致命（没有它 App 没有可用页面）。
    try {
      final music = MusicRepository(auth);
      final playback = PlaybackRepository(music: music, handler: handler);
      final app = App(auth: auth, music: music, playback: playback);
      _mark(2, BootStepStatus.ok, null);
      if (mounted) {
        setState(() => _ready = app);
      }
    } catch (e, st) {
      Log.e('仓库装配失败', e, st);
      _mark(2, BootStepStatus.failed, '$e');
      if (mounted) {
        setState(() => _fatal = '装配播放/数据仓库失败：$e\n\n$st');
      }
    }
  }

  /// 初始化播放引擎。返回 null 表示彻底失败（已写入 [_fatal]）。
  ///
  /// 先尝试带 MediaSession 的 handler；失败则退回裸 [PlaybackHandler]。
  /// **两条路径都加超时** ——「永久挂起」与「抛异常」在电视上表现都是黑屏，
  /// 必须一起防住。
  Future<PlaybackHandler?> _initAudio() async {
    try {
      final handler = await MediaSessionService.init()
          .timeout(const Duration(seconds: 15));
      _mark(0, BootStepStatus.ok, 'MediaSession 已就绪');
      return handler;
    } catch (e, st) {
      Log.e('MediaSession 初始化失败，尝试降级为本地播放引擎', e, st);
      try {
        final handler = PlaybackHandler();
        _mark(0, BootStepStatus.degraded,
            '已降级为本地播放（无后台播放 / 遥控媒体键）：$e');
        return handler;
      } catch (e2, st2) {
        Log.e('本地播放引擎也不可用', e2, st2);
        _mark(0, BootStepStatus.failed, '$e2');
        if (mounted) {
          setState(() => _fatal = '播放引擎初始化失败：$e2\n\n$st2');
        }
        return null;
      }
    }
  }

  void _retry() {
    for (final step in _steps) {
      step.status = BootStepStatus.running;
      step.note = null;
    }
    setState(() {
      _ready = null;
      _fatal = null;
    });
    unawaited(_boot());
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    if (ready != null) {
      return ready;
    }
    return MaterialApp(
      title: '飞牛 TV 音乐',
      debugShowCheckedModeBanner: false,
      theme: buildTvTheme(),
      home: _BootPage(steps: _steps, fatal: _fatal, onRetry: _retry),
    );
  }
}

/// 引导界面本体。刻意做得极其「素」：不依赖任何第三方库、
/// 不发起网络请求，保证在任何设备上都能画出来。
class _BootPage extends StatelessWidget {
  const _BootPage({
    required this.steps,
    required this.fatal,
    required this.onRetry,
  });

  final List<BootStep> steps;
  final String? fatal;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final fatalText = fatal;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('飞牛 TV 音乐',
                  style: TextStyle(fontSize: 40, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text('正在启动…',
                  style: TextStyle(fontSize: 20, color: Colors.white70)),
              const SizedBox(height: 28),
              for (final step in steps) _StepRow(step: step),
              const SizedBox(height: 28),
              const _EnvBox(),
              if (fatalText != null) ...<Widget>[
                const SizedBox(height: 28),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A1216),
                    // 注意：Border.all 在当前 Flutter 版本不是 const 构造器，
                    // 加 const 会报 const_with_non_const。
                    border: Border.all(color: const Color(0xFFFF5A5F), width: 2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        '启动失败',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFFF8A8F),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SelectableText(fatalText,
                          style: const TextStyle(fontSize: 18, height: 1.5)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  autofocus: true,
                  onPressed: onRetry,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 36, vertical: 16),
                  ),
                  child: const Text('重试', style: TextStyle(fontSize: 22)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final BootStep step;

  String get _icon {
    switch (step.status) {
      case BootStepStatus.running:
        return '…';
      case BootStepStatus.ok:
        return 'OK';
      case BootStepStatus.degraded:
        return '!';
      case BootStepStatus.failed:
        return 'X';
    }
  }

  Color get _color {
    switch (step.status) {
      case BootStepStatus.running:
        return Colors.white54;
      case BootStepStatus.ok:
        return const Color(0xFF54D68A);
      case BootStepStatus.degraded:
        return const Color(0xFFFFC24B);
      case BootStepStatus.failed:
        return const Color(0xFFFF5A5F);
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = step.note;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 46,
                child: Text(_icon,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: _color)),
              ),
              Expanded(
                child: Text(step.title,
                    style: TextStyle(fontSize: 22, color: _color)),
              ),
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(left: 46, top: 6),
              child: Text(
                note,
                style: const TextStyle(
                    fontSize: 17, color: Colors.white70, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// 环境信息。黑白屏排错时这些数字是最有用的第一手线索
/// （例如系统版本能立刻暴露是哪个 Android TV 版本）。
class _EnvBox extends StatelessWidget {
  const _EnvBox();

  String get _osInfo {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (e) {
      return '(不可用: $e)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      'Dart ${Platform.version.split(' ').first}\n系统 $_osInfo',
      style: const TextStyle(fontSize: 15, color: Colors.white38, height: 1.6),
    );
  }
}
