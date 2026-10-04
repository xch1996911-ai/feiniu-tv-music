import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:feiniu_tv_music/playback/playback_port.dart';

/// 一次「加载并播放」的记录，用于断言实际下发了什么。
class RecordedLoad {
  final String url;
  final Map<String, String> headers;
  final MediaItem item;

  RecordedLoad(this.url, this.headers, this.item);

  @override
  String toString() => 'RecordedLoad(${item.id}, $url)';
}

/// 离线假引擎：让队列逻辑能在**无 Android 平台**的单元测试里被验证。
///
/// 真实 `PlaybackHandler` 内部 `AudioPlayer()` 依赖 ExoPlayer/AVPlayer，
/// 纯 Dart 测试无法实例化，因此队列语义（自动下一首、失效跳过、竞态、边界）
/// 全部改用本假实现断言。生产路径不受影响。
class FakePlaybackEngine implements PlaybackEngine {
  /// 记录每一次真正下发的加载（被 generation 判定为过期的不会进来）。
  final List<RecordedLoad> loads = <RecordedLoad>[];

  /// 收到过的 MediaSession 传输键调用次数。
  int skipNextCalls = 0;
  int skipPreviousCalls = 0;

  final StreamController<void> _stateChanges = StreamController<void>.broadcast();
  /// ⚠️ 必须是 **sync** 广播流：控制器在 `setUp`（root Zone）里创建，
  ///    异步广播会把监听回调排进 **root Zone 的微任务队列** ——
  ///    `testWidgets` 的假时钟永远不推进它，于是「setPosition 之后
  ///    pump 两帧」收不到任何进度事件（实测 H/I/J/L 四条全因此挂）。
  ///    `sync: true` 让 `_emit()` 的派发与调用方同 zone 同步完成，
  ///    与真机「seek 时 just_audio 立即回调」的时序语义一致。
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast(sync: true);

  PlaybackCommandListener? _listener;

  /// 当前是否处于「播放中」。
  bool playing = false;

  Duration _position = Duration.zero;

  /// 曲目时长。固定值：测试只关心「队列语义」，不模拟真实时长变化。
  final Duration _duration = const Duration(minutes: 3);

  /// 按曲目 id 定制的加载延迟。用于构造「旧请求后返回」的竞态场景。
  final Map<String, Duration> loadDelays = <String, Duration>{};

  /// 未命中 [loadDelays] 时使用的默认延迟。
  ///
  /// 固定为 0：需要延迟的场景一律用 [loadDelays] 按曲目 id 精确指定。
  final Duration defaultLoadDelay = Duration.zero;

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  int seekCalls = 0;
  final List<Duration> seeks = <Duration>[];

  /// 让 loadAndPlay 抛异常（模拟 URL 失效 / 网络错误）。
  bool failLoad = false;

  /// 最近一次成功 load 的媒体项。
  MediaItem? currentItem;

  @override
  set commandListener(PlaybackCommandListener listener) => _listener = listener;

  /// 已装配的队列控制回调（验证 MediaSession → Repository 桥接确实装上了）。
  PlaybackCommandListener? get listener => _listener;

  @override
  Stream<void> get stateChanges => _stateChanges.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  bool get isPlaying => playing;

  @override
  Duration? get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  Future<void> loadAndPlay({
    required String url,
    required Map<String, String> headers,
    required MediaItem item,
  }) async {
    final delay = loadDelays[item.id] ?? defaultLoadDelay;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (failLoad) {
      throw StateError('模拟加载失败: ${item.id}');
    }
    loads.add(RecordedLoad(url, headers, item));
    currentItem = item;
    playing = true;
    _position = Duration.zero;
    // ⚠️ 本方法**只代表「换源完成」**，绝不等整首歌播完 ——
    //    真实 `PlaybackHandler.loadAndPlay` 亦然（见 `PlaybackLauncher`）。
    //    [playbackSessions] 记录「仍在挂着的播放会话」，
    //    用于断言「切歌不依赖上一首的播放生命周期」。
    playbackSessions.add(item.id);
    _emit();
  }

  /// 仍未结束的「播放会话」（真实 just_audio 的 `play()` Future 只在
  /// **播放结束 / 暂停 / 停止**时完成）。
  ///
  /// ## 为什么要在假引擎里显式建模它
  /// 旧引擎写成 `await _player.play()`，于是 A 的播放会话未结束时，
  /// B 的 `setAudioSource` 会被串行链挡在后面 —— 表现就是
  /// 「界面是 B、耳朵里还是 A」。测试必须能表达「A 的会话还挂着的**同时**
  /// 已经换到了 B」，否则这条回归永远测不出来。
  final Set<String> playbackSessions = <String>{};

  /// 模拟「播放期间」的异常（网络中断 / 解码失败）。
  ///
  /// 真实链路：`PlaybackHandler` 里那个**不被 await** 的 `play()` Future
  /// 失败 → `PlaybackLauncher` 的错误通道 → `PlaybackCommandListener.onPlaybackError`
  /// → 仓储置错误态（界面可见）。这里直接走最后一步，验证界面可见性。
  void simulatePlaybackError(Object error) {
    _listener?.onPlaybackError(error, StackTrace.current);
  }

  @override
  Future<void> play() async {
    playCalls++;
    playing = true;
    _emit();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
    // 暂停会结束当前播放会话（just_audio 语义）。
    playbackSessions.clear();
    _emit();
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    seeks.add(position);
    _position = position;
    _emit();
  }

  /// stopSession 被调用的次数（断言「退出并停止」确实走了这条路径）。
  int stopSessionCalls = 0;

  @override
  Future<void> stopSession() async {
    stopSessionCalls++;
    await stop();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    playing = false;
    playbackSessions.clear();
    _emit();
  }

  /// 模拟 MediaSession 的「下一曲」媒体键。
  Future<void> mediaKeyNext() async {
    skipNextCalls++;
    await _listener?.onSkipToNext();
  }

  /// 模拟 MediaSession 的「上一曲」媒体键。
  Future<void> mediaKeyPrevious() async {
    skipPreviousCalls++;
    await _listener?.onSkipToPrevious();
  }

  /// 模拟当前曲目**自然播放结束**（对应真实引擎 completed 状态的边沿）。
  Future<void> simulateTrackCompleted() async {
    playing = false;
    playbackSessions.clear(); // 播完 = 会话结束
    _position = _duration;
    _emit();
    await _listener?.onTrackCompleted();
  }

  /// 手动设置当前位置（用于「播放超过 3 秒则上一首回到开头」这条语义）。
  ///
  /// ⚠️ 必须向 [positionStream] 发值：真机上的 just_audio 在 **seek 时会立即
  /// 发一个进度值**（这正是「seek 后歌词立即跟随」的依据）。
  /// 假引擎不发值的话，订阅进度流的组件在测试里就永远收不到 seek，
  /// 与真机行为不一致。
  void setPosition(Duration position) {
    _position = position;
    _emit();
  }

  /// 当前真正在播放的曲目 id（用于断言「界面与实际播放一致」）。
  String? get playingId => currentItem?.id;

  void _emit() {
    if (!_stateChanges.isClosed) {
      _stateChanges.add(null);
    }
    if (!_positions.isClosed) {
      _positions.add(_position);
    }
  }

  Future<void> close() async {
    await _stateChanges.close();
    await _positions.close();
  }
}
