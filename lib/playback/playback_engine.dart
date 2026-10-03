import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../core/log.dart';
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
      await _player.play();
    } catch (e, st) {
      Log.e('播放失败 url=$url', e, st);
      rethrow;
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

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
