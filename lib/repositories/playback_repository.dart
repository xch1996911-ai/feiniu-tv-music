import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../core/log.dart';
import '../domain/track.dart';
import '../playback/playback_port.dart';
import 'music_repository.dart';

/// 播放编排仓储：管理播放队列、当前索引、上一首/下一首、播放/暂停/Seek。
///
/// 引擎只负责「播放单个 URL」，队列与模式逻辑全部在此，避免在播放引擎里堆砌业务
/// （改进 FeiNiuMusic 170KB 巨型单例，见 technical_research.md §6.2）。
///
/// ## 单一队列状态（重要）
/// 本类是**唯一**持有 `_queue` / `_index` 的地方。
/// `PlaybackHandler` 既不保存队列也不保存索引，只在 [onTrackCompleted] /
/// [onSkipToNext] / [onSkipToPrevious] 里回调进来。
/// 因此页面按钮与 Android MediaSession 媒体键必然走同一套逻辑，不会出现两套状态。
///
/// ## 并发模型：串行队列 + generation 令牌（两者缺一不可）
///
/// 快速连按「下一首」时，多次播放请求会并发进入 [PlaybackEngine.loadAndPlay]。
/// 只在 `await` **之后**比对代号是不够的：旧的 `setAudioSource` 一旦后返回，
/// 仍会在引擎内部把新曲目的音源覆盖掉（表现为「界面是 C，实际在放 B」）。
///
/// 因此这里做两件事：
/// 1. **串行**：所有加载排在同一条链上（[_loadChain]），同一时刻只有一个在飞，
///    杜绝引擎内部的新旧音源交错；
/// 2. **latest-wins**：每个任务真正下发前先比对 [_generation]，
///    已被更新的请求取代的直接跳过，连引擎都不碰。
class PlaybackRepository extends ChangeNotifier implements PlaybackCommandListener {
  final MusicRepository _music;
  final PlaybackEngine _handler;

  List<Track> _queue = const [];
  int _index = -1;

  /// 播放请求代号：每次「开始加载某首歌」自增。
  int _generation = 0;

  /// 加载串行链，保证同一时刻只有一个 [PlaybackEngine.loadAndPlay] 在执行。
  Future<void> _loadChain = Future<void>.value();

  /// 队列里是否还有下一首（用于「最后一首自然结束」的边界判断）。
  bool get hasNext => _index >= 0 && _index < _queue.length - 1;

  /// 队列里是否还有上一首。
  bool get hasPrevious => _index > 0;

  /// 当前排队的加载全部结束时完成。
  ///
  /// 仅供测试等待「串行链排空」用。`next()` 是 `async` 但**不同步等待加载完成**
  /// （它只把任务排进 [_loadChain] 就返回），所以测试里 `await next()` 之后
  /// 引擎侧可能**什么都没发生**，必须额外 await 这个 Future 才能断言结果。
  @visibleForTesting
  Future<void> get pendingLoads => _loadChain;

  PlaybackRepository({
    required MusicRepository music,
    required PlaybackEngine handler,
  })  : _music = music,
        _handler = handler {
    // 引擎播放状态变化 → 通知 UI（进度条、播放/暂停按钮）。
    _stateSub = _handler.stateChanges.listen((_) => _safeNotify());
    // 装配队列控制回调：MediaSession 媒体键 / 自然结束 → 本类的队列逻辑。
    _handler.commandListener = this;
  }

  late final StreamSubscription<void> _stateSub;

  /// 是否已 dispose。
  ///
  /// `_load()` 在 `await` 之后会回来刷新 UI，而这段窗口里仓储可能已被销毁
  /// （例如用户退出登录）。`ChangeNotifier.notifyListeners()` 在 dispose 之后
  /// 调用会**抛异常**，因此所有异步回调都必须先过这一关。
  bool _disposed = false;

  /// 安全地通知 UI：已 dispose 时静默跳过。
  ///
  /// 播放状态本身属于全局播放层，dispose 不影响引擎，只是不再有监听者。
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  List<Track> get queue => _queue;
  int get currentIndex => _index;
  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  PlaybackEngine get handler => _handler;

  bool get isPlaying => _handler.isPlaying;
  Duration? get position => _handler.position;
  Duration? get duration => _handler.duration;

  @override
  void dispose() {
    _disposed = true;
    _stateSub.cancel();
    // ⚠️ 刻意**不**调用 `_handler.stop()`：
    // 播放状态属于全局播放层，不绑定任何页面或仓储的生命周期。
    // 真正「停止播放」只由用户显式操作触发。
    super.dispose();
  }

  /// 用整张列表建立队列并从 startIndex 开始播放（Phase 1 默认顺序播放）。
  void setQueue(List<Track> tracks, {int startIndex = 0}) {
    _queue = tracks;
    _index = startIndex;
    _playCurrent();
  }

  /// 从 [_index] 起**向后**找第一首可播放的曲目，最多扫到队尾。
  ///
  /// 返回 null 表示后面没有可播放的曲目。
  /// 循环上界固定为「剩余长度」，既不递归也不会绕回队首造成诡异行为。
  int? _findPlayableIndex(int from) {
    final n = _queue.length;
    var scanned = 0;
    for (var i = from; i < n; i++) {
      if (_queue[i].isAccessible) return i;
      scanned++;
    }
    Log.w('INVALID_TRACK_SKIP 后续 $scanned 首均不可播放，停止自动切换');
    return null;
  }

