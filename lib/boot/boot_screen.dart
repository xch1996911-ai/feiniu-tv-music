import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../app/theme.dart';
import '../core/boot_log.dart';
import '../core/log.dart';
import '../playback/media_session_service.dart';
import '../playback/playback_engine.dart';
import '../repositories/auth_repository.dart';
import '../repositories/library_repository.dart';
import '../repositories/lyric_repository.dart';
import '../repositories/music_repository.dart';
import '../repositories/playback_repository.dart';

/// 启动引导页 —— **必须是屏幕上最先出现的东西**。
///
/// ## 为什么需要它（真实故障复盘）
///
/// 第一轮：`main()` 在 `runApp` 之前 `await` 了 media session 与安全存储，
/// 任一步抛异常/挂起，`runApp` 就永不执行 ⇒ **纯黑屏、不闪退、零信息**。
///
/// 第二轮（改成同步 `runApp` 之后）：屏幕终于有机会画出来了，但那些初始化
/// 也开始**真的执行**了，于是变成「黑屏 → 闪退」—— 说明崩溃发生在
/// **原生层**（Dart 的 `try/catch` 抓不住 native crash）。
///
/// 所以本页现在的职责是「**取证**」，而不只是「降级」：
/// 1. 每个步骤前后都经 [BootLog] 落盘（原生文件 + 屏幕），
///    崩溃后回看文件即可知道卡在哪一步；
/// 2. 原生侧（`BootTrace`）记录的节点与 Dart 日志写在**同一个文件**里。
///    ⚠️ 但原生装的是 `Thread.setDefaultUncaughtExceptionHandler`，
///    它**只能捕获 Java/Kotlin 异常，不是 native crash 捕获器**：
///    SIGSEGV / SIGABRT / `libflutter.so` / GPU 驱动崩溃不会留下堆栈。
///    因此「日志里没有堆栈」不代表「没有 native crash」；
/// 3. **自动安全模式**：原生记录「连续启动未走完」的次数，达到 2 次时
///    本次跳过 audio_service 与安全存储 —— 优先保证「能看到界面」。
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

  /// 安全模式：上次启动未走完，本次跳过原生插件相关步骤。
  bool _safeMode = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  void _mark(int index, BootStepStatus status, [String? note]) {
    _steps[index].status = status;
    _steps[index].note = note;
    BootLog.mark('步骤${index + 1}/3 ${status.name}'
        '${note == null || note.isEmpty ? '' : ' · $note'}');
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _boot() async {
    _ready = null;
    _fatal = null;
    BootLog.mark('引导流程开始');

    // ── 与原生同步：拿「启动尝试次数」与日志路径。
    //    超时按正常模式继续，不阻断启动。
    try {
      await BootLog.synced.timeout(const Duration(seconds: 5));
    } catch (e) {
      BootLog.mark('与原生日志通道同步超时：$e');
    }
    if (mounted) {
      setState(() => _safeMode = BootLog.safeMode);
    }

    // 先把引导页画出来再去干危险活：电视上没有 adb，
    // 「屏幕上进行到哪一步」是唯一的实时信号。
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // ── 步骤 1：播放引擎。
    //    失败降级为裸 PlaybackHandler（App 内仍可播放，只是没有后台播放与遥控媒体键）。
    BootLog.mark('步骤1/3 开始：播放引擎');
    final handler = await _initAudio();
    if (handler == null) {
      return; // _initAudio 已写好 _fatal 并刷新过界面
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));

    // ── 步骤 2：安全存储 + 会话恢复。失败按「未登录」继续，不阻断启动。
    BootLog.mark('步骤2/3 开始：安全存储 / 恢复会话');
    final auth = AuthRepository();
    if (_safeMode) {
      _mark(1, BootStepStatus.degraded, '安全模式：已跳过安全存储读取，需重新登录');
    } else {
      try {
        await auth.restore().timeout(const Duration(seconds: 12));
        _mark(1, BootStepStatus.ok,
            auth.isLoggedIn ? '已恢复登录态' : '无历史会话，需要登录');
      } catch (e, st) {
        Log.e('恢复会话失败（安全存储不可用？），按未登录继续', e, st);
        _mark(1, BootStepStatus.degraded, '安全存储不可用，已按未登录继续：$e');
      }
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));

    // ── 步骤 3：装配仓库。前两步都可降级，这一步只做内存装配，
    //    失败即视为致命（没有它 App 没有可用页面）。
    BootLog.mark('步骤3/3 开始：装配仓库');
    try {
      final music = MusicRepository(auth);
      final playback = PlaybackRepository(music: music, handler: handler);
      final library = LibraryRepository(music);
      final lyrics = LyricRepository(music);

      // 跨分页连续播放的关键接线：播放队列接近末尾时，让曲库去拉下一页，
      // 并把新曲目追加进队列（appendToQueue 不会移动 currentIndex）。
      playback.attachPrefetch(() async {
        final ok = await library.loadMore();
        if (ok) {
          playback.appendToQueue(library.tracks);
        }
        return ok;
      });

      // 恢复播放模式与上次播放点（**不自动播放**，V2 §14）。
      // 失败一律降级，绝不影响启动。
      try {
        await playback.restoreMode();
        await playback.loadRestorePoint();
      } catch (e) {
        Log.w('播放偏好恢复失败，按默认值继续：$e');
      }

      final app = App(
        auth: auth,
        music: music,
        playback: playback,
        library: library,
        lyrics: lyrics,
      );
      _mark(2, BootStepStatus.ok, null);
      BootLog.mark('引导流程全部完成');
      if (mounted) {
        setState(() => _ready = app);
      }
      unawaited(BootLog.markBootOk());
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
  /// 正常模式：先尝试带 MediaSession 的 handler；失败则退回裸 [PlaybackHandler]。
  /// **两条路径都加超时** ——「永久挂起」与「抛异常」在电视上表现都是黑屏，
  /// 必须一起防住。
  ///
  /// 安全模式：直接走裸 handler，完全不碰 audio_service 的原生代码。
  Future<PlaybackHandler?> _initAudio() async {
    if (_safeMode) {
      BootLog.mark('步骤1/3 安全模式：跳过 audio_service，直接用本地播放引擎');
      try {
        final handler = PlaybackHandler();
        _mark(0, BootStepStatus.degraded,
            '安全模式：本地播放引擎（无后台播放 / 遥控媒体键）');
        return handler;
      } catch (e, st) {
        Log.e('本地播放引擎不可用', e, st);
        _mark(0, BootStepStatus.failed, '$e');
        if (mounted) {
          setState(() => _fatal = '播放引擎初始化失败：$e\n\n$st');
        }
        return null;
      }
    }

    try {
      final handler = await MediaSessionService.init()
          .timeout(const Duration(seconds: 15));
      _mark(0, BootStepStatus.ok, 'MediaSession 已就绪');
      return handler;
    } catch (e, st) {
      Log.e('MediaSession 初始化失败，尝试降级为本地播放引擎', e, st);
      BootLog.mark('步骤1/3 MediaSession 失败，降级：$e');
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
    BootLog.mark('用户点击「重试」');
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
      home: _BootPage(
        steps: _steps,
        fatal: _fatal,
        safeMode: _safeMode,
        onRetry: _retry,
      ),
    );
  }
}

