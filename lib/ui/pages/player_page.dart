import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/log.dart';
import '../../playback/playback_control.dart';
import '../../repositories/lyric_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/cover_image.dart';
import '../widgets/lyric_view.dart';

/// 正在播放页（全屏覆盖层）。
///
/// ## 职责边界（V2 §21）
/// 本页**只**做两件事：观察 [PlaybackRepository] 状态、发控制命令。
/// **不持有任何播放状态副本**（不自己存 currentIndex / isPlaying / position），
/// 也不直接触碰 `AudioPlayer`。
///
/// ## 关键实现
/// - **歌词跟随**：由 [LyricView] 内部按需刷新高亮，不用 position 流驱动
///   整页 setState（那会让整页每 200ms 重建）。
/// - **Seek**：进度条可拖动；遥控器左右键由 [Shortcuts] 接管（±5 秒），
///   并把 Slider 自身设为 `descendantsAreFocusable: false`，避免「Slider 抢死焦点」。
class PlayerPage extends StatefulWidget {
  final VoidCallback onBack;

  const PlayerPage({super.key, required this.onBack});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  /// 进度刷新定时器。⚠️ 必须在 dispose 取消（V2 §29）。
  Timer? _progressTimer;

  /// 当前已请求歌词的曲目 guid，用于检测换歌。
  String? _lyricForGuid;

  @override
  void initState() {
    super.initState();
    // 1 秒刷新一次进度显示足够（音频进度不需要 200ms 精度）
    _progressTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;
        setState(() {});
        _syncLyric();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncLyric());
  }

  @override
  void dispose() {
    // ⚠️ Timer 必须取消，否则 dispose 后 setState 会抛异常。
    _progressTimer?.cancel();
    super.dispose();
  }

  /// 换歌时加载新歌词（自动下一首后歌词要跟着换，V2 §10）。
  void _syncLyric() {
    if (!mounted) return;
    final song = context.read<PlaybackRepository>().current;
    if (song == null) {
      if (_lyricForGuid != null) {
        context.read<LyricRepository>().clear();
        _lyricForGuid = null;
      }
      return;
    }
    if (_lyricForGuid == song.guid) return;
    _lyricForGuid = song.guid;
    Log.i('LYRIC_LOAD 切歌 → ${song.guid}');
    // 刻意不 await：歌词慢不能挡住页面
    unawaited(context.read<LyricRepository>().load(song));
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackRepository>();
    final music = context.read<MusicRepository>();
    final song = playback.current;

    return Material(
      color: const Color(0xFF0B0B0F),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Row(
              children: <Widget>[
                // 左：封面 + 曲目信息
                Expanded(
                  flex: 5,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(40, 60, 16, 24),
                    child: song == null
                        ? const Center(
                            child: Text('尚未选择歌曲',
                                style: TextStyle(
                                    fontSize: 24, color: Colors.white38)),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              CoverImage(
                                music: music,
                                coverId: song.effectiveCoverId,
                                size: 340,
                                radius: 12,
                              ),
                              const SizedBox(height: 24),
                              Text(
                                song.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                song.artistNames,
                                style: const TextStyle(
                                    fontSize: 21, color: Colors.white70),
                              ),
                              Text(
                                song.album.name,
                                style: const TextStyle(
                                    fontSize: 19, color: Colors.white54),
                              ),
                              const SizedBox(height: 10),
                              // 音频格式 / bit depth / sample rate
                              Text(
                                song.audioSpec.display,
                                style: const TextStyle(
                                    fontSize: 18, color: Colors.blueAccent),
                              ),
                            ],
                          ),
                  ),
                ),
                // 右：歌词 + 进度 + 控制
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 60, 40, 24),
                    child: Column(
                      children: <Widget>[
                        const Expanded(child: LyricView()),
                        const SizedBox(height: 12),
                        _ProgressSection(playback: playback),
                        const SizedBox(height: 16),
                        _Controls(playback: playback),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 左上角返回
          Positioned(
            left: 16,
            top: 12,
            child: _RoundButton(
              icon: Icons.arrow_back,
              tooltip: '返回（音乐继续播放）',
              onPressed: widget.onBack,
            ),
          ),
          // 右上角播放模式
          Positioned(
            right: 16,
            top: 12,
            child: _ModeButton(
              mode: playback.mode,
              onPressed: () {
                final next =
                    PlayMode.values[(playback.mode.index + 1) % PlayMode.values.length];
                Log.i('PLAY_MODE_CHANGE UI ${playback.mode.name} → ${next.name}');
                playback.setMode(next);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 进度条 + 时间 + 遥控器左右键 Seek。
class _ProgressSection extends StatelessWidget {
  final PlaybackRepository playback;

  const _ProgressSection({required this.playback});

  /// 单次快退/快进。
  static const Duration _step = Duration(seconds: 5);

  @override
  Widget build(BuildContext context) {
    final pos = playback.position ?? Duration.zero;
    final dur = playback.duration ?? Duration.zero;
    final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
    final value = pos.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();

    // ⚠️ 电视端关键：Slider 默认会用左右键改变值，导致「进度条抢死焦点」，
    // 方向键在进度条上完全失效。这里显式覆盖为「±5 秒」。
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.arrowLeft): const _SeekIntent(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): const _SeekIntent(1),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SeekIntent: CallbackAction<_SeekIntent>(
            onInvoke: (intent) {
              playback.seekRelative(_step * intent.direction);
              return null;
            },
          ),
        },
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(_fmt(pos),
                    style: const TextStyle(
                        fontSize: 16, color: Colors.white54)),
                const SizedBox(width: 10),
                Expanded(
                  child: _SeekSlider(
                    value: value,
                    max: maxMs,
                    onSeek: (ms) {
                      Log.i('SEEK slider ${ms.round()}ms');
                      playback.seek(Duration(milliseconds: ms.round()));
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Text(_fmt(dur),
                    style: const TextStyle(
                        fontSize: 16, color: Colors.white54)),
              ],
            ),
            const SizedBox(height: 2),
            const Text('← → 快退/快进 5 秒',
                style: TextStyle(fontSize: 13, color: Colors.white30)),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// 快退/快进意图（direction: -1 后退 / +1 前进）。
class _SeekIntent extends Intent {
  const _SeekIntent(this.direction);
  final int direction;
}

/// 可拖动 Seek 的进度条。
class _SeekSlider extends StatefulWidget {
  final double value;
  final double max;
  final ValueChanged<double> onSeek;

  const _SeekSlider({
    required this.value,
    required this.max,
    required this.onSeek,
  });

  @override
  State<_SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<_SeekSlider> {
  /// 拖动中的本地值（拖动过程中不被外部 position 覆盖）。
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final v = _dragValue ?? widget.value;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 6,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
      ),
      child: Slider(
        value: v.clamp(0.0, widget.max),
        max: widget.max,
        onChanged: (val) => setState(() => _dragValue = val),
        // ⚠️ 只在**拖动结束**时 seek：拖动过程中不产生播放请求。
        onChangeEnd: (val) {
          widget.onSeek(val);
          setState(() => _dragValue = null);
        },
      ),
    );
  }
}

/// 播放控制按钮组。
class _Controls extends StatelessWidget {
  final PlaybackRepository playback;

  const _Controls({required this.playback});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _RoundButton(
              icon: Icons.skip_previous,
              tooltip: '上一首',
              onPressed: playback.previous,
            ),
            const SizedBox(width: 24),
            _RoundButton(
              icon: playback.isPlaying ? Icons.pause : Icons.play_arrow,
              tooltip: playback.isPlaying ? '暂停' : '播放',
              large: true,
              onPressed: playback.togglePlay,
            ),
            const SizedBox(width: 24),
            _RoundButton(
              icon: Icons.skip_next,
              tooltip: '下一首',
              onPressed: playback.next,
            ),
          ],
        ),
        // 队列来源 + 错误提示
        if (playback.state.error != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            playback.state.error!,
            style: const TextStyle(fontSize: 16, color: Colors.redAccent),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 6),
        Text(
          '队列：${playback.state.sourceLabel} · '
          '${playback.currentIndex + 1}/${playback.queue.length}',
          style: const TextStyle(fontSize: 14, color: Colors.white30),
        ),
      ],
    );
  }
}

