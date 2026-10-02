import 'package:flutter/material.dart';

import '../core/log.dart';
import '../domain/track.dart';
import '../playback/playback_engine.dart';
import 'music_repository.dart';

/// 播放编排仓储：管理播放队列、当前索引、上一首/下一首、播放/暂停/Seek。
///
/// 引擎只负责「播放单个 URL」，队列与模式逻辑全部在此，避免在播放引擎里堆砌业务
/// （改进 FeiNiuMusic 170KB 巨型单例，见 technical_research.md §6.2）。
class PlaybackRepository extends ChangeNotifier {
  final MusicRepository _music;
  final PlaybackHandler _handler;

  List<Track> _queue = const [];
  int _index = -1;

  PlaybackRepository({
    required MusicRepository music,
    required PlaybackHandler handler,
  })  : _music = music,
        _handler = handler {
    // 引擎播放状态变化 → 通知 UI（进度条、播放/暂停按钮）。
    _handler.playbackState.listen((_) => notifyListeners());
  }

  List<Track> get queue => _queue;
  int get currentIndex => _index;
  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  PlaybackHandler get handler => _handler;

  bool get isPlaying => _handler.isPlaying;
  Duration? get position => _handler.position;
  Duration? get duration => _handler.duration;

  /// 用整张列表建立队列并从 startIndex 开始播放（Phase 1 默认顺序播放）。
  void setQueue(List<Track> tracks, {int startIndex = 0}) {
    _queue = tracks;
    _index = startIndex;
    _playCurrent();
  }

  void _playCurrent() {
    final t = current;
    if (t == null) return;
    if (!t.isAccessible) {
      Log.w('跳过失效曲目 guid=${t.guid}');
      return;
    }
    final url = _music.buildStreamUrl(t.guid);
    final headers = _music.authHeaders;
    final item = MediaItem(
      id: t.guid,
      title: t.title,
      artist: t.artistNames,
      album: t.album.name,
    );
    _handler
        .loadAndPlay(url: url, headers: headers, item: item)
        .then((_) => notifyListeners())
        .catchError((e, st) {
      Log.e('播放失败', e, st);
      notifyListeners();
    });
  }

  Future<void> play() async {
    await _handler.play();
    notifyListeners();
  }

  Future<void> pause() async {
    await _handler.pause();
    notifyListeners();
  }

  Future<void> togglePlay() async {
    if (_handler.isPlaying) {
      await _handler.pause();
    } else {
      await _handler.play();
    }
    notifyListeners();
  }

  Future<void> next() async {
    if (_index < _queue.length - 1) {
      _index += 1;
      _playCurrent();
    }
  }

  Future<void> previous() async {
    // 播放超过 3 秒时，上一首先回到本曲开头（常见媒体键语义）。
    if (_handler.position != null && _handler.position! > const Duration(seconds: 3)) {
      await _handler.seek(Duration.zero);
      return;
    }
    if (_index > 0) {
      _index -= 1;
      _playCurrent();
    }
  }

  Future<void> seek(Duration position) async {
    await _handler.seek(position);
    notifyListeners();
  }
}
