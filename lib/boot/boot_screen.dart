import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../app/theme.dart';
import '../core/boot_log.dart';
import '../core/branding.dart';
import '../core/diagnostics.dart';
import '../core/log.dart';
import '../playback/media_session_service.dart';
import '../playback/playback_engine.dart';
import '../repositories/auth_repository.dart';
import '../repositories/library_repository.dart';
import '../repositories/local_library_repository.dart';
import '../repositories/lyric_repository.dart';
import '../repositories/music_repository.dart';
import '../repositories/playback_repository.dart';
import '../services/online_lyric_source.dart';
import '../ui/pages/diagnostics_page.dart';
import '../ui/widgets/tv_focus.dart';
import '../ui/widgets/tv_glass.dart';

/// 启动引导 —— **必须是屏幕上最先出现的东西**。
///
/// ## 为什么仍然需要「先画 UI，再干活」
///
/// 第一轮：`main()` 在 `runApp` 之前 `await` 了 media session 与安全存储，
/// 任一步抛异常/挂起，`runApp` 就永不执行 ⇒ **纯黑屏、不闪退、零信息**。
///
/// 第二轮（改成同步 `runApp` 之后）：屏幕有机会画出来了，但那些初始化
/// 也开始真的执行，于是变成「黑屏 → 闪退」—— 崩溃发生在**原生层**。
///
/// 所以骨架不变：同步 `runApp` → 立刻画出界面 → 初始化逐步 try/catch + 超时。
/// 每一步都经 [BootLog] 落盘，崩溃后回看文件即可知道卡在哪一步。
///
/// ## V5 的关键变化：**正常流程不再显示诊断界面**
///
/// V4 把这个引导页做成了「取证屏」：步骤清单 + 系统版本 + Dart 版本 +
/// 日志尾部全文印在屏幕上（实机截图里就是一大片技术文字）。
/// 对用户来说，正常启动看到这些只有一个感受 —— **这软件好像坏了**。
///
/// V5 拆成两件事：
/// - **用户看到的**：一个简洁短暂的加载画面（品牌标识 + 名称 + 细进度条
///   + 一句人话状态），恢复登录态后直接进首页；需要重新登录就进登录页。
/// - **排错需要的**：全部登记到 [Diagnostics]，从右下角「诊断」按钮进入
///   （或侧栏底部「诊断与帮助」），仍然包含日志文件路径与日志尾部。
///
/// 只有**致命失败**（连仓库都装配不起来，App 没有任何可用页面）才会在
/// 启动画面上显示一句简短、可操作的错误 + 重试按钮；原始堆栈只进诊断页。
class BootApp extends StatefulWidget {
  const BootApp({super.key});

  @override
  State<BootApp> createState() => _BootAppState();
}

/// 单个初始化步骤的状态。
enum BootStepStatus { running, ok, degraded, failed }

/// 单个初始化步骤。
///
/// [title] 是给用户看的人话（会短暂出现在启动画面上），
/// 技术细节写在 [note] 里并**只**登记到诊断。
class BootStep {
  BootStep(this.title);

  final String title;
  BootStepStatus status = BootStepStatus.running;
  String? note;
}

class _BootAppState extends State<BootApp> {
  final List<BootStep> _steps = <BootStep>[
    BootStep('正在启动播放服务…'),
    BootStep('正在恢复登录状态…'),
    BootStep('正在准备曲库…'),
  ];

  /// 初始化全部完成后置位，届时本页被真实 App 替换。
  App? _ready;

  /// 致命错误（无法继续启动）。只显示最后一行「人话」，堆栈进诊断。
  String? _fatal;

  /// 安全模式：上次启动未走完，本次跳过原生插件相关步骤。
  bool _safeMode = false;

  /// 用户是否主动打开了诊断页（从启动画面进入）。
  bool _showDiagnostics = false;

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
    _showDiagnostics = false;
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
    // 「屏幕上停在哪一步」是唯一的实时信号（现在是无声的，但不卡死更重要）。
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // ── 步骤 1：播放引擎。
    //    失败降级为裸 PlaybackHandler（App 内仍可播放，只是没有后台播放与遥控媒体键）。
    BootLog.mark('步骤1/3 开始：播放引擎');
    final handler = await _initAudio();
    if (handler == null) {
      return; // _initAudio 已写好 _fatal 并刷新过界面
    }

    await Future<void>.delayed(const Duration(milliseconds: 200));

    // ── 步骤 2：安全存储 + 会话恢复。失败按「未登录」继续，不阻断启动。
    BootLog.mark('步骤2/3 开始：安全存储 / 恢复会话');
    final auth = AuthRepository();
    if (_safeMode) {
      _mark(1, BootStepStatus.degraded, '安全模式：已跳过安全存储读取，需重新登录');
      Diagnostics.note('登录会话', '安全模式：已跳过读取，需要重新登录');
    } else {
      try {
        await auth.restore().timeout(const Duration(seconds: 12));
        _mark(1, BootStepStatus.ok,
            auth.isLoggedIn ? '已恢复登录态' : '无历史会话，需要登录');
        Diagnostics.note('登录会话',
            auth.isLoggedIn ? '已恢复登录态（启动时自动恢复）' : '无历史会话，等待登录');
      } catch (e, st) {
        Log.e('恢复会话失败（安全存储不可用？），按未登录继续', e, st);
        _mark(1, BootStepStatus.degraded, '安全存储不可用，已按未登录继续：$e');
        Diagnostics.note('登录会话', '安全存储读取失败，按未登录继续：$e');
      }
    }