/// 播放模式按钮。
class _ModeButton extends StatelessWidget {
  final PlayMode mode;
  final VoidCallback onPressed;

  const _ModeButton({required this.mode, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(_iconOf(mode), size: 20),
      label: Text(mode.shortLabel, style: const TextStyle(fontSize: 16)),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white12,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }

  static IconData _iconOf(PlayMode m) => switch (m) {
        PlayMode.sequence => Icons.trending_flat,
        PlayMode.repeatAll => Icons.repeat,
        PlayMode.repeatOne => Icons.repeat_one,
        PlayMode.shuffle => Icons.shuffle,
      };
}

/// 圆形控制按钮（焦点态有明显描边）。
class _RoundButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool large;

  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.large = false,
  });

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _node.dispose(); // ⚠️ 必须释放
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() => _focused = _node.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: Focus(
        focusNode: _node,
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: widget.onPressed,
            style: ElevatedButton.styleFrom(
              shape: const CircleBorder(),
              backgroundColor: _focused ? Colors.blue : Colors.white12,
              padding:
                  EdgeInsets.all(widget.large ? 20 : 14),
              side: BorderSide(
                color: _focused ? Colors.white : Colors.transparent,
                width: 3,
              ),
            ),
            child: Icon(
              widget.icon,
              size: widget.large ? 34 : 26,
            ),
          ),
        ),
      ),
    );
  }
}
