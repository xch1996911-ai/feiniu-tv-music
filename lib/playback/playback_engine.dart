import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../core/log.dart';
import 'play_launcher.dart';
import 'playback_port.dart';

/// 播放引擎：封装 just_audio（ExoPlayer / AVPlayer，系统解码优先）并桥接 MediaSession。
///
/// Phase 1 仅用系统解码（just_audio / ExoPlayer），不引入 media_kit 兜底引擎
/// （留待 Phase 3，见 technical_research.md §6.3）。
///
/// 遥控器媒体键（Play/Pause/Next/Prev）由 Android MediaSession 经 audio_service 自动路由到本 Handler，
/// 无需在 Flutter 层重复接管传输键。
///
/// ## 职责边界（不要越界）
/// 本类**只负责「播这一首 URL」与 MediaSession 桥接**，**不保存队列、不保存索引**。
/// 队列 / 上一首下一首 / 自动切歌全部在 `PlaybackRepository`。
/// 两者之间只通过 [PlaybackCommandListener] 回调通信（见 [commandListener]），
/// 因此页面按钮与 MediaSession 媒体键最终走**同一套**队列逻辑，不会出现两套状态。
///
/// ## 循环与随机**由应用层独占**（V5 明确决定）
///
/// 需求要求「统一决定循环/随机由底层还是应用层负责，不能两层都生效」。
/// 本项目的决定是：**全部由 `PlaybackRepository` 负责**。
///
/// 因此这里**刻意不设置**：
/// - `AudioPlayer.setLoopMode(...)` —— 保持默认 `LoopMode.off`；
/// - `BaseAudioHandler.setRepeatMode(...)` / `setShuffleMode(...)`
///   —— 一律不响应（MediaSession 下发这两种模式时不做任何事）。
///
/// 理由是队列状态只有 `PlaybackRepository` 持有：若底层自己 loop，
/// 「单曲循环」会变成底层重复而应用层不知道（历史/索引全乱）；
/// 若底层自己 shuffle，就会与应用层的随机遍历计划**各洗一次牌**，
/// 表现为「随机的顺序和界面对不上」。
/// 底层只做一件事：把「这首播完了」以 [PlaybackCommandListener.onTrackCompleted]
/// 的形式上报一次（且只上报 `非 completed → completed` 这一次跃迁）。
class PlaybackHandler extends BaseAudioHandler with SeekHandler implements PlaybackEngine {
  final AudioPlayer _player = AudioPlayer();

  /// 队列控制回调，由 `PlaybackRepository` 注入。为 null 表示尚未装配
  /// （例如安全模式的裸 handler），此时传输键安全地什么都不做。
  PlaybackCommandListener? _listener;

  /// 上一次已派发的处理状态。用来只捕捉 `completed` 的**跃迁**，
  /// 避免 `completed` 停留期间被重复派发造成连续自动切歌。
  ProcessingState? _lastProcessingState;

  final StreamController<void> _stateChanges = StreamController<void>.broadcast();

  PlaybackHandler() {
    _player.playbackEventStream.listen(_transformEvent);
    _player.durationStream.listen(_onDuration);
  }

  @override
  set commandListener(PlaybackCommandListener listener) => _listener = listener;

  @override
  Stream<void> get stateChanges => _stateChanges.stream;

