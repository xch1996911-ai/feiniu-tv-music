import '../domain/track.dart';

/// 播放模式。
///
/// 语义在 [mode] 各自的文档注释里写死，UI 与控制层共用同一套定义，
/// 避免「UI 显示的和实际行为不一致」。
enum PlayMode {
  /// 顺序播放：最后一首结束 → 停在 completed，**不**回到第一首。
  sequence,

  /// 列表循环：最后一首结束 → 自动回第一首。
  repeatAll,

  /// 单曲循环：当前曲结束 → 从 0:00 重播同一首。
  repeatOne,

  /// 随机播放：随机选下一首，尽量避免连续随机到同一首。
  shuffle,
}

extension PlayModeX on PlayMode {
  /// 持久化用的稳定字符串（**不要**用 `index` 或 `name`：
  /// 将来调整枚举顺序会让已存的用户设置全部错位）。
  String get storageKey => switch (this) {
        PlayMode.sequence => 'sequence',
        PlayMode.repeatAll => 'repeat_all',
        PlayMode.repeatOne => 'repeat_one',
        PlayMode.shuffle => 'shuffle',
      };

  /// 解析持久化值；未知值一律降级为 [PlayMode.sequence]（不抛异常）。
  static PlayMode fromStorage(String? raw) {
    for (final m in PlayMode.values) {
      if (m.storageKey == raw) return m;
    }
    return PlayMode.sequence;
  }

  String get label => switch (this) {
        PlayMode.sequence => '顺序播放',
        PlayMode.repeatAll => '列表循环',
        PlayMode.repeatOne => '单曲循环',
        PlayMode.shuffle => '随机播放',
      };

  /// 电视端显示用的短标签。
  String get shortLabel => switch (this) {
        PlayMode.sequence => '顺序',
        PlayMode.repeatAll => '列表循环',
        PlayMode.repeatOne => '单曲',
        PlayMode.shuffle => '随机',
      };

  /// 播放模式下一次「自然结束」之后该做什么。
  ///
  /// - [PlayAdvanceAction.stop]：停在最后一首（不循环）
  /// - [PlayAdvanceAction.wrapToFirst]：回到第一首
  /// - [PlayAdvanceAction.repeatCurrent]：重播当前首
  /// - [PlayAdvanceAction.pickRandom]：随机下一首
  PlayAdvanceAction get onCompleted => switch (this) {
        PlayMode.sequence => PlayAdvanceAction.stop,
        PlayMode.repeatAll => PlayAdvanceAction.wrapToFirst,
        PlayMode.repeatOne => PlayAdvanceAction.repeatCurrent,
        PlayMode.shuffle => PlayAdvanceAction.pickRandom,
      };

  /// 手动按「下一首」时是否允许在末尾回绕。
  ///
  /// 只有 [PlayMode.repeatAll] 与 [PlayMode.shuffle] 回绕；
  /// 顺序播放与单曲循环在末尾按下一首保持不动（避免用户以为坏了）。
  bool get wrapOnManualNext =>
      this == PlayMode.repeatAll || this == PlayMode.shuffle;
}

/// 自然播放结束后队列推进的动作。
enum PlayAdvanceAction { stop, wrapToFirst, repeatCurrent, pickRandom }

/// 播放队列的来源。
///
/// 用途：
/// 1. 让 UI 知道「当前在放谁」；
/// 2. 避免搜索结果队列污染全部歌曲队列（两者是**独立**的队列快照）。
enum QueueSource {
  /// 全部歌曲（曲库）。
  library,

  /// 搜索结果。
  search,

  /// 恢复自上次会话。
  restored,
}

extension QueueSourceX on QueueSource {
  /// 日志用的稳定短标识。
  String get storageKey => switch (this) {
        QueueSource.library => 'library',
        QueueSource.search => 'search',
        QueueSource.restored => 'restored',
      };
}