  void _playCurrent() {
    final t = current;
    if (t == null) return;

    // 失效曲目（accessStatus==3 等）→ 向后找下一首可播的，最多扫一轮。
    if (!t.isAccessible) {
      final next = _findPlayableIndex(_index);
      if (next == null) {
        Log.w('INVALID_TRACK_SKIP 无可播放曲目，停止播放 index=$_index guid=${t.guid}');
        _safeNotify();
        return;
      }
      Log.i('INVALID_TRACK_SKIP 跳过失效曲目 index=$_index → $next');
      _index = next;
    }

    final track = _queue[_index];
    final gen = ++_generation;
    final url = _music.buildStreamUrl(track.guid);
    final headers = _music.authHeaders;
    final item = MediaItem(
      id: track.guid,
      title: track.title,
      artist: track.artistNames,
      album: track.album.name,
    );
    Log.i('PLAY_REQUEST gen=$gen index=$_index guid=${track.guid}');

    // 串行排队：前一个加载结束后才下发本次，且下发前先确认自己仍是最新请求。
    //
    // ⚠️ 链尾必须吞掉异常：否则**任何一次**失败都会把这条链变成已失败的 Future，
    // 之后所有 `.then` 都被跳过 → 整个播放器再也无法切歌（静默永久失效）。
    _loadChain = _loadChain.then((_) => _load(gen, url, headers, item)).catchError(
      (Object e, StackTrace st) {
        // `_load` 内部已兜住业务异常；这里只兜链本身被破坏的极端情况。
        Log.e('播放链异常，已恢复（不影响后续切歌）gen=$gen', e, st);
      },
    );
  }

  /// 真正下发一次播放请求。**只在串行链上被调用**，因此无需担心并发交错。
  Future<void> _load(
    int gen,
    String url,
    Map<String, String> headers,
    MediaItem item,
  ) async {
    if (gen != _generation) {
      Log.i('STALE_PLAY_REQUEST_IGNORED gen=$gen 已过期（当前 gen=$_generation），不下发');
      return;
    }
    try {
      await _handler.loadAndPlay(url: url, headers: headers, item: item);
    } catch (e, st) {
      if (gen != _generation) {
        Log.i('STALE_PLAY_REQUEST_IGNORED gen=$gen 失败已过期，忽略错误');
        return;
      }
      Log.e('PLAY_ERROR gen=$gen guid=${item.id}', e, st);
      _safeNotify();
      return;
    }
    // 加载期间用户又切歌了：这次的结果作废，不得覆盖更新的播放状态。
    if (gen != _generation) {
      Log.i('STALE_PLAY_REQUEST_IGNORED gen=$gen 加载完成但已过期（当前 gen=$_generation）');
      return;
    }
    Log.i('PLAY_START gen=$gen guid=${item.id}');
    _safeNotify();
  }

  Future<void> play() async {
    await _handler.play();
    _safeNotify();
  }

  Future<void> pause() async {
    await _handler.pause();
    _safeNotify();
  }

  Future<void> togglePlay() async {
    if (_handler.isPlaying) {
      await _handler.pause();
    } else {
      await _handler.play();
    }
    _safeNotify();
  }

  /// 下一首。**边界**：已是最后一首则保持不动（不循环，不崩溃）。
  Future<void> next() async {
    if (_index < _queue.length - 1) {
      _index += 1;
      Log.i('SKIP_NEXT index=$_index guid=${_queue[_index].guid}');
      _playCurrent();
    } else {
      Log.i('SKIP_NEXT 已到队尾 index=$_index，保持当前曲目');
      _safeNotify();
    }
  }

  /// 上一首。**边界**：已是第一首则保持不动（不循环，不崩溃）。
  Future<void> previous() async {
    // 播放超过 3 秒时，上一首先回到本曲开头（常见媒体键语义）。
    if (_handler.position != null && _handler.position! > const Duration(seconds: 3)) {
      await _handler.seek(Duration.zero);
      return;
    }
    if (_index > 0) {
      _index -= 1;
      Log.i('SKIP_PREVIOUS index=$_index guid=${_queue[_index].guid}');
      _playCurrent();
    } else {
      Log.i('SKIP_PREVIOUS 已到队首 index=$_index，保持当前曲目');
      _safeNotify();
    }
  }

  Future<void> seek(Duration position) async {
    await _handler.seek(position);
    _safeNotify();
  }

  // ── PlaybackCommandListener：MediaSession 与自然结束的入口 ──────────────
  // 页面按钮调用上面的 next()/previous()，媒体键调用这里，
  // 两条路径最终都执行同一份代码，因此不存在两套队列状态。

  @override
  Future<void> onSkipToNext() => next();

  @override
  Future<void> onSkipToPrevious() => previous();

  /// 当前曲目自然播放结束 → 自动切下一首。
  ///
  /// 边界：已是最后一首时**不循环**，停在 completed 状态。
  @override
  Future<void> onTrackCompleted() async {
    if (!hasNext) {
      Log.i('AUTO_NEXT 已是队尾 index=$_index，不自动切歌，保持 completed');
      _safeNotify();
      return;
    }
    Log.i('AUTO_NEXT index=$_index → ${_index + 1}');
    await next();
  }
}
