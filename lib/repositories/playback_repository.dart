import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../core/log.dart';
import '../domain/track.dart';
import '../playback/playback_control.dart';
import '../playback/playback_port.dart';
import '../services/secure_store.dart';
import 'music_repository.dart';

/// 播放编排仓储：管理播放队列、当前索引、上一首/下一首、播放/暂停/Seek、播放模式。
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
/// 仍会在引擎内部把新曲目的音源覆盖掉（表现为「界面显示 C、实际在放 B」）。
///
/// 因此这里做两件事：
/// 1. **串行**：所有加载排在同一条链上（[_loadChain]），同一时刻只有一个在飞，
///    杜绝引擎内部的新旧音源交错；
/// 2. **latest-wins**：每个任务真正下发前先比对 [_generation]，
///    已被更新的请求取代的直接跳过，连引擎都不碰。
///
/// 链尾额外 `catchError` 兜底：否则任意一次失败都会把链变成已失败的 Future，
/// 之后所有 `.then` 都被跳过 → 播放器**永久无法切歌**（静默失效）。
///
/// ## V2 扩展
/// - 实现 [PlaybackControl]：为 V3 手机端远程控制预留唯一入口；
/// - 播放模式（顺序 / 列表循环 / 单曲 / 随机）+ 持久化；
/// - 队列跨分页追加（[appendToQueue]），使「第 30 首播完能接第 31 首」；
/// - 播放错误自动跳过（有尝试上限，防死循环）。
class PlaybackRepository extends ChangeNotifier
    implements PlaybackCommandListener, PlaybackControl {
  final MusicRepository _music;
  final PlaybackEngine _handler;

  List<Track> _queue = const [];
  int _index = -1;

  /// 播放请求代号：每次「开始加载某首歌」自增。
  int _generation = 0;

  /// 加载串行链，保证同一时刻只有一个 [PlaybackEngine.loadAndPlay] 在执行。
  Future<void> _loadChain = Future<void>.value();

  /// 当前队列来源（全部歌曲 / 搜索结果 / 恢复）。
  QueueSource _source = QueueSource.library;

  /// 当前播放模式。
  PlayMode _mode = PlayMode.sequence;

  /// 队列末尾还差几首就触发预加载（见 [prefetchMore]）。
  static const int _prefetchThreshold = 3;

  /// 预加载回调。由曲库仓储注入（避免播放层直接依赖曲库层）。
  Future<bool> Function()? _prefetchCallback;

  /// 预加载防重入。
  bool _prefetching = false;

  /// 连续播放失败的曲目数（用于错误自动跳过的死循环保护）。
  int _consecutiveFailures = 0;

  /// 单次自动跳过的最大尝试次数。
  static const int _maxAutoSkip = 5;

  /// 随机播放用（避免连续随机到同一首）。
  final Random _random = Random();

  /// 统一状态流（供 [PlaybackControl.states]）。用同步广播以免漏掉首个订阅者。
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast(sync: true);

  PlaybackRepository({
    required MusicRepository music,
    required PlaybackEngine handler,
    SecureStore? store,
  })  : _music = music,
        _handler = handler,
        _store = store ?? SecureStore() {
    // 引擎播放状态变化 → 通知 UI（进度条、播放/暂停按钮）。
    _stateSub = _handler.stateChanges.listen((_) => _safeNotify());
    // 装配队列控制回调：MediaSession 媒体键 / 自然结束 → 本类的队列逻辑。
    _handler.commandListener = this;
  }

  final SecureStore _store;
  late final StreamSubscription<void> _stateSub;

  /// 恢复播放模式。**必须在使用 UI 之前 await**，否则首帧可能显示默认模式。
  ///
  /// 失败一律降级为顺序播放，绝不影响启动。
  Future<void> restoreMode() async {
    try {
      final key = await _store.readPlayModeKey().timeout(
        const Duration(seconds: 3),
      );
      _mode = PlayModeX.fromStorage(key);
      Log.i('STATE_RESTORE 播放模式=${_mode.storageKey}');
      _safeNotify();
    } catch (e) {
      Log.w('STATE_RESTORE_FAIL 播放模式读取失败，用默认值：$e');
      _mode = PlayMode.sequence;
    }
  }

  /// 注入曲库的预加载回调（曲库仓储在构造后调用）。
  void attachPrefetch(Future<bool> Function() callback) {
    _prefetchCallback = callback;
  }

  /// 当前排队的加载全部结束时完成。
  ///
  /// 仅供测试等待「串行链排空」用。`next()` 是 `async` 但**不同步等待加载完成**
  /// （它只把任务排进 [_loadChain] 就返回），所以测试里 `await next()` 之后
  /// 引擎侧可能**什么都没发生**，必须额外 await 这个 Future 才能断言结果。
  @visibleForTesting
  Future<void> get pendingLoads => _loadChain;

  // ── 状态恢复（V2 §14）────────────────────────────────────

  /// 上次播放的曲目 guid 与进度（供 [restoreToTrack] 使用）。
  String? _pendingRestoreGuid;
  Duration _pendingRestorePosition = Duration.zero;

  /// 待恢复的曲目 guid（UI 可据此显示「上次播放的歌曲」）。
  String? get pendingRestoreGuid => _pendingRestoreGuid;
  Duration get pendingRestorePosition => _pendingRestorePosition;

  /// 读取上次播放的曲目与进度。
  ///
  /// **刻意不自动播放**（V2 §14 明确要求）：电视开机后 APP 突然放歌是很糟的体验。
  /// 只是把「上次在听什么」准备好，等用户按播放。
  Future<void> loadRestorePoint() async {
    try {
      final guid = await _store.readLastTrackGuid().timeout(
            const Duration(seconds: 3),
          );
      final ms = await _store.readLastPositionMs().timeout(
            const Duration(seconds: 3),
          );
      if (guid == null || guid.isEmpty) {
        Log.i('STATE_RESTORE 无上次播放记录');
        return;
      }
      _pendingRestoreGuid = guid;
      _pendingRestorePosition = Duration(milliseconds: ms ?? 0);
      Log.i('STATE_RESTORE guid=$guid position=${_pendingRestorePosition.inMilliseconds}ms');
    } catch (e) {
      // 恢复失败必须**完全不影响启动**（V2 §14）。
      Log.w('STATE_RESTORE_FAIL 读取上次播放失败（忽略）：$e');
    }
  }

  /// 把队列定位到上次播放的曲目，但**不自动播放**。
  ///
  /// 返回是否命中。UI 命中后可以显示「上次播放：xxx」。
  bool restoreToTrack(List<Track> catalogue) {
    final guid = _pendingRestoreGuid;
    if (guid == null || catalogue.isEmpty) return false;
    final idx = catalogue.indexWhere((t) => t.guid == guid);
    if (idx < 0) {
      Log.i('STATE_RESTORE 曲库里已找不到 guid=$guid（可能已删除）');
      return false;
    }
    _queue = List<Track>.unmodifiable(catalogue);
    _index = idx;
    _source = QueueSource.restored;
    _consecutiveFailures = 0;
    _lastError = null;
    Log.i('STATE_RESTORE 定位到 index=$idx（未自动播放）');
    _safeNotify();
    return true;
  }

  /// 记录当前曲目与进度（供下次启动恢复）。
  ///
  /// 由 UI 定期调用；**刻意不自动播放**，恢复后等用户按播放。
  Future<void> saveRestorePoint() async {
    final t = current;
    if (t == null) return;
    try {
      await _store.writeLastTrackGuid(t.guid);
      final pos = _handler.position ?? Duration.zero;
      await _store.writeLastPositionMs(pos.inMilliseconds);
    } catch (e) {
      // 持久化失败静默忽略：不能因为存不进去而影响播放
      Log.w('STATE_RESTORE_FAIL 保存进度失败：$e');
    }
  }

  /// **仅供测试**：直接写入「待恢复点」，跳过安全存储。
  ///
  /// 设备上恒为测试专用入口（生产路径请用 [saveRestorePoint]）。
  @visibleForTesting
  void restoreToTrackForTest(String guid, Duration position) {
    _pendingRestoreGuid = guid;
    _pendingRestorePosition = position;
  }

  // ── 基础查询 ──────────────────────────────────────────────

  /// 队列里是否还有下一首（不考虑播放模式的回绕）。
  bool get hasNext => _index >= 0 && _index < _queue.length - 1;

  /// 队列里是否还有上一首。
  bool get hasPrevious => _index > 0;

  List<Track> get queue => _queue;
  int get currentIndex => _index;
  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  PlaybackEngine get handler => _handler;

  bool get isPlaying => _handler.isPlaying;
  Duration? get position => _handler.position;
  Duration? get duration => _handler.duration;

  QueueSource get source => _source;

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
    if (!_states.isClosed) {
      _states.add(buildState());
    }
  }

  /// 组装当前状态快照。
  ///
  /// 每次都构造**新对象**（不可变），保证订阅者拿到一致的一帧。
  PlaybackState buildState() => PlaybackState(
        source: _source,
        sourceLabel: sourceLabelOf(_source),
        queue: _queue,
        currentIndex: _index,
        currentSong: current,
        isPlaying: isPlaying,
        position: position ?? Duration.zero,
        duration: duration ?? Duration.zero,
        mode: _mode,
        error: _lastError,
      );

  static String sourceLabelOf(QueueSource s) => switch (s) {
        QueueSource.library => '全部歌曲',
        QueueSource.search => '搜索结果',
        QueueSource.restored => '上次播放',
      };

  String? _lastError;

  @override
  Stream<PlaybackState> get states => _states.stream;

  @override
  PlaybackState get state => buildState();

  @override
  PlayMode get mode => _mode;

  @override
  void dispose() {
    _disposed = true;
    _stateSub.cancel();
    _states.close();
    // ⚠️ 刻意**不**调用 `_handler.stop()`：
    // 播放状态属于全局播放层，不绑定任何页面或仓储的生命周期。
    // 真正「停止播放」只由用户显式操作触发。
    super.dispose();
  }

  // ── 队列控制 ──────────────────────────────────────────────

  /// 用整张列表建立队列并从 [startIndex] 开始播放。
  void setQueue(List<Track> tracks, {int startIndex = 0}) {
    _playQueueImpl(
      tracks,
      source: QueueSource.library,
      startIndex: startIndex,
    );
  }

  @override
  Future<void> playQueue(
    List<Track> tracks, {
    required QueueSource source,
    int startIndex = 0,
  }) async {
    _playQueueImpl(tracks, source: source, startIndex: startIndex);
  }

  void _playQueueImpl(
    List<Track> tracks, {
    required QueueSource source,
    int startIndex = 0,
  }) {
    _queue = List<Track>.unmodifiable(tracks);
    _source = source;
    _index = (startIndex >= 0 && startIndex < tracks.length) ? startIndex : -1;
    _consecutiveFailures = 0;
    _lastError = null;
    Log.i('QUEUE_SET source=${source.storageKey} '
        'length=${tracks.length} start=$_index');
    _playCurrent();
  }

  /// **不改变 currentIndex**：分页加载更多时调用，正在播放的歌不会被换掉。
  int appendToQueue(List<Track> tracks) {
    if (tracks.isEmpty) return _queue.length;
    final existing = <String>{for (final t in _queue) t.guid};
    final fresh = tracks.where((t) => t.guid.isNotEmpty && existing.add(t.guid));
    if (fresh.isEmpty) return _queue.length;
    _queue = List<Track>.unmodifiable(<Track>[..._queue, ...fresh]);
    Log.i('QUEUE_APPEND added=${fresh.length} total=${_queue.length} '
        'index=$_index');
    _safeNotify();
    return _queue.length;
  }

  /// 用整份曲库**建立**队列，但**不自动播放**。
  ///
  /// 用于「首屏曲库加载完，用户还没点歌」的场合：
  /// 队列先就位（保证跨分页连续播放成立），但**不发任何播放请求**
  /// （电视上开机不该突然放歌，V2 §14）。
  ///
  /// 已经有队列时**什么都不做** —— 不能覆盖搜索结果队列。
  void adoptQueue(List<Track> tracks) {
    if (tracks.isEmpty) return;
    if (_queue.isNotEmpty) return;
    _queue = List<Track>.unmodifiable(tracks);
    _index = -1; // 未开始播放，current 为 null → Mini Player 隐藏
    _source = QueueSource.library;
    Log.i('QUEUE_ADOPT 已建立队列但未播放 total=${_queue.length}');
    _safeNotify();
  }

  @override
  Future<int> addToQueue(Track track) async {
    final existing = _queue.any((t) => t.guid == track.guid);
    if (existing) return _queue.length;
    _queue = List<Track>.unmodifiable(<Track>[..._queue, track]);
    _safeNotify();
    return _queue.length;
  }

  @override
  Future<bool> removeFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return false;
    if (index == _index) {
      // 正在播放的曲目不允许移除，否则 currentIndex 与 queue 会错位。
      Log.w('QUEUE_REMOVE 拒绝移除正在播放的曲目 index=$index');
      return false;
    }
    final next = List<Track>.of(_queue)..removeAt(index);
    _queue = List<Track>.unmodifiable(next);
    if (index < _index) {
      _index -= 1; // 删除了前面的元素，当前曲的下标要跟着前移
    }
    Log.i('QUEUE_REMOVE index=$index total=${_queue.length}');
    _safeNotify();
    return true;
  }

  @override
  void notifyQueueExtended(int count) {
    if (count <= 0) return;
    Log.i('QUEUE_PREFETCH 已扩展队列 +$count → total=${_queue.length}');
    _safeNotify();
  }

  @override
  Future<bool> prefetchMore() async {
    if (_prefetching) return false; // 防重入：快速连点不会重复请求
    final cb = _prefetchCallback;
    if (cb == null) return false;
    final remaining = _queue.length - 1 - _index;
    if (remaining > _prefetchThreshold) return false;
    _prefetching = true;
    try {
      Log.i('QUEUE_PREFETCH 触发（剩余 $remaining 首）');
      return await cb();
    } finally {
      _prefetching = false;
    }
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
        _lastError = '这首歌曲不可播放';
        _safeNotify();
        return;
      }
      Log.i('PLAY_SKIP_ERROR_TRACK 跳过失效曲目 index=$_index → $next');
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
    Log.i('PLAY_REQUEST gen=$gen index=$_index guid=${track.guid} '
        'mode=${_mode.storageKey} source=${_source.storageKey}');

    // 串行排队：前一个加载结束后才下发本次，且下发前先确认自己仍是最新请求。
    //
    // ⚠️ 链尾必须吞掉异常：否则**任何一次**失败都会把这条链变成已失败的 Future，
    // 之后所有 `.then` 都被跳过 → 整个播放器再也无法切歌（静默永久失效）。
    _loadChain = _loadChain.then((_) => _load(gen, url, headers, item)).catchError(
      (Object e, StackTrace st) {
        // `_load` 内部已兜住业务异常；这里只兜链本身被破坏的极端情况。
        Log.e('PLAY_ERROR 播放链异常，已恢复（不影响后续切歌）gen=$gen', e, st);
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
      _lastError = '播放失败：正在跳过这首';
      _safeNotify();
      // 加载失败也自动跳过，但有次数上限（见 [_handleLoadFailure]）。
      await _handleLoadFailure();
      return;
    }
    // 加载期间用户又切歌了：这次的结果作废，不得覆盖更新的播放状态。
    if (gen != _generation) {
      Log.i('STALE_PLAY_REQUEST_IGNORED gen=$gen 加载完成但已过期（当前 gen=$_generation）');
      return;
    }
    Log.i('PLAY_START gen=$gen guid=${item.id}');
    _consecutiveFailures = 0;
    _lastError = null;
    _safeNotify();
  }

  /// 加载失败后自动跳到下一首，带**次数上限**防死循环。
  Future<void> _handleLoadFailure() async {
    if (_consecutiveFailures >= _maxAutoSkip) {
      Log.e('PLAY_ERROR 连续 $_maxAutoSkip 首失败，停止自动跳过 '
          '（防止整队皆不可播时死循环）');
      _lastError = '连续多首无法播放，已停止';
      _safeNotify();
      return;
    }
    _consecutiveFailures++;
    if (!hasNext) {
      Log.w('PLAY_ERROR 已是最后一首且加载失败，停止');
      _safeNotify();
      return;
    }
    Log.i('PLAY_SKIP_ERROR_TRACK 加载失败，自动跳下一首 '
        '($_consecutiveFailures/$_maxAutoSkip)');
    await next();
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

  /// 下一首。末尾行为取决于播放模式：
  /// - 列表循环 / 随机 → 回绕到第一首；
  /// - 顺序播放 / 单曲循环 → 保持不动（不崩溃）。
  @override
  Future<void> next() async {
    if (_queue.isEmpty) return;
    if (_index < _queue.length - 1) {
      _index += 1;
      Log.i('SKIP_NEXT index=$_index guid=${_queue[_index].guid}');
      _playCurrent();
      unawaited(_maybePrefetch());
    } else if (_mode.wrapOnManualNext) {
      _index = 0;
      Log.i('SKIP_NEXT 回绕到队首 index=0 mode=${_mode.storageKey}');
      _playCurrent();
    } else {
      Log.i('SKIP_NEXT 已到队尾 index=$_index，保持当前曲目');
      _safeNotify();
    }
  }

  /// 上一首。播放超过 3 秒时先回到本曲开头（常见媒体键语义）。
  @override
  Future<void> previous() async {
    if (_queue.isEmpty) return;
    if (_handler.position != null && _handler.position! > const Duration(seconds: 3)) {
      Log.i('SEEK 上一首键：播放超过 3 秒，回到本曲开头');
      await _handler.seek(Duration.zero);
      _safeNotify();
      return;
    }
    if (_index > 0) {
      _index -= 1;
      Log.i('SKIP_PREVIOUS index=$_index guid=${_queue[_index].guid}');
      _playCurrent();
    } else if (_mode == PlayMode.repeatAll || _mode == PlayMode.shuffle) {
      _index = _queue.length - 1;
      Log.i('SKIP_PREVIOUS 回绕到队尾 index=$_index');
      _playCurrent();
    } else {
      Log.i('SKIP_PREVIOUS 已到队首 index=$_index，保持当前曲目');
      _safeNotify();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    Log.i('SEEK position=${position.inMilliseconds}ms');
    await _handler.seek(position);
    _safeNotify();
  }

  Future<void> seekRelative(Duration delta) => seek(
        (_handler.position ?? Duration.zero) + delta,
      );

  // ── 播放模式 ──────────────────────────────────────────────

  @override
  Future<void> setMode(PlayMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    Log.i('PLAY_MODE_CHANGE mode=${mode.storageKey}');
    _safeNotify();
    try {
      await _store.writePlayModeKey(mode.storageKey);
    } catch (e) {
      // 持久化失败不影响本次使用
      Log.w('PLAY_MODE_CHANGE 持久化失败：$e');
    }
  }

  /// 随机播放时挑一个**尽量不是当前曲**的下一首。
  int _randomIndexNext() {
    if (_queue.length <= 1) return _index;
    var candidate = _index;
    var guard = 0;
    while (candidate == _index && guard < 8) {
      candidate = _random.nextInt(_queue.length);
      guard++;
    }
    if (candidate == _index) {
      // 兜底：只有一个可选项时直接回绕
      candidate = (_index + 1) % _queue.length;
    }
    return candidate;
  }

  // ── PlaybackCommandListener：MediaSession 与自然结束的入口 ──
  // 页面按钮调用上面的 next()/previous()，媒体键调用这里，
  // 两条路径最终都执行同一份代码，因此不存在两套队列状态。

  @override
  Future<void> onSkipToNext() => next();

  @override
  Future<void> onSkipToPrevious() => previous();

  /// 当前曲目自然播放结束 → 按播放模式推进。
  ///
  /// 顺序播放在最后一首**不循环**（V1 行为，保持不变）。
  @override
  Future<void> onTrackCompleted() async {
    Log.i('PLAY_COMPLETED index=$_index mode=${_mode.storageKey}');
    _consecutiveFailures = 0;
    switch (_mode.onCompleted) {
      case PlayAdvanceAction.stop:
        if (!hasNext) {
          Log.i('AUTO_NEXT 顺序播放且已是队尾，停在 completed');
          _safeNotify();
          return;
        }
        Log.i('AUTO_NEXT index=$_index → ${_index + 1}');
        await next();
      case PlayAdvanceAction.wrapToFirst:
        _index = 0;
        Log.i('AUTO_NEXT 列表循环 → 队首 index=0');
        _playCurrent();
        unawaited(_maybePrefetch());
      case PlayAdvanceAction.repeatCurrent:
        Log.i('AUTO_NEXT 单曲循环 → 重播当前曲 index=$_index');
        await _handler.seek(Duration.zero);
        await _handler.play();
        _safeNotify();
      case PlayAdvanceAction.pickRandom:
        final target = _randomIndexNext();
        Log.i('AUTO_NEXT 随机 → index=$_index → $target');
        _index = target;
        _playCurrent();
        unawaited(_maybePrefetch());
    }
  }

  /// 播放推进后若接近队尾则触发预加载（跨分页连续播放的关键）。
  ///
  /// 返回 [Future] 以便调用处写 `unawaited(...)`；`prefetchMore()` 内部
  /// 已有防重入，重复调用不会产生并发请求。
  Future<bool> _maybePrefetch() => prefetchMore();
}