  /// 加载并播放一首歌。headers 携带认证（如 Cookie: music-token）。
  ///
  /// ## ⚠️ 绝不可改回 `await _player.play()`（V6 事故根因）
  ///
  /// `just_audio` 的 `play()` Future **不是在播放开始时完成**，而是在
  /// **播放结束 / 被暂停 / 被停止**时才完成。而 `PlaybackRepository` 的加载链是
  /// 串行的（`_loadChain.then(_load)`）—— 一旦这里 `await`，就会变成：
  ///
  ///     A 正在播放时点 B ⇒ B 的 setAudioSource 排在 A 的 play() 后面
  ///     ⇒ A 播完/被暂停之前根本不会换源
  ///     ⇒ 但仓储里「当前曲目」已经是 B
  ///     ⇒ 实机表现：「界面/歌词都是 B，耳朵里还是 A」
  ///
  /// 正确做法：**只等待 setAudioSource（换源）完成**，然后经 [PlaybackLauncher]
  /// 触发播放并立即返回。串行链因此只串行化「换源」这一关键阶段，
  /// 不会被任何一首歌的播放生命周期占住。
  ///
  /// 播放期间的异常不吞：交给 [PlaybackLauncher] 的错误通道，
  /// 由仓储转成界面可见的提示（见 [PlaybackCommandListener.onPlaybackError]）。
  @override
  Future<void> loadAndPlay({
    required String url,
    required Map<String, String> headers,
    required MediaItem item,
  }) async {
    mediaItem.add(item);
    try {
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(url), headers: headers),
        preload: true,
      );
    } catch (e, st) {
      Log.e('播放失败 url=$url', e, st);
      rethrow;
    }
    _playingGuid = item.id;
    Log.i('PLAY_SOURCE_SET guid=${item.id}（换源完成，播放命令不等待生命周期）');
    _launcher.launch(
      () => _player.play(),
      onError: (Object e, StackTrace st) {
        Log.e('PLAY_ERROR 播放期间异常 guid=${item.id}', e, st);
        _listener?.onPlaybackError(e, st);
      },
      // 只有「当前音源仍是这首」时错误才有意义：
      // 用户已经点了别的歌，就不该再报上一首的错。
      isCurrent: () => _playingGuid == item.id,
    );
  }

  /// 当前已换源的曲目 id（[isCurrent] 判据）。
  String? _playingGuid;

  /// 启动/播放期间的错误通道（见 [PlaybackLauncher]）。
  final PlaybackLauncher _launcher = PlaybackLauncher();

  @override
  Future<void> play() {
    _startPlay();
    // ⚠️ 立即返回：不能把「整首播完」的 Future 交给调用方（仓储会 await 它）。
    return Future<void>.value();
  }

  /// 显式「播放」命令（暂停后恢复 / 重试）。
  ///
  /// ⚠️ 同样**不能直通 `await _player.play()`**：仓储的 `play()` / `togglePlay()`
  /// 会 `await` 本方法，一旦等待「整首播完」，按钮回调就永远不返回
  /// （旧实现在暂停后按播放，Future 会一直挂到这首放完）。
  /// 这里改成「触发 + 独立错误通道 + 立即返回」，
  /// 播放态由 `playbackEventStream` 正常刷新。
  void _startPlay() {
    final String? guid = _playingGuid;
    _launcher.launch(
      () => _player.play(),
      onError: (Object e, StackTrace st) {
        Log.e('PLAY_ERROR 播放期间异常（play 命令）guid=${guid ?? '-'}', e, st);
        _listener?.onPlaybackError(e, st);
      },
      isCurrent: () => guid == null || _playingGuid == guid,
    );
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() {
    // 作废当前播放会话：之后迟到的播放期异常不再上报给队列层。
    _launcher.invalidate();
    _playingGuid = null;
    return _player.stop();
  }

  @override
  Future<void> stopSession() async {
    _launcher.invalidate();
    _playingGuid = null;
    await _player.stop();
    // ⚠️ 必须显式广播 idle：audio_service 0.18 的 `BaseAudioHandler.stop()`
    //    默认是空操作，前台服务进入 `stopped` 状态由「processingState == idle」
    //    驱动（Android 官方文档原文："enters the stopped state whenever
    //    PlaybackState.processingState becomes idle"）。
    //    只停音源不广播的话，媒体通知 / 前台服务会一直挂着 ——
    //    这正是「退出并停止播放」要避免的「只隐藏窗口、服务还在」。
    //    controls 清空是为了让通知上的播放/暂停按钮一并消失。
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
      controls: const <MediaControl>[],
    ));
    Log.i('STOP_SESSION 音源已停，MediaSession 会话已置 idle（前台服务随之结束）');
  }

  /// MediaSession「下一曲」→ 交给队列控制方（`PlaybackRepository`）。
  ///
  /// ⚠️ 不重写 `UnimplementedError` 之前，Android 媒体键的下一曲是**直接抛异常**的：
  /// 页面按钮能用是因为它们绕开 MediaSession 直接调 Repository，
  /// 这会让人误以为媒体键也正常。
  @override
  Future<void> skipToNext() async {
    final l = _listener;
    if (l == null) {
      Log.w('MediaSession skipToNext：未装配队列控制回调，忽略');
      return;
    }
    await l.onSkipToNext();
  }

  /// MediaSession「上一曲」→ 交给队列控制方（`PlaybackRepository`）。
  @override
  Future<void> skipToPrevious() async {
    final l = _listener;
    if (l == null) {
      Log.w('MediaSession skipToPrevious：未装配队列控制回调，忽略');
      return;
    }
    await l.onSkipToPrevious();
  }

  /// MediaSession「重复模式」→ **刻意忽略**（见类文档「循环与随机由应用层独占」）。
  ///
  /// 若这里转成 `_player.setLoopMode(...)`，就会与应用层的自动下一首**同时生效**：
  /// 单曲循环下底层自己重播一次、应用层又按模式推进一次，结果是一首歌播两遍
  /// 或者干脆跳下一首 —— 这正是需求点名要避免的「两边都生效」。
  ///
  /// 播放模式的唯一入口是 `PlaybackRepository.setMode()`（UI 按钮 / 遥控器 /
  /// 手机遥控都走它）。
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    Log.i('MediaSession setRepeatMode(${repeatMode.name}) 已忽略：'
        '循环统一由 PlaybackRepository 决定');
  }

  /// MediaSession「随机模式」→ **刻意忽略**（同上）。
  ///
  /// 应用层的随机是「一轮不重复的遍历计划」，底层再来一次 shuffle
  /// 会让界面上显示的随机顺序与实际播放顺序对不上。
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    Log.i('MediaSession setShuffleMode(${shuffleMode.name}) 已忽略：'
        '随机统一由 PlaybackRepository 决定');
  }

  void _onDuration(Duration? duration) {
    final current = mediaItem.value;
    if (duration != null && current != null) {
      mediaItem.add(current.copyWith(duration: duration));
    }
  }

  void _transformEvent(PlaybackEvent event) {
    final playing = _player.playing;
    final processing = _player.processingState;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      playing: playing,
      processingState: _mapState(processing),
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    ));

    if (!_stateChanges.isClosed) {
      _stateChanges.add(null);
    }
    _dispatchCompleted(processing);
    _lastProcessingState = processing;
  }

  /// 把「自然播放结束」的**边沿**转成一次队列回调。
  ///
  /// 只在 `非 completed → completed` 的跃迁时派发：`completed` 状态下播放器仍会继续
  /// 抛出事件（position/buffered 变化），若不判边沿就会连成一条自动切歌链。
  void _dispatchCompleted(ProcessingState current) {
    if (current != ProcessingState.completed) return;
    if (_lastProcessingState == ProcessingState.completed) return;
    final l = _listener;
    if (l == null) {
      Log.w('自然播放结束：未装配队列控制回调，无法自动切下一首');
      return;
    }
    Log.i('PLAY_COMPLETED 派发自动下一首');
    // 不 await：这里是事件回调，排队让队列控制方处理即可。
    unawaited(l.onTrackCompleted());
  }

  AudioProcessingState _mapState(ProcessingState s) {
    switch (s) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  @override
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  @override
  Duration? get position => _player.position;
  @override
  Duration? get duration => _player.duration;
  @override
  bool get isPlaying => _player.playing;
  Stream<PlayerState> get stateStream => _player.playerStateStream;
}
