import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/lyric_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/cover_image.dart';
import '../widgets/lyric_view.dart';
import '../widgets/tv_focus.dart';

/// 正在播放页（全屏覆盖层），版式对齐参考图三。
///
/// ## 职责边界
/// 本页**只**做两件事：观察 [PlaybackRepository] 状态、发控制命令。
/// **不持有任何播放状态副本**（不自己存 currentIndex / isPlaying / position），
/// 也不直接触碰 `AudioPlayer`。
///
/// ## 三层遥控器焦点（这是本次改版的重点）
/// ```
///   第一层 · 顶部功能     [返回]                          [列表循环]
///                                     ↓
///   第二层 · 核心播放控制        [上一首]  [播放/暂停]  [下一首]
///                                     ↓
///   第三层 · 进度 / 快进快退  [ -5秒  ═════进度条════  +5秒 ]   ← 组合控件
/// ```
/// 每一条跳转都通过 [TvFocus] 的 `nextUp` / `nextDown` / `nextLeft` / `nextRight`
/// **显式指定目标节点**，不依赖框架的「就近寻找」启发式。
/// 任何一个位置都能原路返回，不存在只进不出的死区。
///
/// > 与参考图的唯一顺序差异：图三里进度条在控制键**上方**。
/// > 但验收要求「控制区按 ↓ 进入进度区、进度区按 ↑ 回到控制区」，
/// > 若进度条在上方，按 ↓ 焦点反而向上跑，遥控器体验是坏的。
/// > 因此这里把进度行放到控制行**下方**，其余版式（深绿底、大封面、
/// > 右侧歌词、圆形控制键）一律照图三。
///
/// ## 为什么控制区不会因进度刷新而丢焦点
/// 进度每秒都在变，但本页的 `build` **不订阅** position：
/// - 进度只在 [_SeekRow] 内部自刷新；
/// - 播放/暂停按钮用 `context.select` 只订阅 `isPlaying`；
/// - 播放模式按钮只订阅 `mode`；曲目信息只订阅 `current`。
///
/// 于是进度跳动时控制按钮**根本不重建**，`FocusNode` 自然不会被换掉。
class PlayerPage extends StatefulWidget {
  /// 返回（回到进入播放页之前的位置）。音乐**继续播放**。
  final VoidCallback onBack;

  const PlayerPage({super.key, required this.onBack});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  // ── 焦点节点（全部在本 State 创建并释放）────────────────────
  final FocusNode _backNode = FocusNode(debugLabel: 'player.back');
  final FocusNode _modeNode = FocusNode(debugLabel: 'player.mode');
  final FocusNode _prevNode = FocusNode(debugLabel: 'player.prev');
  final FocusNode _playNode = FocusNode(debugLabel: 'player.play');
  final FocusNode _nextNode = FocusNode(debugLabel: 'player.next');
  final FocusNode _seekNode = FocusNode(debugLabel: 'player.seek');

  /// 已请求歌词的曲目 guid，用于检测换歌。
  String? _lyricForGuid;

