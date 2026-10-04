/// 播放启动器：把「**触发播放**」与「**等待整首播完**」彻底解耦。
///
/// ## 为什么必须单独抽出来（这是一个真实事故的根因）
///
/// `just_audio` 的 `AudioPlayer.play()` 返回的 Future **不是在播放开始时完成**，
/// 而是在**播放结束 / 被暂停 / 被停止**时才完成（官方文档明确区分
/// 「不等待播完的 `player.play()`」与「等待播完的 `await player.play()`」）。
///
/// 旧实现写的是：
///
/// ```dart
/// await _player.setAudioSource(...);
/// await _player.play();          // ← 一直挂到 A 播完
/// ```
///
/// 而 `PlaybackRepository` 的加载链是串行的（`_loadChain.then(_load)`），
/// 于是：**A 正在播放时点 B，B 的 `setAudioSource` 会被排在 A 的 play() 后面**；
/// 在 A 播完（或被暂停）之前，真正的换源根本不会执行。
/// 与此同时仓储已把「当前曲目」改成 B ⇒ 用户看到的就是
/// **「界面/歌词是 B，耳朵里还是 A」**。
///
/// 本类只做一件事：`launch()` 调 `play()` 之后**立刻返回**，
/// 但绝不把那个 Future 的异常丢掉 —— 用独立的错误通道上报，
/// 并且只有在「这次会话仍是当前会话」时才上报（迟到的旧会话异常直接丢弃）。
///
/// 这样 `_loadChain` 只串行化「设置/替换音源」这一关键阶段，
/// 不再被任何一首歌的播放生命周期占住。
class PlaybackLauncher {
  /// 当前会话号。每次 [launch] / [invalidate] 自增。
  int _session = 0;

  /// 当前会话号（测试断言「过期会话的异常被丢弃」用）。
  int get sessionId => _session;

  /// 启动一次播放：调用 [play] 并**立即返回**，不等它的 Future 结束。
  ///
  /// - [play] **同步抛出**的异常 → 立刻转交 [onError]（同样不吞）。
  /// - [play] 返回的 Future 完成（正常结束）→ 什么都不做，
  ///   「播完了」这一业务语义由引擎的 `completed` 状态跃迁单独派发；
  /// - [play] 返回的 Future **失败**（播放期间网络中断、解码失败等）→
  ///   若这次会话仍是最新且 [isCurrent] 成立，转交 [onError]；
  ///   否则视为过期会话，直接丢弃（否则会给用户弹出已经无效的错误）。
  void launch(
    Future<void> Function() play, {
    required void Function(Object error, StackTrace stack) onError,
    bool Function()? isCurrent,
  }) {
    final int gen = ++_session;
    Future<void> running;
    try {
      running = play();
    } catch (e, st) {
      // 同步抛出：不能吞，也不能让调用方以为「已经开播了」。
      onError(e, st);
      return;
    }
    running.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        // 过期会话的异常必须丢弃：用户已经点了别的歌，
        // 这时弹「上一首播放失败」只会让人以为新歌也坏了。
        if (gen != _session) return;
        if (isCurrent != null && !isCurrent()) return;
        onError(e, st);
      },
    );
  }

  /// 作废当前会话（停止播放 / 结束会话时调用）。
  ///
  /// 之后到达的异常一律按过期处理，不再上报。
  void invalidate() {
    _session++;
  }

  /// 全部未完成会话的数量（**仅测试用**，用于断言「没有被等待」）。
  ///
  /// 生产路径不读这个值。
  int get launchedSessions => _session;
}