    await Future<void>.delayed(const Duration(milliseconds: 200));

    // ── 步骤 3：装配仓库。前两步都可降级，这一步只做内存装配，
    //    失败即视为致命（没有它 App 没有可用页面）。
    BootLog.mark('步骤3/3 开始：装配仓库');
    try {
      final music = MusicRepository(auth);
      final playback = PlaybackRepository(music: music, handler: handler);
      final library = LibraryRepository(music);
      // 歌词：NAS 优先；NAS 没有/失败/为空时才走 LRCLIB 在线兜底
      // （免密钥，符合「密钥不得硬编码」的红线）。
      // ⚠️ 只在这里注入 —— 测试里不传 online 时 `_online == null`，
      //    因此既有的歌词测试**不会**打真实网络。
      final lyrics = LyricRepository(music, online: LrclibLyricSource());
      final local = LocalLibraryRepository();

      // 用户手动风格 ↔ 曲库归纳的**双向接线**：
      // 曲库层读「用户指定」，用户改完反过来触发重算。
      // 用回调而不是互相持有引用：数据层之间不该有硬依赖。
      library.attachGenreOverrides(() => local.genreOverrides);
      local.onGenreOverrideChanged = library.refreshGenres;

      // 跨分页连续播放的关键接线：播放队列接近末尾时，让曲库去拉下一页，
      // 并把新曲目追加进队列（appendToQueue 不会移动 currentIndex）。
      playback.attachPrefetch(() async {
        final ok = await library.loadMore();
        if (ok) {
          playback.appendToQueue(library.tracks);
        }
        return ok;
      });

      // 恢复播放模式、上次播放点（**不自动播放**）与本机收听历史。
      // 全部失败一律降级，绝不影响启动。
      try {
        await playback.restoreMode();
        await playback.loadRestorePoint();
        await local.restore();
      } catch (e) {
        Log.w('本机偏好恢复失败，按默认值继续：$e');
      }

      // 全曲库整理：**登录恢复后立即开始，不要求用户先打开音乐库**
      // （需求 §三-B.1 / §三-B.2 —— 这正是「不点音乐库就只有 50 首」的修复点）。
      // 刻意 **不 await**：先读本地索引那一刻极快，全量核对则放后台，
      // 进度通过 LibraryRepository.syncStatus 暴露给首页与概览页。
      if (auth.isLoggedIn) {
        unawaited(library.startSync(auth.catalogueIdentity));
      }

      final app = App(
        auth: auth,
        music: music,
        playback: playback,
        library: library,
        lyrics: lyrics,
        local: local,
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
      Diagnostics.event('仓库装配失败：$e');
      if (mounted) {
        setState(() => _fatal = e.toString());
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
  ///
  /// ⚠️ **降级不再出现在启动画面上**：它是「可选能力缺失」而不是
  /// 「用户需要处理的问题」，只登记到诊断。前台播放本身不受影响。
  Future<PlaybackHandler?> _initAudio() async {
    if (_safeMode) {
      BootLog.mark('步骤1/3 安全模式：跳过 audio_service，直接用本地播放引擎');
      try {
        final handler = PlaybackHandler();
        _mark(0, BootStepStatus.degraded, '安全模式：本地播放引擎');
        Diagnostics.note('媒体会话',
            '安全模式：本次跳过 audio_service（上次启动未走完），无后台播放 / 遥控媒体键');
        return handler;
      } catch (e, st) {
        Log.e('本地播放引擎不可用', e, st);
        _mark(0, BootStepStatus.failed, '$e');
        Diagnostics.event('本地播放引擎初始化失败：$e');
        if (mounted) {
          setState(() => _fatal = e.toString());
        }
        return null;
      }
    }

    try {
      final handler = await MediaSessionService.init()
          .timeout(const Duration(seconds: 15));
      _mark(0, BootStepStatus.ok, 'MediaSession 已就绪');
      Diagnostics.note('媒体会话', '已就绪（后台播放 + 遥控媒体键可用）');
      return handler;
    } catch (e, st) {
      Log.e('MediaSession 初始化失败，尝试降级为本地播放引擎', e, st);
      BootLog.mark('步骤1/3 MediaSession 失败，降级：$e');
      Diagnostics.event('MediaSession 初始化失败：$e');
      try {
        final handler = PlaybackHandler();
        _mark(0, BootStepStatus.degraded, '已降级为本地播放');
        Diagnostics.note(
            '媒体会话', '初始化失败，已降级为本地播放（无后台播放 / 遥控媒体键）：$e');
        return handler;
      } catch (e2, st2) {
        Log.e('本地播放引擎也不可用', e2, st2);
        _mark(0, BootStepStatus.failed, '$e2');
        Diagnostics.event('本地播放引擎初始化失败：$e2');
        if (mounted) {
          setState(() => _fatal = e2.toString());
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
      _showDiagnostics = false;
    });
    unawaited(_boot());
  }

  /// 当前应该显示的人话状态：取第一个「正在运行」的步骤标题。
  String get _statusText {
    for (final BootStep s in _steps) {
      if (s.status == BootStepStatus.running) return s.title;
    }
    return '正在启动…';
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    if (ready != null) {
      return ready;
    }
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: buildTvTheme(),
      home: _showDiagnostics
          ? const Scaffold(
              backgroundColor: TvColors.bg,
              body: SafeArea(
                child: Padding(
                  padding: EdgeInsets.all(48),
                  child: DiagnosticsPage(embedded: true),
                ),
              ),
            )
          : _SplashPage(
              status: _fatal != null ? '启动遇到问题' : _statusText,
              fatal: _fatal,
              onRetry: _retry,
              onDiagnostics: () => setState(() => _showDiagnostics = true),
            ),
    );
  }
}

/// 启动画面本体。刻意做得极其「素」：不依赖任何第三方库、不发起网络请求，
/// 保证在任何设备上都能画出来。
///
/// 布局只有三块：品牌标识 + 名称标语、细进度条 + 一句状态、
/// 右下角「诊断」。**没有任何技术文字**。
class _SplashPage extends StatelessWidget {
  const _SplashPage({
    required this.status,
    required this.fatal,
    required this.onRetry,
    required this.onDiagnostics,
  });

  final String status;
  final String? fatal;
  final VoidCallback onRetry;
  final VoidCallback onDiagnostics;

  @override
  Widget build(BuildContext context) {
    final String? error = fatal;
    return Scaffold(
      backgroundColor: TvColors.bg,
      body: Stack(
        children: <Widget>[
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    const _BrandMark(),
                    const SizedBox(height: 26),
                    const Text(
                      kAppName,
                      style: TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      kAppTagline,
                      style: TextStyle(fontSize: 17, color: TvColors.textFaint),
                    ),
                    const SizedBox(height: 44),
                    if (error == null) ...<Widget>[
                      SizedBox(
                        width: 260,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: const LinearProgressIndicator(
                            minHeight: 3,
                            backgroundColor: TvColors.line,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                TvColors.accent),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        status,
                        style: const TextStyle(
                            fontSize: 18, color: TvColors.textDim),
                      ),
                    ] else ...<Widget>[
                      // 只有**致命**失败才在启动画面显示错误。
                      // 文案刻意短、可操作；原始异常在诊断页。
                      const Icon(Icons.error_outline,
                          size: 40, color: TvColors.warn),
                      const SizedBox(height: 14),
                      const Text(
                        '启动没有完成，可以从「诊断」看到原因。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 19, color: TvColors.text, height: 1.4),
                      ),
                      const SizedBox(height: 22),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          TvFocus(
                            debugLabel: 'boot.retry',
                            autofocus: true,
                            onPressed: onRetry,
                            builder: (BuildContext c, TvFocusStatus s) =>
                                TvFocusRing(
                              status: s,
                              radius: 999,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 26, vertical: 12),
                              child: const Text('重试',
                                  style: TextStyle(fontSize: 20)),
                            ),
                          ),
                          const SizedBox(width: 18),
                          TvFocus(
                            debugLabel: 'boot.diag',
                            onPressed: onDiagnostics,
                            builder: (BuildContext c, TvFocusStatus s) =>
                                TvFocusRing(
                              status: s,
                              radius: 999,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 26, vertical: 12),
                              child: const Text('看诊断',
                                  style: TextStyle(fontSize: 20)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // 正常流程下「诊断」只是一个不打扰的角落入口：
          // 不抢焦点、不占内容区、没有技术文字。
          Positioned(
            right: 32,
            bottom: 28,
            child: TvFocus(
              debugLabel: 'boot.diagnostics',
              autofocus: error != null,
              onPressed: onDiagnostics,
              builder: (BuildContext c, TvFocusStatus s) => TvFocusRing(
                status: s,
                radius: 999,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.info_outline,
                        size: 17, color: TvColors.textFaint),
                    SizedBox(width: 6),
                    Text('诊断',
                        style: TextStyle(
                            fontSize: 15, color: TvColors.textFaint)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 品牌标识：圆角方块 + 音符。不依赖任何图片资源（避免 asset 缺失导致
/// 启动画面是空白 —— 那正是最需要看到东西的时候）。
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return TvGlass(
      radius: 24,
      padding: const EdgeInsets.all(18),
      width: 92,
      height: 92,
      child: const Icon(Icons.music_note, size: 48, color: TvColors.brand),
    );
  }
}