  /// 播放仓储引用（构造时抓一次，避免 dispose 阶段再 `context.read`）。
  late final PlaybackRepository _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackRepository>();
    // 换歌（含自动下一首）要立刻换歌词：直接监听播放仓储，
    // 比轮询定时器更及时，也不会漏掉「用户按下一首」这种瞬间切歌。
    _playback.addListener(_syncLyric);
    // 进入播放页把焦点**直接落在播放/暂停**上（验收要求）。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _playNode.requestFocus();
      _syncLyric();
    });
  }

  @override
  void dispose() {
    _playback.removeListener(_syncLyric);
    _backNode.dispose();
    _modeNode.dispose();
    _prevNode.dispose();
    _playNode.dispose();
    _nextNode.dispose();
    _seekNode.dispose();
    super.dispose();
  }

  /// 换歌时加载新歌词（自动下一首后歌词要跟着换）。
  ///
  /// 本方法会被**高频调用**（出现在播放仓储的监听链上），
  /// 因此第一件事就是比对 guid 后短路，绝不做多余工作。
  void _syncLyric() {
    if (!mounted) return;
    final Track? song = _playback.current;
    final lyrics = context.read<LyricRepository>();
    if (song == null) {
      if (_lyricForGuid != null) {
        lyrics.clear();
        _lyricForGuid = null;
      }
      return;
    }
    if (_lyricForGuid == song.guid) return;
    _lyricForGuid = song.guid;
    Log.i('LYRIC_LOAD 播放页检测到切歌 → ${song.guid}');
    // 刻意不 await：歌词慢不能挡住页面
    unawaited(lyrics.load(song));
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 只订阅「当前曲目」。进度用不着在这里监听 —— 一旦在这里 watch，
    //    进度每跳动一次整页就会重建，控件焦点与歌词视口都会跟着抖。
    final Track? song = context.select<PlaybackRepository, Track?>(
      (PlaybackRepository p) => p.current,
    );

    return Material(
      color: TvColors.stageTo,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[TvColors.stageFrom, TvColors.stageTo],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(36, 20, 36, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildTopLayer(),
                const SizedBox(height: 14),
                Expanded(
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints c) {
                      // 封面按**可用高度**自适应：小屏不会把标题挤出去，
                      // 大屏也不会留一大片空。
                      // （注意不能用 Column 里的 LayoutBuilder —— 那时
                      //   maxHeight 是 infinity，clamp 会静默退化成固定值。）
                      final double cover =
                          (c.maxHeight * 0.50).clamp(170.0, 340.0);
                      return _buildStage(song, cover);
                    },
                  ),
                ),
                const SizedBox(height: 10),
                _buildControlLayer(),
                const SizedBox(height: 14),
                _SeekRow(playbackNode: _seekNode, upNode: _playNode),
                const SizedBox(height: 8),
                const _StatusLine(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 第一层：顶部功能（返回 / 列表循环）────────────────────
  Widget _buildTopLayer() {
    final PlayMode mode = context.select<PlaybackRepository, PlayMode>(
      (PlaybackRepository p) => p.mode,
    );

    return Row(
      children: <Widget>[
        TvFocus(
          focusNode: _backNode,
          debugLabel: 'player.back',
          onPressed: widget.onBack,
          nextRight: _modeNode,
          nextDown: _prevNode,
          builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
            status: s,
            radius: 26,
            padding: EdgeInsets.zero,
            width: 52,
            height: 52,
            baseColor: const Color(0x33000000),
            child: const Icon(Icons.keyboard_arrow_down,
                size: 30, color: TvColors.text),
          ),
        ),
        const SizedBox(width: 14),
        const Spacer(),
        TvFocus(
          focusNode: _modeNode,
          debugLabel: 'player.mode',
          onPressed: () {
            final PlaybackRepository p = context.read<PlaybackRepository>();
            final PlayMode nextMode =
                PlayMode.values[(p.mode.index + 1) % PlayMode.values.length];
            Log.i('PLAY_MODE_CHANGE UI ${p.mode.name} → ${nextMode.name}');
            unawaited(p.setMode(nextMode));
          },
          nextLeft: _backNode,
          nextDown: _nextNode,
          builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
            status: s,
            radius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            baseColor: const Color(0x33000000),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(_modeIcon(mode), size: 22, color: TvColors.text),
                const SizedBox(width: 8),
                Text(
                  mode.shortLabel,
                  style: const TextStyle(fontSize: 18, color: TvColors.text),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 中部舞台：封面 + 曲目信息（左） / 歌词（右）────────────
  Widget _buildStage(Track? song, double coverSize) {
    if (song == null) {
      return const Center(
        child: Text('尚未选择歌曲',
            style: TextStyle(fontSize: 26, color: TvColors.textFaint)),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(flex: 5, child: _buildLeftPane(song, coverSize)),
        const SizedBox(width: 30),
        Expanded(flex: 4, child: _buildRightPane(song)),
      ],
    );
  }

  Widget _buildLeftPane(Track song, double coverSize) {
    final music = context.read<MusicRepository>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: CoverImage(
            music: music,
            coverId: song.effectiveCoverId,
            size: coverSize,
            radius: 16,
            iconScale: 0.3,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          song.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 36,
            height: 1.15,
            fontWeight: FontWeight.w700,
            color: TvColors.text,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            if (song.isFavorite) ...<Widget>[
              const Icon(Icons.favorite, size: 22, color: TvColors.brand),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                '${song.artistNames} · ${song.album.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 21, color: TvColors.textDim),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Chip(text: song.audioSpec.display),
      ],
    );
  }

  Widget _buildRightPane(Track song) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${song.title} - ${song.artistNames}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: TvColors.text,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          song.album.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 19, color: TvColors.textFaint),
        ),
        const SizedBox(height: 16),
        const Expanded(child: LyricView()),
      ],
    );
  }

  // ── 第二层：核心播放控制（上一首 / 播放暂停 / 下一首）────────
  Widget _buildControlLayer() {
    final bool playing = context.select<PlaybackRepository, bool>(
      (PlaybackRepository p) => p.isPlaying,
    );
    final PlaybackRepository p = context.read<PlaybackRepository>();

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        _RoundControl(
          node: _prevNode,
          debugLabel: 'player.prev',
          icon: Icons.skip_previous,
          tooltip: '上一首',
          onPressed: () {
            Log.i('SKIP_PREVIOUS (player)');
            unawaited(p.previous());
          },
          nextUp: _backNode,
          nextDown: _seekNode,
          nextLeft: _nextNode, // 环：上一首 ← 下一首，保证左右永远有去有回
          nextRight: _playNode,
        ),
        const SizedBox(width: 34),
        _RoundControl(
          node: _playNode,
          debugLabel: 'player.play',
          icon: playing ? Icons.pause : Icons.play_arrow,
          tooltip: playing ? '暂停' : '播放',
          large: true,
          onPressed: () {
            Log.i('PLAY_TOGGLE (player) → ${playing ? '暂停' : '播放'}');
            unawaited(p.togglePlay());
          },
          nextUp: _backNode,
          nextDown: _seekNode,
          nextLeft: _prevNode,
          nextRight: _nextNode,
        ),
        const SizedBox(width: 34),
        _RoundControl(
          node: _nextNode,
          debugLabel: 'player.next',
          icon: Icons.skip_next,
          tooltip: '下一首',
          onPressed: () {
            Log.i('SKIP_NEXT (player)');
            unawaited(p.next());
          },
          nextUp: _modeNode,
          nextDown: _seekNode,
          nextLeft: _playNode,
          nextRight: _prevNode,
        ),
      ],
    );
  }
}

