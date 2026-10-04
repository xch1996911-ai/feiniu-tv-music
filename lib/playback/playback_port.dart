import 'package:audio_service/audio_service.dart';

/// 播放引擎对「播放编排层」暴露的最小能力集。
///
/// ## 为什么要抽这一层接口
///
/// [PlaybackHandler] 内部 `AudioPlayer()` 依赖真实 Android 平台（ExoPlayer / AVPlayer），
/// 在纯 Dart 单元测试里**无法实例化**。而队列语义（自动下一首、失效跳过、
/// 快速切歌竞态、边界）是本项目最需要回归保护的部分，不能依赖真机才能验证。
///
/// 抽出接口后：生产路径仍走 [PlaybackHandler]（行为完全不变），
/// 测试路径换成 `FakePlaybackEngine`（见 `test/support/fake_playback_engine.dart`），
/// **不联网、不碰平台通道**即可断言队列行为。
///
/// 职责边界不变：本接口只管「播这一首 URL」，队列与模式逻辑全在 `PlaybackRepository`。
abstract class PlaybackEngine {
  /// 播放状态变化流（供 UI 刷新）。**不承载业务语义**，仅用于通知。
  Stream<void> get stateChanges;

  /// 播放位置流（进度条）。
  Stream<Duration> get positionStream;

  bool get isPlaying;

  Duration? get position;

  Duration? get duration;

  /// 加载并播放一首歌。headers 携带认证（如 Cookie）。
  Future<void> loadAndPlay({
    required String url,
    required Map<String, String> headers,
    required MediaItem item,
  });

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> stop();

  /// 「退出应用」专用：停音源，**并结束 MediaSession 的前台会话**。
  ///
  /// ⚠️ 与 [stop] 的区别是本项目一个真实的坑：audio_service 0.18 的
  /// `BaseAudioHandler.stop()` 默认是**空操作**，前台服务进入 `stopped`
  /// 状态由「`processingState` 变为 `idle`」驱动 —— 只调 `_player.stop()`
  /// 而不广播 idle，媒体通知 / 前台服务会一直挂着。
  /// 平时的「停止播放」继续用 [stop]（MediaSession 保留，媒体键仍可用）；
  /// 只有用户明确选择「退出并停止播放」才走本方法。
  Future<void> stopSession();

  /// 注入队列控制回调（由 `PlaybackRepository` 在构造时注册）。
  ///
  /// 这样 MediaSession 的传输键与页面按钮最终都落到**同一个** `PlaybackRepository`，
  /// 不会形成两套队列状态。
  set commandListener(PlaybackCommandListener listener);
}

/// 引擎 → 编排层的控制回调。
///
/// 单独成接口是为了打断「引擎 ↔ 仓储」的循环依赖：
/// 引擎只认这个接口，不认 `PlaybackRepository`。
abstract class PlaybackCommandListener {
  /// 当前曲目**自然播放结束**（`ProcessingState.completed` 的那次跃迁）。
  Future<void> onTrackCompleted();

  /// MediaSession 的「下一曲」（遥控器 / 蓝牙媒体键 / 系统媒体控制）。
  Future<void> onSkipToNext();

  /// MediaSession 的「上一曲」。
  Future<void> onSkipToPrevious();

  /// **播放期间**（已成功换源之后）发生的异常：网络中断、解码失败等。
  ///
  /// 为什么必须有这条通道：`play()` 的 Future 只会「在播放结束/暂停/停止时完成」，
  /// 它的失败**不会被任何 `await` 接住**（调用方早就返回了）。
  /// 不显式上报的话，这类错误就是**静默丢弃** ——
  /// 用户看到进度条在走、却没有声音，页面上没有任何提示。
  ///
  /// ⚠️ 语义与「换源失败」不同：这时音源**已经是新歌**了，
  /// 因此只做「提示 + 标记失败（按播放可重试）」，不自动跳歌。
  void onPlaybackError(Object error, StackTrace? stackTrace);
}
