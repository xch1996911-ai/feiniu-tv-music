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
///
/// ## V5 修复：三种模式此前「表现不符合预期」的真实原因
///
/// 用户实机反馈：随机播放很快听到重复、顺序播放到「最后一首」就停、
/// 单曲循环会跳下一首、随机播放的「上一首」跑到列表里的前一首。
/// 逐条对应到代码：
///
/// 1. **随机播放重复** —— 原实现是 [Random.nextInt] **有放回**取样：
///    ```dart
///    candidate = _random.nextInt(_queue.length);  // 每次都从全队列重抽
///    ```
///    这不是「随机遍历」，而是「随机点播」。从 N 首里抽 n 次，出现重复的
///    期望次数按生日问题增长：N=50 时大约抽 **9 次**就会出现重复，
///    N=1000 时也只要抽 **39 次**。所以「很快又听到前面听过的歌」是必然。
///    → 现在改为**一次性随机遍历计划**（[_plan]，Fisher–Yates 洗牌），
///    一轮里每首恰好播一次；一轮走完再重新生成，且保证新一轮第一首
///    不是刚播完那首。[PlayMode.shuffle]
///
/// 2. **「数量明显少于曲目总量」** —— 这是**曲库索引**的问题而不是播放模式
///    的问题：队列来自 `library.tracks`，而 V4 只加载了首屏 50 首
///    （见 `LibraryRepository` 的类文档）。50 首的「随机」怎么抽都会很快重复。
///    → 由 V5 的全曲库索引修复；本类不再做任何补偿。
///
/// 3. **顺序播放「最后一首」就停** —— 队列末尾是「已加载的最后一首」，
///    而 [_maybePrefetch] 只在**成功切歌之后**调用；走到末尾时命中的是
///    「保持不动」分支，预加载永远不触发，于是队列不再增长、播放停止。
///    → 现在「到达队尾」也会先尝试预加载，只有确实没有更多内容才停。
///
/// 4. **单曲循环跳到下一首** —— [PlayAdvanceAction.repeatCurrent] 走的是
///    `seek(0)` + `play()`；在 `completed` 状态下这一步在部分 ROM 上
///    不会重新起播（播放器停在末尾，UI 又是「播放中」），
///    紧接着的自然结束事件就把它推进到下一首。
///    → 现在改为**重新下发一次加载**（复用 [_playCurrent] 的串行链），
///    这是唯一在真机上被证明能起播的路径。
///
/// 5. **随机的「上一首」跑到列表前一首** —— 原 `previous()` 是
///    `_index -= 1`（队列顺序），与随机播放的**实际播放顺序**无关。
///    → 现在改为**播放历史栈**（[_history]），只记录用户操作产生的顺序，
///    与界面列表顺序无关，首曲不回绕、无记录时不动作。
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

  /// 自动推进重入闸门（见 [onTrackCompleted]）。
  ///
  /// 只用来挡「同一次自然结束被并发触发两次」，不挡连续的单次推进 ——
  /// 因此进函数立刻置位、`finally` 立刻复位。
  bool _advancing = false;

  /// 当前曲目**上次加载是否失败**。
  ///
  /// 用途：网络恢复后用户按「播放」时，引擎里**没有音源**，
  /// 直接 `_handler.play()` 什么也不会发生 —— 用户会卡住。
  /// 有了这个标记就能在 [play] 里重新下发一次加载（V2 §15
  /// 「网络恢复后用户重新播放应能够继续使用」）。
  bool _loadFailed = false;

  /// 单次自动跳过的最大尝试次数。
  static const int _maxAutoSkip = 5;

  /// 随机播放用（避免连续随机到同一首）。
  ///
  /// ⚠️ 只在**生成随机遍历计划**时使用（见 [_rebuildPlan]），
  /// 不在每次切歌时使用 —— 后者是 V4 的 bug（见类文档第 1 条）。
  ///
  /// 需求「播放模式补充要求」§5 要求「用可控的随机种子验证随机序列，
  /// 但实际使用时不固定种子」：因此这里允许测试注入固定种子
  /// （`PlaybackRepository(random: Random(42))`），生产路径永远是
  /// [newSystemRandom]（不固定种子）。
  final Random _random;

  /// 生产环境用的随机源工厂（不固定种子）。
  static Random newSystemRandom() => Random();

  // ── 随机遍历计划（V5）──────────────────────────────────────

  /// 本轮随机遍历的**曲目标识**顺序（不是下标）。
  ///
  /// ⚠️ 用 guid 而不是下标：队列会被 [appendToQueue] 追加、
  /// 被 [removeFromQueue] 删除，下标会整体漂移，而计划一旦漂移就会出现
  /// 「重复播同一首」或「整首被跳过」——这正是需求要求避免的两件事。
  List<String> _plan = const <String>[];

  /// 计划游标：下一个待播位置。
  int _planCursor = 0;

  /// 上一首的历史（V5）：**用户操作产生**的播放顺序，最新在最后。
  ///
  /// 只记录「真正开始播放过」的曲目 guid；随机播放时它与队列顺序毫无关系，
  /// 这正是需求要的语义（「对随机播放的上一首，要回到本次播放中此前那一首，
  /// 而不是队列列表里前一首」）。
  final List<String> _history = <String>[];

  /// 历史长度上限。防止长时间播放后无限增长（电视常年不关机）。
  static const int maxHistory = 200;

  /// 本次切歌的**来源**，只用于诊断日志（需求：「诊断日志记录……切歌来源」）。
  ///
  /// 取值：`set_queue` / `restore` / `manual_next` / `manual_previous` /
  /// `media_next` / `media_previous` / `auto_complete` / `auto_repeat_one` /
  /// `auto_shuffle` / `auto_wrap` / `retry` / `error_skip`。
  ///
  /// ⚠️ 只记「谁发起的」，**不含任何凭据**；也不展示在普通用户界面
  /// （只进日志与诊断页）。
  String _advanceSource = 'none';

  /// 统一状态流（供 [PlaybackControl.states]）。用同步广播以免漏掉首个订阅者。
  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);

  PlaybackRepository({
    required MusicRepository music,
    required PlaybackEngine handler,
    SecureStore? store,
    Random? random,
  })  : _music = music,
        _handler = handler,
        _store = store ?? SecureStore(),
        _random = random ?? newSystemRandom() {
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
    _advanceSource = 'restore';
    // 恢复点是「上次听的那首」，队列就是整张曲库 → 用统一的历史回填规则
    // （随机模式只放当前这首，其它模式回填队列前缀），
    // 这样「上一首」的行为与直接点这首开始播完全一致。
    _seedHistory(idx);
    _plan = const <String>[];
    _planCursor = 0;
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

  /// 是否还能「上一首」。
  ///
  /// V5 起语义改成**播放历史**：历史里至少要有「当前这首 + 上一首」两条
  /// 才可能回退（见 [_history]）。界面据此把按钮置灰，
  /// 而不是让用户按了没反应（需求：「用户没有上一首记录时，显示无操作」）。
  ///
  /// 例外：**允许边界回绕的模式**（列表循环 / 单曲循环）在队首也能「上一首」
  /// —— 需求明确要求「第一首处上一首应回到最后一首」。
  /// 随机播放**不**适用该例外（随机的上一首必须沿真实历史）。
  bool get hasPrevious {
    if (_queue.length <= 1) return false;
    if (_history.length >= 2) return true;
    return _mode.wrapOnManualPrevious;
  }

  /// 播放历史（guid，最新的在最后）。只读，供测试与诊断使用。
  List<String> get playHistory => List<String>.unmodifiable(_history);

  /// 本轮随机计划的剩余数量（供诊断/测试使用）。
  int get shuffleRemaining =>
      _planCursor >= _plan.length ? 0 : _plan.length - _planCursor;

  /// 当前曲目是否是队列里的**最后一首**（顺序播放"最后一首"判定）。
  bool get isLastInQueue => _queue.isNotEmpty && _index == _queue.length - 1;

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
  PlaybackSnapshot buildState() => PlaybackSnapshot(
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
        hasPrevious: hasPrevious,
      );

  static String sourceLabelOf(QueueSource s) => switch (s) {
        QueueSource.library => '全部歌曲',
        QueueSource.search => '搜索结果',
        QueueSource.local => '本机列表',
        QueueSource.restored => '上次播放',
      };

  String? _lastError;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  PlaybackSnapshot get state => buildState();

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
    // ⚠️ **必须先按 guid 去重**（需求：「重复条目……都要有明确处理」）。
    //
    // 不去重会有两个后果，而且都很难查：
    //   1. `_history` / 随机计划都以 **guid** 为身份，队列里同一 guid 出现两次时
    //      `indexWhere` 永远返回第一个 → 随机计划里的第二次「命中」会跳回同一首，
    //      表现为随机播放**重复**（正是本版要修掉的那个 bug）；
    //   2. 「一轮里每首恰好一次」的断言不再成立。
    // 保留**首次出现**的位置，`startIndex` 随之映射到去重后的下标。
    final List<Track> unique = <Track>[];
    final Set<String> seen = <String>{};
    for (final Track t in tracks) {
      if (t.guid.isEmpty) continue; // 无 guid 无法建立身份，宁可丢弃
      if (seen.add(t.guid)) unique.add(t);
    }
    final int dropped = tracks.length - unique.length;
    if (dropped > 0) {
      Log.w('QUEUE_SET 丢弃 $dropped 个重复/无标识条目 '
          '（${tracks.length} → ${unique.length}）');
    }

    // startIndex 是**原列表**下标 → 换算成去重后的下标。
    int mapped = -1;
    if (startIndex >= 0 && startIndex < tracks.length) {
      final String guid = tracks[startIndex].guid;
      mapped = unique.indexWhere((Track t) => t.guid == guid);
    }

    _queue = List<Track>.unmodifiable(unique);
    _source = source;
    _index = mapped;
    _consecutiveFailures = 0;
    _lastError = null;
    _advanceSource = 'set_queue';

    // ⚠️ V5：开始播放**新队列**时必须清掉上一队列的三样东西
    // （需求「播放模式补充要求」第 4 条）：
    //   · 播放历史 —— 否则「上一首」会跳回上一条队列里的歌；
    //   · 随机计划 —— 否则新队列会按旧计划的 guid 找不到任何歌（表现为随机播放停住）；
    //   · 进度 —— 由 `_playCurrent()` 重新 setAudioSource 自然重置；
    //     这里额外作废在飞的加载（`_generation` 由 `_playCurrent` 自增）。
    _history.clear();
    _plan = const <String>[];
    _planCursor = 0;

    Log.i('QUEUE_SET source=${source.storageKey} '
        'length=${_queue.length} start=$_index mode=${_mode.storageKey}');

    if (_queue.isEmpty) {
      // 空队列：必须**停掉**上一首，否则界面显示「新队列」而声音还是旧的。
      _index = -1;
      _generation++; // 作废在飞的加载
      Log.w('QUEUE_SET 空队列，停止播放并清空当前曲目');
      unawaited(_handler.stop().catchError((Object e) {
        Log.w('QUEUE_SET 停止旧音源失败（忽略）：$e');
      }));
      _safeNotify();
      return;
    }

    // 从列表中间某首开始播时，回填它**之前**的条目，使「上一首」有意义
    // （见 [_seedHistory] 的说明）。
    _seedHistory(mapped);
    if (_mode == PlayMode.shuffle) {
      _rebuildPlan();
    }
    _playCurrent();
  }

  /// 建立队列后「回填」播放历史，使队首之外的位置也能按「上一首」。
  ///
  /// ## 为什么需要这一步
  ///
  /// 需求同时要求两件事，看起来互相矛盾：
  /// - 「列表循环：第一首处上一首应回到最后一首」（⇒ 需要知道"上一条目"）
  /// - 「上一首必须回到**实际播放历史**，而不是队列列表里前一首」（随机播放）
  ///
  /// 两者的统一解释是：**历史记录的是"用户实际经过的顺序"**。
  /// 用户点列表第 30 首开始播放时，"经过的顺序"就是列表的 1..30 ——
  /// 因为他是从列表里走下来的（哪怕没听）。所以这里回填 `[0..index]`。
  ///
  /// ⚠️ **随机播放例外**：队列顺序与用户听到的顺序无关，
  /// 回填队列前缀会让「上一首」跳到"列表里前一首"，正是需求禁止的行为。
  /// 因此随机模式下历史里**只放当前这首**，等真实的播放推进再累积。
  ///
  /// ⚠️ 同样**不覆盖 [_playCurrent] 的 push**：这里只回填到 `index`（含），
  /// 随后 `_playCurrent()` 压入同一 guid 时会被"相邻重复"判据挡掉。
  void _seedHistory(int upToIndex) {
    _history.clear();
    if (_queue.isEmpty || upToIndex < 0) return;
    if (_mode == PlayMode.shuffle) {
      _pushHistory(_queue[upToIndex].guid);
      return;
    }
    // 只保留最近 [maxHistory] 条 —— 回填 3000 首没有意义，
    // 而且会让 `_history.removeRange` 的截断逻辑变成一次无谓的搬运。
    final int from = upToIndex - maxHistory + 1 > 0 ? upToIndex - maxHistory + 1 : 0;
    for (int i = from; i <= upToIndex; i++) {
      // ⚠️ **不可播放的曲目不进历史**：`_playCurrent()` 会把它跳过，
      // 若这里把它也塞进历史，「上一首」就会退到一首根本不会播的歌上，
      // 表现为「按上一首之后又跳回同一首」（用户看到的是按钮失灵）。
      if (!_queue[i].isAccessible) continue;
      _pushHistory(_queue[i].guid);
    }
  }

  /// 重新生成一轮随机遍历计划（Fisher–Yates）。
  ///
  /// [avoidFirst] 用于「一轮播完后再来一轮」：保证新一轮第一首**不是**
  /// 刚播完那首（需求：「避免连续两次听同一首」）。
  void _rebuildPlan({String? avoidFirst}) {
    final List<String> guids = <String>[
      for (final Track t in _queue)
        if (t.guid.isNotEmpty) t.guid,
    ];
    // 洗牌：Fisher–Yates，均匀分布且无偏。
    for (int i = guids.length - 1; i > 0; i--) {
      final int j = _random.nextInt(i + 1);
      final String tmp = guids[i];
      guids[i] = guids[j];
      guids[j] = tmp;
    }

    final String? currentGuid = current?.guid;
    // 当前正在播的那首**不在本轮计划内**（它已经播过了），
    // 这样「一轮里每首恰好播一次」才成立。
    final List<String> plan = <String>[
      for (final String g in guids)
        if (g != currentGuid) g,
    ];

    if (avoidFirst != null && plan.length > 1 && plan.first == avoidFirst) {
      final String tmp = plan[0];
      plan[0] = plan[1];
      plan[1] = tmp;
    }

    _plan = List<String>.unmodifiable(plan);
    _planCursor = 0;
    Log.i('SHUFFLE_PLAN 生成新遍历计划 ${_plan.length} 首'
        '（当前 ${currentGuid ?? '-'} 不参与本轮）');
  }

  /// 取下一首随机曲目在队列中的下标；计划用尽则自动开新一轮。
  int? _shuffleNextIndex() {
    if (_queue.isEmpty) return null;
    var guard = 0;
    // 计划里的 guid 可能已不在队列中（被移除）→ 跳过，最多扫一轮计划长度。
    while (guard <= _plan.length) {
      guard++;
      if (_planCursor >= _plan.length) {
        // 一轮走完：重新生成，且避开刚播完这首。
        _rebuildPlan(avoidFirst: current?.guid);
        if (_plan.isEmpty) return null; // 队列只有当前这一首
      }
      final String guid = _plan[_planCursor];
      _planCursor++;
      final int idx = _queue.indexWhere((Track t) => t.guid == guid);
      if (idx >= 0) return idx;
      Log.w('SHUFFLE_PLAN 计划中的 $guid 已不在队列，跳过');
    }
    return null;
  }

  /// 把一首曲子压入播放历史（**在离开它之前**调用）。
  void _pushHistory(String? guid) {
    if (guid == null || guid.isEmpty) return;
    if (_history.isNotEmpty && _history.last == guid) return;
    _history.add(guid);
    if (_history.length > maxHistory) {
      _history.removeRange(0, _history.length - maxHistory);
    }
  }

  /// **不改变 currentIndex**：分页加载更多时调用，正在播放的歌不会被换掉。
  int appendToQueue(List<Track> tracks) {
    if (tracks.isEmpty) return _queue.length;
    final existing = <String>{for (final t in _queue) t.guid};
    // ⚠️ **必须用显式 for 循环，不能用 `tracks.where((t) => existing.add(t.guid))`。**
    //
    // `where` 是**惰性**的，而谓词里 `existing.add(...)` 有副作用：
    // 上面的 `fresh.isEmpty` 会先消费掉第一个元素（把它的 guid 塞进 existing），
    // 随后 `[...fresh]` 第二次遍历时，同一批 guid 被判为「已存在」而全部被丢弃
    // → 追加 2 首实际只进 1 首，追加 50 首会变成隔一进一。
    // 这会让「加载第 2 页后连续播放」莫名其妙断掉，且极难排查。
    final fresh = <Track>[];
    for (final t in tracks) {
      if (t.guid.isEmpty) continue; // 无 guid 无法去重，宁可丢弃
      if (existing.add(t.guid)) fresh.add(t);
    }
    if (fresh.isEmpty) return _queue.length;
    _queue = List<Track>.unmodifiable(<Track>[..._queue, ...fresh]);

    // ⚠️ 随机模式下**必须同步更新遍历计划**（需求：「队列变化时的顺序
    //    （追加、插入、删除）也需要明确地重建或更新随机序列，
    //    避免重复或跳过」）。
    //
    // 做法：把新曲目乱序后**追加到当前计划末尾**。
    // 不重建整个计划 —— 那会让「已经播过但还没轮到的歌」重新进入本轮，
    // 造成重复；也不原样追加 —— 那会让新歌集中在最后一段按列表顺序播，
    // 削弱随机性。追加到末尾乱序，既保证本轮不重复、不跳过，
    // 又让新增曲目本轮就能轮到。
    if (_mode == PlayMode.shuffle) {
      final List<String> extra = <String>[
        for (final Track t in fresh)
          if (t.guid.isNotEmpty) t.guid,
      ];
      for (int i = extra.length - 1; i > 0; i--) {
        final int j = _random.nextInt(i + 1);
        final String tmp = extra[i];
        extra[i] = extra[j];
        extra[j] = tmp;
      }
      _plan = List<String>.unmodifiable(<String>[..._plan, ...extra]);
      Log.i('SHUFFLE_PLAN 队列追加 $extra.length 首已并入随机计划 '
          '（剩余 $shuffleRemaining）');
    }

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
    // 新队列：历史与随机计划一并清空（V5，见 [_playQueueImpl] 的说明）。
    _history.clear();
    _plan = const <String>[];
    _planCursor = 0;
    Log.i('QUEUE_ADOPT 已建立队列但未播放 total=${_queue.length}');
    _safeNotify();
  }

  @override
  Future<int> addToQueue(Track track) async {
    if (track.guid.isEmpty) return _queue.length;
    final existing = _queue.any((t) => t.guid == track.guid);
    if (existing) return _queue.length;
    _queue = List<Track>.unmodifiable(<Track>[..._queue, track]);
    // ⚠️ 随机模式下必须把新曲目并入本轮计划，否则它要等到**下一轮**
    //    重新洗牌才会被播到（用户会觉得「加了歌但随机播不到」）。
    if (_mode == PlayMode.shuffle) {
      _plan = List<String>.unmodifiable(<String>[..._plan, track.guid]);
      Log.i('SHUFFLE_PLAN 单曲入队已并入随机计划（剩余 $shuffleRemaining）');
    }
    Log.i('QUEUE_ADD guid=${track.guid} total=${_queue.length}');
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
    // 记入播放历史（去重相邻重复，因此重复按播放不会堆叠）。
    // 放在这里而不是调用方：只有**真正开始加载**的曲目才算「播放过」，
    // 被跳过/作废的请求不该进历史。
    _pushHistory(track.guid);
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
        'mode=${_mode.storageKey} source=${_source.storageKey} '
        'via=$_advanceSource queue=${_queue.length} '
        'cursor=$_planCursor/${_plan.length} history=${_history.length}');

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
      _loadFailed = true;
      _lastError = '播放失败：正在跳过这首';
      // 加载失败 = 这首**根本没播出来**，不该留在播放历史里，
      // 否则「上一首」会回退到一首放不出来的歌上。
      if (_history.isNotEmpty && _history.last == item.id) {
        _history.removeLast();
      }
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
    _loadFailed = false;
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
    // 是否还有「别的曲子」可试 —— 随机模式由计划决定（它可以一直开新轮），
    // 所以不能只看 `hasNext`。
    final bool canTryAnother = _mode == PlayMode.shuffle
        ? _queue.length > 1
        : (hasNext || _mode == PlayMode.repeatAll);
    if (!canTryAnother) {
      Log.w('PLAY_ERROR 已无可切换的曲目且加载失败，停止');
      _safeNotify();
      return;
    }
    Log.i('PLAY_SKIP_ERROR_TRACK 加载失败，自动跳下一首 '
        '($_consecutiveFailures/$_maxAutoSkip) mode=${_mode.storageKey}');
    // ⚠️ 加载失败**不是**「自然播完」，所以这里走 `next()` 而不是
    //   `onTrackCompleted()`：否则单曲循环下失败会反复重播同一首，
    //   永远跳不出去（需求：「加载失败与正常播完要分开处理，
    //   单曲循环下失败不得无限重试」）。
    await next(via: 'error_skip');
  }

  @override
  Future<void> play() async {
    // 上次加载失败过（网络/文件问题）→ 引擎里没有音源，
    // 直接 play() 不会有任何声音，用户会以为按钮坏了。
    // 这里重新下发一次加载，让「网络恢复后按播放」真的能继续听。
    if (_loadFailed && current != null) {
      final t = current!;
      Log.i('PLAY_RETRY 重新加载当前曲目 guid=${t.guid}');
      _advanceSource = 'retry';
      _playCurrent();
      return;
    }
    await _handler.play();
    _safeNotify();
  }

  @override
  Future<void> pause() async {
    await _handler.pause();
    _safeNotify();
  }

  @override
  Future<void> togglePlay() async {
    if (_handler.isPlaying) {
      await _handler.pause();
    } else {
      await _handler.play();
    }
    _safeNotify();
  }

  /// 下一首。末尾行为取决于播放模式：
  /// - 随机 → 取**本轮随机遍历计划**的下一首（每首恰好一次，走完再开一轮）；
  /// - 列表循环 / 单曲循环 → 回绕到第一首；
  /// - 顺序播放 → 保持不动（不崩溃）。
  ///
  /// [via] 只是**诊断日志的来源标记**（页面按钮 / 媒体键 / 手机遥控），
  /// 不影响任何行为 —— 三条入口必须走同一份逻辑，这正是本类的核心约束。
  ///
  /// ⚠️ V5：随机分支**不再**用 `Random.nextInt` 有放回取样（见类文档第 1 条）。
  @override
  Future<void> next({String via = 'manual_next'}) async {
    if (_queue.isEmpty) return;

    // 队列只有一首：**只有会循环的模式**才「从头重播」。
    // 需求：「队列中只有一首时，上一首/下一首都从头播放这首」（单曲循环/列表循环），
    // 但顺序播放的语义是「末首不重新开始整队列」——只有一首时那就是整队列，
    // 所以必须是**无操作**而不是重播。
    if (_queue.length == 1) {
      if (_mode == PlayMode.sequence) {
        Log.i('SKIP_NEXT 队列仅一首且顺序播放，无操作');
        _safeNotify();
        return;
      }
      Log.i('SKIP_NEXT 队列仅一首（mode=${_mode.storageKey}），从头重播');
      _advanceSource = '${via}_single';
      _playCurrent();
      return;
    }

    if (_mode == PlayMode.shuffle) {
      final int? target = _shuffleNextIndex();
      if (target == null) {
        Log.i('SKIP_NEXT 随机计划为空，保持当前曲目');
        _safeNotify();
        return;
      }
      _index = target;
      _advanceSource = '$via_shuffle';
      Log.i('SKIP_NEXT 随机计划 → index=$_index guid=${_queue[_index].guid} '
          '剩余 ${shuffleRemaining}');
      _playCurrent();
      unawaited(_maybePrefetch());
      return;
    }

    if (_index < _queue.length - 1) {
      _index += 1;
      _advanceSource = via;
      Log.i('SKIP_NEXT index=$_index guid=${_queue[_index].guid}');
      _playCurrent();
      unawaited(_maybePrefetch());
    } else if (_mode.wrapOnManualNext) {
      _index = 0;
      _advanceSource = '${via}_wrap';
      Log.i('SKIP_NEXT 回绕到队首 index=0 mode=${_mode.storageKey}');
      _playCurrent();
    } else {
      // 队尾：**先尝试预加载**再决定停不停。
      // ⚠️ V5 修复：V4 在这里直接 `_safeNotify()` 返回，于是「曲库还有下一页」
      //    时也不会去取 —— 表现就是「顺序播放到最后一首就停」，
      //    而那个「最后一首」其实只是**已加载的最后一首**。
      Log.i('SKIP_NEXT 已到队尾 index=$_index，尝试预加载后续内容');
      final bool grew = await _maybePrefetch();
      if (grew && _index < _queue.length - 1) {
        _index += 1;
        _advanceSource = '${via}_prefetch';
        Log.i('SKIP_NEXT 预加载成功，继续 index=$_index');
        _playCurrent();
      } else {
        Log.i('SKIP_NEXT 确无更多内容，保持当前曲目');
        _safeNotify();
      }
    }
  }

  /// 上一首：**只走播放历史**，不依赖界面列表顺序。
  ///
  /// 需求原文（播放模式补充要求 §2）：
  /// - 「只使用用户操作产生的历史记录，不依赖界面列表顺序」；
  /// - 「无论进度和播放状态，都回到此前播放的上一首，首曲不回绕」；
  /// - 「对随机播放的上一首，要回到本次播放中此前那一首，
  ///   而不是队列列表里前一首」；
  /// - 「用户没有上一首记录时，显示无操作，不能跳到别的位置」。
  ///
  /// ⚠️ 因此这里**刻意删掉了** V4 的「播放超过 3 秒先回到本曲开头」逻辑：
  /// 那条规则会让「上一首」在两种完全不同的行为之间随机切换，
  /// 在随机播放下更是与用户的预期完全无关（历史里的上一首才是用户听到的上一首）。
  /// [via] 同 [next]：仅用于诊断日志的来源标记。
  @override
  Future<void> previous({String via = 'manual_previous'}) async {
    if (_queue.isEmpty) return;

    // 队列只有一首：只有会循环的模式才「从头重播」（理由见 [next]）。
    if (_queue.length == 1) {
      if (_mode == PlayMode.sequence) {
        Log.i('SKIP_PREVIOUS 队列仅一首且顺序播放，无操作');
        _safeNotify();
        return;
      }
      Log.i('SKIP_PREVIOUS 队列仅一首（mode=${_mode.storageKey}），从头重播');
      _advanceSource = '${via}_single';
      _playCurrent();
      return;
    }

    if (_history.length < 2) {
      // 没有上一首记录。
      // 允许边界回绕的模式（列表循环 / 单曲循环）→ 回最后一首（需求明确要求）。
      // 顺序播放 / 随机播放 → **无操作**（需求：「首曲不回绕」
      // 与「随机的上一首不得跳到列表里前一首」）。
      if (_mode.wrapOnManualPrevious) {
        _index = _queue.length - 1;
        _advanceSource = '${via}_wrap';
        Log.i('SKIP_PREVIOUS 无历史但模式允许回绕 → 队尾 index=$_index '
            'mode=${_mode.storageKey}');
        _playCurrent();
        return;
      }
      Log.i('SKIP_PREVIOUS 无播放历史（${_history.length} 条），无操作 '
          'mode=${_mode.storageKey}');
      _safeNotify();
      return;
    }

    // 弹出「当前这首」，目标就是新的最后一条。
    _history.removeLast();
    var guard = 0;
    while (_history.isNotEmpty && guard < maxHistory) {
      guard++;
      final String guid = _history.last;
      final int idx = _queue.indexWhere((Track t) => t.guid == guid);
      if (idx >= 0) {
        _index = idx;
        _advanceSource = via;
        Log.i('SKIP_PREVIOUS 历史回退 → index=$_index guid=$guid '
            '（剩余历史 ${_history.length}）');
        _playCurrent();
        _safeNotify();
        return;
      }
      // 这首已不在队列里（被移除/换队列）→ 继续往前找。
      Log.w('SKIP_PREVIOUS 历史里的 $guid 已不在队列，继续回退');
      _history.removeLast();
    }

    Log.i('SKIP_PREVIOUS 历史中已无可回退的曲目，无操作');
    _safeNotify();
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

  /// 切换播放模式。
  ///
  /// ⚠️ V5：**切换模式不重建队列**（需求：「不能随机后还在顺序播放，
  /// 整体语意要准确」—— 反过来也一样：切回顺序播放不该把队列洗乱）。
  /// 随机模式只是「改变下一首的取法」，队列本身保持原样。
  ///
  /// 进入随机时会**立即生成一轮遍历计划**；离开随机时丢弃计划
  /// （避免残留计划在下次进入随机时被误用，导致连着播旧序列里的歌）。
  @override
  Future<void> setMode(PlayMode mode) async {
    if (_mode == mode) return;
    final PlayMode previousMode = _mode;
    _mode = mode;
    Log.i('PLAY_MODE_CHANGE ${previousMode.storageKey} → ${mode.storageKey}');

    if (mode == PlayMode.shuffle) {
      _rebuildPlan();
    } else {
      _plan = const <String>[];
      _planCursor = 0;
    }

    _safeNotify();
    try {
      await _store.writePlayModeKey(mode.storageKey);
    } catch (e) {
      // 持久化失败不影响本次使用
      Log.w('PLAY_MODE_CHANGE 持久化失败：$e');
    }
  }

  // ── PlaybackCommandListener：MediaSession 与自然结束的入口 ──
  // 页面按钮调用上面的 next()/previous()，媒体键调用这里，
  // 两条路径最终都执行同一份代码，因此不存在两套队列状态。

  @override
  Future<void> onSkipToNext() => next(via: 'media_next');

  @override
  Future<void> onSkipToPrevious() => previous(via: 'media_previous');

  /// 当前曲目自然播放结束 → 按播放模式推进**一次**。
  ///
  /// 四种模式的目标语义（需求「播放模式补充要求」§（补充六））：
  ///
  /// | 模式 | 一首播完之后 |
  /// |---|---|
  /// | 顺序播放 | 播下一首；**确实是队列最后一首**时停止，不回到开头 |
  /// | 列表循环 | 播下一首；最后一首之后回到第一首，继续循环 |
  /// | 随机播放 | 按**随机遍历计划**取下一首（与手动「下一首」同一份计划） |
  /// | 单曲循环 | 当前曲**从 0:00 重新播放**，不换曲 |
  ///
  /// ## 为什么要有 [_advancing] 这个重入闸门
  ///
  /// 需求：「避免自然结束和手动切歌同时发生导致跳过多首」。
  /// 顺序播放分支里会 `await _maybePrefetch()`（可能耗时数百毫秒），
  /// 这段窗口内若又收到一次 completed（快进到结尾、ROM 重复派发），
  /// 两次推进就会叠加成「一次跳两首」。
  /// 闸门只挡**并发**，不挡正常的连续单次推进。
  @override
  Future<void> onTrackCompleted() async {
    if (_advancing) {
      Log.i('AUTO_NEXT 上一次自动推进尚未结束，忽略重复的 completed');
      return;
    }
    _advancing = true;
    try {
      await _handleCompleted();
    } finally {
      _advancing = false;
    }
  }

  Future<void> _handleCompleted() async {
    Log.i('PLAY_COMPLETED index=$_index mode=${_mode.storageKey} '
        'queue=${_queue.length}');
    _consecutiveFailures = 0;

    // 空队列（用户清空了队列 / 队列来源被删光）：没有任何"下一首"可言。
    // 放在最前面，避免 `wrapToFirst` 分支把 `_index` 设成 0 而队列是空的。
    if (_queue.isEmpty) {
      Log.i('PLAY_COMPLETED 队列为空，无操作');
      _safeNotify();
      return;
    }

    switch (_mode.onCompleted) {
      case PlayAdvanceAction.stop:
        if (hasNext) {
          Log.i('AUTO_NEXT index=$_index → ${_index + 1}');
          await next(via: 'auto_next');
          return;
        }
        // 队列里的最后一首 —— 但队列可能只是「已加载的最后一首」，
        // 先尝试预加载，真的没有更多才停（V5 修复，见类文档第 3 条）。
        final bool grew = await _maybePrefetch();
        if (grew && _index < _queue.length - 1) {
          Log.i('AUTO_NEXT 预加载到新曲目，继续 index=${_index + 1}');
          await next(via: 'auto_next_prefetch');
          return;
        }
        Log.i('AUTO_NEXT 顺序播放且确认已是队尾，停在 completed（不回第一首）');
        _safeNotify();
        return;

      case PlayAdvanceAction.wrapToFirst:
        // 列表循环：即使「当前是最后一首」也要回到第一首继续循环。
        // 队列只有一首时「回到第一首」= 重播这首，同样是正确行为。
        _index = 0;
        _advanceSource = 'auto_wrap';
        Log.i('AUTO_NEXT 列表循环 → 队首 index=0');
        _playCurrent();
        unawaited(_maybePrefetch());
        return;

      case PlayAdvanceAction.repeatCurrent:
        // 单曲循环：**重新下发一次加载**，而不是 seek(0)+play()。
        //
        // ⚠️ V5 修复（类文档第 4 条）：`completed` 状态下 `seek(0)` 之后
        //    `play()` 在部分 ROM 上不会重新起播，播放器停在末尾、
        //    界面却显示「播放中」，紧接着就出现「单曲循环跳下一首」。
        //    走 [_playCurrent] 会复用串行链与 generation 令牌，
        //    是唯一在真机上被证明能起播的路径；它把进度重置为 0，
        //    因此语义上就是「从 0 秒重新播放同一首」。
        //
        // ⚠️ 这里**不修改 `_index`、不 push 历史**（同一首不算"去过新地方"），
        //    所以无论循环多少次，历史长度都不变。
        _advanceSource = 'auto_repeat_one';
        Log.i('AUTO_NEXT 单曲循环 → 从 0:00 重新加载当前曲 index=$_index '
            'guid=${current?.guid ?? '-'}');
        _playCurrent();
        return;

      case PlayAdvanceAction.pickRandom:
        // 队列只有一首：一轮就等于这一首 → 循环它（需求「随机默认整轮循环」）。
        if (_queue.length <= 1) {
          _advanceSource = 'auto_shuffle_single';
          Log.i('AUTO_NEXT 随机播放且队列仅一首 → 重新播放该曲');
          _playCurrent();
          return;
        }
        final int? target = _shuffleNextIndex();
        if (target == null) {
          Log.i('AUTO_NEXT 随机计划为空，保持当前曲目');
          _safeNotify();
          return;
        }
        Log.i('AUTO_NEXT 随机计划 → index=$_index → $target '
            '（剩余 $shuffleRemaining）');
        _index = target;
        _advanceSource = 'auto_shuffle';
        _playCurrent();
        unawaited(_maybePrefetch());
        return;
    }
  }

  /// 播放推进后若接近队尾则触发预加载（跨分页连续播放的关键）。
  ///
  /// 返回 [Future] 以便调用处写 `unawaited(...)`；`prefetchMore()` 内部
  /// 已有防重入，重复调用不会产生并发请求。
  Future<bool> _maybePrefetch() => prefetchMore();
}