/// 队列来源 / 当前序号 / 播放错误。既有信息，不能因为改版而丢掉。
class _StatusLine extends StatelessWidget {
  const _StatusLine();

  @override
  Widget build(BuildContext context) {
    final String label = context.select<PlaybackRepository, String>(
      (PlaybackRepository p) => '队列：${p.state.sourceLabel} · '
          '${p.currentIndex + 1}/${p.queue.length}',
    );
    final String? error = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.state.error,
    );

    return Column(
      children: <Widget>[
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, color: Color(0xFFFF8A8F)),
            ),
          ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, color: TvColors.textFaint),
        ),
      ],
    );
  }
}

/// 第三层：进度 + 快退/快进（**组合控件**）。
///
/// 整行是**一个**焦点节点：`←` / `→` 直接快退/快进 5 秒，
/// `OK` 等价于播放/暂停，`↑` 回到播放/暂停按钮。
///
/// 这样设计的原因（需求明确允许组合形式）：
/// 「方向键用于焦点移动，只有在明确设计的进度操作情形下才控制进度」——
/// 进度区就是那个「明确设计的情形」。若把进度条独立成节点并允许其内部
/// 消费左右键，就必然出现「进了进度条只能按 BACK 出来的死区」。
class _SeekRow extends StatefulWidget {
  /// 本行的焦点节点（由 PlayerPage 创建，用于串联焦点链）。
  final FocusNode playbackNode;

  /// ↑ 的去处：播放/暂停按钮。
  final FocusNode upNode;

  const _SeekRow({required this.playbackNode, required this.upNode});

