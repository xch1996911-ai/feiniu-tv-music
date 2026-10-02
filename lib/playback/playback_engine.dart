import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../core/log.dart';

/// 播放引擎：封装 just_audio（ExoPlayer / AVPlayer，系统解码优先）并桥接 MediaSession。
///
/// Phase 1 仅用系统解码（just_audio / ExoPlayer），不引入 media_kit 兜底引擎
/// （留待 Phase 3，见 technical_research.md §6.3）。
///
/// 遥控器媒体键（Play/Pause/Next/Prev）由 Android MediaSession 经 audio_service 自动路由到本 Handler，
/// 无需在 Flutter 层重复接管传输键。
class PlaybackHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  PlaybackHandler() {
    _player.playbackEventStream.listen(_transformEvent);
    _player.durationStream.listen(_onDuration);
  }

  /// 加载并播放一首歌。headers 携带认证（如 Cookie: music-token）。
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

  void _onDuration(Duration? duration) {
    final current = mediaItem.value;
    if (duration != null && current != null) {
      mediaItem.add(current.copyWith(duration: duration));
    }
  }

  void _transformEvent(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      playing: playing,
      processingState: _mapState(_player.processingState),
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    ));
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

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Duration? get position => _player.position;
  Duration? get duration => _player.duration;
  bool get isPlaying => _player.playing;
  Stream<PlayerState> get stateStream => _player.playerStateStream;
}