/// 引导界面本体。刻意做得极其「素」：不依赖任何第三方库、
/// 不发起网络请求，保证在任何设备上都能画出来。
class _BootPage extends StatelessWidget {
  const _BootPage({
    required this.steps,
    required this.fatal,
    required this.safeMode,
    required this.onRetry,
  });

  final List<BootStep> steps;
  final String? fatal;
  final bool safeMode;
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
              Text(
                safeMode ? '正在启动…（安全模式）' : '正在启动…',
                style: TextStyle(
                  fontSize: 20,
                  color:
                      safeMode ? const Color(0xFFFFC24B) : Colors.white70,
                ),
              ),
              const SizedBox(height: 28),
              for (final step in steps) _StepRow(step: step),
              const SizedBox(height: 28),
              const _DiagBox(),
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

/// 诊断信息。
///
/// 「黑屏 / 闪退」排错时，这一块是电视端最值钱的东西：
/// - 系统版本立刻暴露是哪个 Android TV；
/// - 启动尝试次数说明是不是「反复崩」；
/// - 日志文件路径告诉用户去哪取证；
/// - 最近日志直接在屏幕上给出「走到哪一步」，拍照即可回传。
class _DiagBox extends StatelessWidget {
  const _DiagBox();

  static const int _tailCount = 14;

  List<String> get _tail {
    final lines = BootLog.lines;
    if (lines.length <= _tailCount) {
      return lines;
    }
    return lines.sublist(lines.length - _tailCount);
  }

  String get _osInfo {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (e) {
      return '(不可用: $e)';
    }
  }

  String get _dartVersion {
    try {
      return Platform.version.split(' ').first;
    } catch (_) {
      return '(未知)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tail = _tail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Dart $_dartVersion\n'
          '系统 $_osInfo\n'
          '启动尝试 ${BootLog.bootAttempts} 次'
          '${BootLog.safeMode ? '（已达安全模式阈值）' : ''}\n'
          '日志文件 ${BootLog.path}',
          style:
              const TextStyle(fontSize: 15, color: Colors.white38, height: 1.6),
        ),
        const SizedBox(height: 18),
        const Text('最近启动日志',
            style: TextStyle(fontSize: 16, color: Colors.white54)),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF101018),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            tail.isEmpty ? '(暂无)' : tail.join('\n'),
            style: const TextStyle(
              fontSize: 14,
              height: 1.5,
              fontFamily: 'monospace',
              color: Color(0xFF9FE8B5),
            ),
          ),
        ),
      ],
    );
  }
}