/// 统一播放控制层对外暴露的**不可变状态快照**。
///
/// ## 为什么不直接暴露 `PlaybackRepository`
///
/// 这是 V2 最重要的架构约束：**UI 只能通过控制层操作播放**，
/// 永远不要绕过它去摸 `AudioPlayer` / `PlaybackHandler`。
///
/// 理由：手机端远程控制（V3）需要在**任何进程/页面**下都能下发命令并回读状态。
/// 只要 UI 与未来的手机控制都走同一个接口，
/// V3 只需再加一个 HTTP / WebSocket 适配器（把 JSON 映射到这些方法），
/// **UI 与业务层一行都不用改**。
class PlaybackSnapshot {
  final QueueSource source;

  /// 队列来源在 UI 上显示的名字（如「搜索结果」）。
  final String sourceLabel;

  final List<Track> queue;

  final int currentIndex;

  final Track? currentSong;

  final bool isPlaying;

  final Duration position;

  final Duration duration;

  final PlayMode mode;

  /// 非 null 表示当前处于错误态（如整队不可播放、网络持续失败）。
  final String? error;

  const PlaybackSnapshot({
    required this.source,
    required this.sourceLabel,
    required this.queue,
    required this.currentIndex,
    required this.currentSong,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.mode,
    this.error,
  });

  static const PlaybackSnapshot empty = PlaybackSnapshot(
    source: QueueSource.library,
    sourceLabel: '全部歌曲',
    queue: <Track>[],
    currentIndex: -1,
    currentSong: null,
    isPlaying: false,
    position: Duration.zero,
    duration: Duration.zero,
    mode: PlayMode.sequence,
  );

  bool get hasSong => currentSong != null;

  int get length => queue.length;

  /// 是否有下一首（考虑播放模式的回绕规则）。
  bool get hasNextByMode {
    if (queue.isEmpty) return false;
    return mode.wrapOnManualNext || currentIndex < queue.length - 1;
  }

  @override
  String toString() =>
      'PlaybackSnapshot($sourceLabel ${currentIndex + 1}/$length '
      'playing=$isPlaying mode=${mode.storageKey})';
}

/// 统一播放控制接口。
///
/// **UI 与未来的手机端都必须只依赖这个接口。**
///
/// 约束（V3 手机互联的前提）：
/// - 不暴露 `AudioPlayer` / `PlaybackHandler` / `PlaybackRepository`；
/// - 所有状态通过 [states] 单向流出，控制方不保存状态副本；
/// - 方法全部是「命令式」的，不返回 UI 需要自己解释的复杂结构。
abstract class PlaybackControl {
  /// 状态流。每次播放状态变化都会发出**新的完整快照**。
  Stream<PlaybackSnapshot> get states;

  /// 当前状态快照（同步读取，避免 UI 首次构建时空窗）。
  PlaybackSnapshot get state;

  // ── 传输控制 ──────────────────────────────────────────────
  Future<void> play();
  Future<void> pause();
  Future<void> togglePlay();

  /// 下一首。末尾行为由播放模式决定（顺序播放保持不动）。
  Future<void> next();

  /// 上一首。播放超过 3 秒时先回到本曲开头。
  Future<void> previous();

  /// 跳到指定位置。
  Future<void> seek(Duration position);

  // ── 队列控制 ──────────────────────────────────────────────
  /// 用给定列表替换队列并从 [startIndex] 开始播放。
  Future<void> playQueue(
    List<Track> tracks, {
    required QueueSource source,
    int startIndex = 0,
  });

  /// 在当前曲之后插入（用于「添加到队列」）。返回新队列长度。
  Future<int> addToQueue(Track track);

  /// 从队列移除。**正在播放的曲目不允许移除**，返回 false。
  Future<bool> removeFromQueue(int index);

  /// 队列接近末尾时预加载后续内容（供分页曲库注入更多歌曲）。
  ///
  /// 返回 true 表示确实发起了预加载。实现应**防重入**。
  Future<bool> prefetchMore();

  /// 告知控制层：曲库又追加了 [count] 首（分页加载完成后调用）。
  void notifyQueueExtended(int count);

  // ── 播放模式 ──────────────────────────────────────────────
  PlayMode get mode;
  Future<void> setMode(PlayMode mode);
}