  @override
  State<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<_SeekRow> {
  /// 单次快退/快进。
  static const Duration _step = Duration(seconds: 5);

  /// 进度刷新定时器。⚠️ 必须取消（dispose 后 setState 会抛异常）。
  Timer? _ticker;

  /// 拖动中的本地值（拖动过程中不被外部 position 覆盖）。
  double? _dragValue;

  /// 最近一次 ← / → 的方向（-1 后退 / 1 前进 / 0 无），用于闪一下对应按钮。
  int _flash = 0;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    // 只让这一小块每 400ms 重建 —— 控制区与歌词区因此完全不受影响。
    _ticker = Timer.periodic(
      const Duration(milliseconds: 400),
      (Timer _) {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

  void _seekBy(int direction) {
    final p = context.read<PlaybackRepository>();
    Log.i('SEEK ${direction < 0 ? '快退' : '快进'} 5 秒');
    unawaited(p.seekRelative(_step * direction));
    setState(() => _flash = direction);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 260), () {
      if (mounted) setState(() => _flash = 0);
    });
  }

  static String _fmt(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.read<PlaybackRepository>();
    final Duration pos = p.position ?? Duration.zero;
    final Duration dur = p.duration ?? Duration.zero;
    final double maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
    final double shown = (_dragValue ?? pos.inMilliseconds.toDouble())
        .clamp(0.0, maxMs);

    return TvFocus(
      focusNode: widget.playbackNode,
      debugLabel: 'player.seek',
      // ⚠️ 左右键在这块是**进度操作**，不是焦点移动 —— 这正是需求里
      //    「明确设计的进度操作情形」。它不会造成死区：↑ 始终能回控制区。
      onArrowLeft: () => _seekBy(-1),
      onArrowRight: () => _seekBy(1),
      onPressed: () => unawaited(p.togglePlay()),
      nextUp: widget.upNode,
      // 进度区已经是**最下一层**：↓ 指回自己 = 「原地不动」。
      // 显式写成自己而不是留空，是为了避免框架的方向遍历把焦点
      // 甩到某个不可预期的节点上（那正是「按 ↓ 焦点就不见了」的来源）。
      nextDown: widget.playbackNode,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        focusColor: const Color(0x33FFFFFF),
        ringColor: TvColors.focusRing,
        child: Row(
          children: <Widget>[
            _SeekChip(
              icon: Icons.fast_rewind,
              label: '5秒',
              highlighted: _flash < 0,
            ),
            const SizedBox(width: 12),
            Text(
              _fmt(Duration(milliseconds: shown.round())),
              style: const TextStyle(fontSize: 18, color: TvColors.textDim),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ExcludeFocus(
                // 进度条自身**绝不获焦**：否则 Material 的 Slider 会吃掉方向键，
                // 把焦点锁在进度条上（这正是「进了进度区就出不来」的根因）。
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 7,
                    activeTrackColor: TvColors.focusRing,
                    inactiveTrackColor: const Color(0x40FFFFFF),
                    thumbColor: Colors.white,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 9),
                  ),
                  child: Slider(
                    value: shown,
                    max: maxMs,
                    onChanged: (double v) => setState(() => _dragValue = v),
                    // 只在拖动结束时 seek：拖动过程不产生播放请求。
                    onChangeEnd: (double v) {
                      Log.i('SEEK slider ${v.round()}ms');
                      unawaited(p.seek(Duration(milliseconds: v.round())));
                      setState(() => _dragValue = null);
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _fmt(dur),
              style: const TextStyle(fontSize: 18, color: TvColors.textDim),
            ),
            const SizedBox(width: 12),
            _SeekChip(
              icon: Icons.fast_forward,
              label: '5秒',
              trailing: true,
              highlighted: _flash > 0,
            ),
          ],
        ),
      ),
    );
  }
}

/// 快退 / 快进 5 秒的视觉提示（被 ← / → 触发时点亮）。
///
/// 刻意做成**不可聚焦**的提示块：真正的操作热区是整个 [_SeekRow]。
/// 这样「看得见的按钮」和「按得动的位置」是同一块区域，不会出现
/// 「看着有个按钮但焦点进不去」的困惑。
class _SeekChip extends StatelessWidget {
  const _SeekChip({
    required this.icon,
    required this.label,
    required this.highlighted,
    this.trailing = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  /// true 表示图标在文字右侧（快进）。
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    final Color color =
        highlighted ? TvColors.focusRing : TvColors.textFaint;
    final Widget iconWidget = Icon(icon, size: 24, color: color);
    final Widget textWidget = Text(
      label,
      style: TextStyle(fontSize: 16, color: color),
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlighted ? const Color(0x33FFFFFF) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: trailing
            ? <Widget>[textWidget, const SizedBox(width: 6), iconWidget]
            : <Widget>[iconWidget, const SizedBox(width: 6), textWidget],
      ),
    );
  }
}

/// 圆形播放控制键。
///
/// ⚠️ **不要用 `ElevatedButton` / `IconButton`**：它们内部各自持有 FocusNode，
/// 与本组件的焦点节点互相打架，会出现「高亮在这个按钮上但 OK 按不动」
/// 或「按得动但没有高亮」——这正是本次要修的故障。这里用纯 `Container` +
/// [TvFocus]，焦点节点唯一、行为完全可控。
class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.node,
    required this.debugLabel,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.nextUp,
    required this.nextDown,
    this.nextLeft,
    this.nextRight,
    this.large = false,
  });

  final FocusNode node;
  final String debugLabel;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final FocusNode nextUp;
  final FocusNode nextDown;
  final FocusNode? nextLeft;
  final FocusNode? nextRight;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final double box = large ? 84 : 68;
    return TvFocus(
      focusNode: node,
      debugLabel: debugLabel,
      onPressed: onPressed,
      nextUp: nextUp,
      nextDown: nextDown,
      nextLeft: nextLeft,
      nextRight: nextRight,
      builder: (BuildContext context, TvFocusStatus s) => Tooltip(
        message: tooltip,
        child: SizedBox(
          width: box,
          height: box,
          child: TvFocusRing(
            status: s,
            radius: box / 2,
            padding: EdgeInsets.zero,
            width: box,
            height: box,
            baseColor: const Color(0x33FFFFFF),
            child: Icon(
              icon,
              size: large ? 42 : 32,
              color: TvColors.text,
            ),
          ),
        ),
      ),
    );
  }
}

/// 规格 / 属性小胶囊。
class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 16,
          color: TvColors.text,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

IconData _modeIcon(PlayMode m) => switch (m) {
      PlayMode.sequence => Icons.trending_flat,
      PlayMode.repeatAll => Icons.repeat,
      PlayMode.repeatOne => Icons.repeat_one,
      PlayMode.shuffle => Icons.shuffle,
    };
