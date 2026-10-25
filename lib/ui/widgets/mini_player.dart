import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import 'cover_image.dart';
import 'tv_focus.dart';
import 'tv_glass.dart';

/// 底部迷你播放器（UI 2.0：悬浮毛玻璃条 + 细进度线）。
///
/// ## 焦点顺序（**固定 5 步**，不得扩展）
/// ```
///   [封面] → [上一首] → [播放/暂停] → [下一首] → [队列]
///    ↑ OK = 打开完整播放页
/// ```
/// - **默认焦点落在左侧封面**（不是歌曲文字）：封面是整条里最大的目标，
///   电视上最容易命中，且「点封面进播放页」是用户的本能预期；
/// - 歌曲名 / 歌手**只展示、不可聚焦** —— 否则焦点会停在文字上，
///   按 OK 什么也不发生（文字没有动作），用户会以为遥控器坏了；
/// - 队列按钮打开的是**同一份**当前队列（与播放页里那个是同一个面板）。
///
/// ## UI 2.0 新增的收藏 / 播放模式为什么走「次级层」
/// 参考图里底部条有 8–9 个按钮。若照抄，用户从封面按到队列要按 8 下 ——
/// 电视上这是灾难。因此：
/// - 主链**仍然只有 5 段**；
/// - 收藏 / 播放模式 / 播放队列收进一个**毛玻璃小菜单**，
///   入口是主链最后一格「队列/更多」按 OK；
/// - 系统音量交给电视遥控器，不新增软件音量。
///
/// ## ⚠️ UP 就是 UP
/// 实机 Bug：Mini Player 上按 ↑ 会弹出「收藏 / 模式」条。
/// 方向键是**空间导航键**，不能兼任「展开菜单」——
/// 否则用户永远无法预测这一下 ↑ 是移动焦点还是打开面板。
/// 现在五个主键的 ↑ **一律**回正文（[onReturnToContent]），
/// ↓ 到底（没有更低层）就留在原地，不触发任何面板。
/// 次级菜单只由 OK 打开、由 BACK 关闭，与方向键彻底解耦。
///
/// ## 为什么进度条不进焦点链
/// 进度条是**只读展示**。一旦可聚焦，用户按左右键会期待 seek，
/// 而底部条没有逐秒 seek 的语义（那是播放页进度区的职责），
/// 结果必然是「按了没反应」。
///
/// ## 节点归属
/// 五个主 `FocusNode` **由 AppShell 创建并释放**（不在这里建）：
/// 关闭全屏播放页后要把焦点**恢复**到底部播放条上，
/// 而 Shell 是唯一知道「播放页刚被关掉」的地方。
/// 次级菜单的三个节点由本 State 自己创建并释放。
///
/// ⚠️ 这是**固定高度行**，里面的每个 `Text` 都必须显式写 `height`：
/// M3 主题的 `DefaultTextStyle` 行高是 **1.43**（不是 1.0），
/// 18 号字不写 height 会占 26px 而不是 22px —— 两行文字加起来就把
/// 高度撑爆，表现为 `RenderFlex overflowed`（电视上是黄黑条纹）。
const double _miniHeight = 76;

/// 行高倍率。⚠️ 「字号 × 行高」必须是整数（Flutter 逐行向上取整）。
const double _textHeight = 1.2;

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({
    super.key,
    required this.onOpenPlayer,
    required this.onOpenQueue,
    required this.onReturnToContent,
    required this.coverNode,
    required this.prevNode,
    required this.playNode,
    required this.nextNode,
    required this.queueNode,
  });

  final VoidCallback onOpenPlayer;
  final VoidCallback onOpenQueue;

  /// ↑ 的去处：回到正文里**进入底部条之前**的那个焦点。
  ///
  /// 由 Shell 提供 —— 只有它知道当前舞台是哪个页面、
  /// 以及正文里最后获得焦点的是哪一项（见 `StageFocus`）。
  final VoidCallback onReturnToContent;

  final FocusNode coverNode;
  final FocusNode prevNode;
  final FocusNode playNode;
  final FocusNode nextNode;
  final FocusNode queueNode;

  @override
  State<MiniPlayer> createState() => MiniPlayerState();
}

/// 公开（不是 `_MiniPlayerState`）是为了让 Shell 能用 `GlobalKey` 调
/// [closeExtra]：BACK 键由 Shell 的 `PopScope` 统一裁决，
/// 而「次级菜单开着没开」只有这里知道。
class MiniPlayerState extends State<MiniPlayer> {
  /// 次级菜单是否展开（播放队列 / 收藏 / 播放模式）。
  bool _extraOpen = false;

  /// 展开前焦点所在的节点 —— 关闭菜单时回到这里。
  FocusNode? _returnNode;

  /// 次级菜单的三个节点（只在展开期间挂到树上）。
  final FocusNode _extraQueueNode = FocusNode(debugLabel: 'extra.queue');
  final FocusNode _extraFavNode = FocusNode(debugLabel: 'extra.fav');
  final FocusNode _extraModeNode = FocusNode(debugLabel: 'extra.mode');

  /// 次级菜单是否开着（Shell 的 BACK 裁决要用）。
  bool get isExtraOpen => _extraOpen;

  @override
  void dispose() {
    _extraQueueNode.dispose();
    _extraFavNode.dispose();
    _extraModeNode.dispose();
    super.dispose();
  }

  /// 打开次级菜单。**只允许由 OK 触发**（在「队列/更多」键上）。
  void openExtra([FocusNode? from]) {
    if (_extraOpen) return;
    setState(() {
      _extraOpen = true;
      _returnNode = from;
    });
    Log.i('UI 迷你播放器打开次级菜单（队列 / 收藏 / 播放模式）');
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _extraOpen) _extraQueueNode.requestFocus();
    });
  }

  /// 收起次级菜单并把焦点还给进入前的那个主键。
  ///
  /// ⚠️ 焦点必须**先**确定、再 setState 卸载菜单：
  /// 菜单节点在卸载后就没了，倒过来做会掉到 FocusScope（方向键全失灵）。
  void closeExtra() {
    if (!_extraOpen) return;
    final FocusNode back = _returnNode ?? widget.queueNode;
    setState(() {
      _extraOpen = false;
      _returnNode = null;
    });
    if (back.canRequestFocus) back.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 用 select 而不是 watch：播放位置每秒跳动多次，
    //    watch 会让整条底部播放条（含网络封面）反复重建。
    final Track? song = context.select<PlaybackRepository, Track?>(
      (PlaybackRepository p) => p.current,
    );
    final bool playing = context.select<PlaybackRepository, bool>(
      (PlaybackRepository p) => p.isPlaying,
    );
    // 当前模式：四处 UI 状态同步的一部分。
    final PlayMode mode = context.select<PlaybackRepository, PlayMode>(
      (PlaybackRepository p) => p.mode,
    );
    // 是否有「上一首」——V5 起由**播放历史**决定（见 `PlaybackRepository.hasPrevious`）。
    final bool canPrevious = context.select<PlaybackRepository, bool>(
      (PlaybackRepository p) => p.hasPrevious,
    );
    final MusicRepository music = context.read<MusicRepository>();

    // 没有播放过任何歌曲 → 不渲染（Shell 也会判一次，这里是二道保险）
    if (song == null) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // ── 次级菜单（只在 OK 打开时存在；BACK / ↓ 收起）────────
        if (_extraOpen)
          _ExtraBar(
            song: song,
            queueNode: _extraQueueNode,
            favNode: _extraFavNode,
            modeNode: _extraModeNode,
            onOpenQueue: () {
              closeExtra();
              widget.onOpenQueue();
            },
            onClose: closeExtra,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: TvGlass(
            radius: TvRadii.glass,
            padding: EdgeInsets.zero,
            child: SizedBox(
              height: _miniHeight,
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: <Widget>[
                          // ── 封面：默认焦点，OK 打开完整播放页 ──────
                          TvFocus(
                            focusNode: widget.coverNode,
                            debugLabel: 'mini.cover',
                            onPressed: () {
                              Log.i('UI 打开完整播放页 (mini 封面)');
                              widget.onOpenPlayer();
                            },
                            // 左右只在 5 段主链里走：到头指回自身，不外溢。
                            nextLeft: widget.coverNode,
                            nextRight: widget.prevNode,
                            // ↑ 回正文；↓ 已经是底部，原地不动。
                            onArrowUp: widget.onReturnToContent,
                            nextDown: widget.coverNode,
                            builder: (BuildContext context, TvFocusStatus s) =>
                                TvFocusRing(
                              status: s,
                              radius: TvRadii.tile,
                              padding: const EdgeInsets.all(4),
                              child: CoverImage(
                                music: music,
                                coverId: song.effectiveCoverId,
                                size: 54,
                                radius: 8,
                                iconScale: 0.45,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // ── 曲目信息：**不可聚焦**（只展示）────────
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    height: _textHeight,
                                    fontWeight: FontWeight.w600,
                                    color: TvColors.text,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  song.artistNames.isEmpty
                                      ? song.album.name
                                      : '${song.artistNames} · ${song.album.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: _textHeight,
                                    color: TvColors.textFaint,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          _MiniButton(
                            node: widget.prevNode,
                            debugLabel: 'mini.prev',
                            icon: Icons.skip_previous,
                            tooltip: canPrevious ? '上一首' : '没有上一首',
                            enabled: canPrevious,
                            nextLeft: widget.coverNode,
                            nextRight: widget.playNode,
                            nextDown: widget.prevNode,
                            onArrowUp: widget.onReturnToContent,
                            onPressed: () {
                              Log.i('SKIP_PREVIOUS (mini player)');
                              context.read<PlaybackRepository>().previous();
                            },
                          ),
                          const SizedBox(width: 6),
                          _MiniButton(
                            node: widget.playNode,
                            debugLabel: 'mini.play',
                            icon: playing ? Icons.pause : Icons.play_arrow,
                            tooltip: playing ? '暂停' : '播放',
                            large: true,
                            strongHalo: true,
                            nextLeft: widget.prevNode,
                            nextRight: widget.nextNode,
                            nextDown: widget.playNode,
                            onArrowUp: widget.onReturnToContent,
                            onPressed: () {
                              Log.i('PLAY_TOGGLE ${playing ? '暂停' : '播放'} '
                                  '(mini player)');
                              context.read<PlaybackRepository>().togglePlay();
                            },
                          ),
                          const SizedBox(width: 6),
                          _MiniButton(
                            node: widget.nextNode,
                            debugLabel: 'mini.next',
                            icon: Icons.skip_next,
                            tooltip: '下一首',
                            nextLeft: widget.playNode,
                            nextRight: widget.queueNode,
                            nextDown: widget.nextNode,
                            onArrowUp: widget.onReturnToContent,
                            onPressed: () {
                              Log.i('SKIP_NEXT (mini player)');
                              context.read<PlaybackRepository>().next();
                            },
                          ),
                          const SizedBox(width: 8),
                          // ── 队列 / 更多：OK 打开次级菜单 ──────────
                          // 这是**唯一**的次级入口。短按就展开，
                          // 不需要长按、不需要 ↑，因为方向键不做命令。
                          _MiniButton(
                            node: widget.queueNode,
                            debugLabel: 'mini.queue',
                            icon: Icons.queue_music,
                            tooltip: '队列 / 更多',
                            nextLeft: widget.nextNode,
                            // 右边界：指回自身，不允许甩到侧栏。
                            nextRight: widget.queueNode,
                            nextDown: widget.queueNode,
                            onArrowUp: widget.onReturnToContent,
                            onPressed: () => openExtra(widget.queueNode),
                          ),
                          const SizedBox(width: 8),
                          // ── 当前播放模式（**不可聚焦**，只做状态同步）──
                          // 需求「播放模式补充要求」§7：当前模式必须在迷你播放栏、
                          // 全屏播放器、队列面板、手机遥控四处保持一致。
                          // 这里只展示，切换入口在次级层。
                          _ModeChip(mode: mode),
                        ],
                      ),
                    ),
                  ),
                  // ── 细进度线（只读，不进焦点链）────────────────
                  _MiniProgress(
                    playback: context.read<PlaybackRepository>(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 迷你播放条底部的 2px 进度线。
///
/// ## 为什么单独一个 StatefulWidget
/// 播放位置每 200–400ms 变一次。若让 [MiniPlayer] 订阅，整条（含网络封面、
/// 文字、五个按钮）都会重建 —— 电视上会明显掉帧。这里只让这 2px 的
/// 进度条重建，其余子树完全不动。
class _MiniProgress extends StatefulWidget {
  const _MiniProgress({required this.playback});

  final PlaybackRepository playback;

  @override
  State<_MiniProgress> createState() => _MiniProgressState();
}

class _MiniProgressState extends State<_MiniProgress> {
  StreamSubscription<Duration>? _sub;

  /// 0..1。位置未知或时长未知时保持 0（不画已播段）。
  double _fraction = 0;

  @override
  void initState() {
    super.initState();
    // 与 LyricView 同一套订阅方式：seek 立即发值、暂停不发。
    _sub = widget.playback.handler.positionStream.listen(_onPosition);
    _onPosition(widget.playback.handler.position ?? Duration.zero);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  void _onPosition(Duration pos) {
    if (!mounted) return;
    final Duration? dur = widget.playback.handler.duration;
    final int totalMs = dur?.inMilliseconds ?? 0;
    final double next = totalMs <= 0
        ? 0.0
        : (pos.inMilliseconds / totalMs).clamp(0.0, 1.0).toDouble();
    // 变化小于 0.2% 不重建：2px 的线看不出差别，但能省掉大量无意义的重绘。
    if ((next - _fraction).abs() < 0.002) return;
    setState(() => _fraction = next);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(TvRadii.glass),
      ),
      child: SizedBox(
        height: 2,
        child: Stack(
          children: <Widget>[
            const Positioned.fill(
              child: ColoredBox(color: Color(0x24FFFFFF)),
            ),
            FractionallySizedBox(
              widthFactor: _fraction,
              heightFactor: 1,
              alignment: Alignment.centerLeft,
              child: const ColoredBox(color: TvColors.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// 次级菜单：播放队列 / 收藏 / 播放模式。
///
/// ## 为什么单独一个组件
/// 它内部要读 `LocalLibraryRepository`（是否已收藏）。放在主 build 里的话，
/// **默认状态**下迷你播放器就依赖了这个仓储 —— 一处提供不到就是
/// `ProviderNotFoundException`，而收藏在默认视觉里根本不显示。
/// 收敛到这里后：只有按 OK 展开时才建立依赖，收起即释放。
///
/// ## 为什么是横向三个胶囊而不是竖排菜单
/// 竖排菜单会盖住整个内容区（底部条只有 76px 高，菜单要往上长）。
/// 三个胶囊横向排在播放条正上方，只占一行，不遮正文；
/// 遥控器左右扫一次就能看全，比竖排菜单少按几次。
class _ExtraBar extends StatelessWidget {
  const _ExtraBar({
    required this.song,
    required this.queueNode,
    required this.favNode,
    required this.modeNode,
    required this.onOpenQueue,
    required this.onClose,
  });

  final Track song;
  final FocusNode queueNode;
  final FocusNode favNode;
  final FocusNode modeNode;
  final VoidCallback onOpenQueue;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final bool fav = context.select<LocalLibraryRepository, bool>(
      (LocalLibraryRepository l) => l.isFavorite(song.guid),
    );
    final PlayMode mode = context.select<PlaybackRepository, PlayMode>(
      (PlaybackRepository p) => p.mode,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: TvGlass(
          radius: TvRadii.pill,
          blur: false,
          shadow: false,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _ExtraChip(
                node: queueNode,
                icon: Icons.queue_music,
                label: '播放队列',
                nextLeft: queueNode,
                nextRight: favNode,
                onExit: onClose,
                onPressed: onOpenQueue,
              ),
              const SizedBox(width: 6),
              _ExtraChip(
                node: favNode,
                icon: fav ? Icons.favorite : Icons.favorite_border,
                iconColor: fav ? TvColors.brand : TvColors.text,
                label: fav ? '取消收藏' : '收藏',
                nextLeft: queueNode,
                nextRight: modeNode,
                onExit: onClose,
                onPressed: () {
                  Log.i('UI 迷你播放器${fav ? '取消收藏' : '收藏'} ${song.title}');
                  unawaited(
                    context
                        .read<LocalLibraryRepository>()
                        .toggleFavorite(song.guid),
                  );
                  onClose();
                },
              ),
              const SizedBox(width: 6),
              _ExtraChip(
                node: modeNode,
                icon: _modeIcon(mode),
                label: '模式：${mode.shortLabel}',
                nextLeft: favNode,
                nextRight: modeNode,
                onExit: onClose,
                onPressed: () {
                  final PlayMode nextMode = mode.next;
                  Log.i('PLAY_MODE_CHANGE UI ${mode.storageKey} → '
                      '${nextMode.storageKey} (mini extra)');
                  unawaited(context.read<PlaybackRepository>().setMode(nextMode));
                },
              ),
              const SizedBox(width: 10),
              const Text(
                'BACK 关闭',
                style: TextStyle(
                  fontSize: 12,
                  height: _textHeight,
                  color: TvColors.textFaint,
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// 次级操作条上的胶囊按钮。
class _ExtraChip extends StatelessWidget {
  const _ExtraChip({
    required this.node,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.nextLeft,
    required this.nextRight,
    required this.onExit,
    this.iconColor,
  });

  final FocusNode node;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode nextLeft;
  final FocusNode nextRight;

  /// ↓ = 收起次级层并回到原来的主键。
  final VoidCallback onExit;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: node,
      debugLabel: node.debugLabel,
      onPressed: onPressed,
      nextLeft: nextLeft,
      nextRight: nextRight,
      nextUp: node, // 已经在最上面
      // ⚠️ ↓ = 收起次级层并回到原来的主键
      onArrowDown: onExit,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: TvRadii.pill,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 18, color: iconColor ?? TvColors.textDim),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                height: _textHeight,
                color: TvColors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 迷你播放栏右端的模式徽标（只读）。
///
/// 切换入口在「队列/更多」打开的次级菜单里 —— 这里只做状态同步，
/// **不可聚焦**（需求：四处 UI 的模式显示必须一致，但不是四处都能改）。
class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode});

  final PlayMode mode;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${mode.label}（在队列/更多里切换）',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(_modeIcon(mode), size: 16, color: TvColors.textFaint),
          const SizedBox(width: 5),
          Text(
            mode.shortLabel,
            style: const TextStyle(
              fontSize: 14,
              height: _textHeight,
              color: TvColors.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部播放条上的圆形按钮。
///
/// 与播放页同理：**不用 `IconButton`**，它自带的 FocusNode 会与焦点环抢状态。
class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.node,
    required this.debugLabel,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.nextLeft,
    required this.nextRight,
    this.nextDown,
    this.onArrowUp,
    this.large = false,
    this.enabled = true,
    this.strongHalo = false,
  });

  final FocusNode node;

  /// 稳定的焦点标签。
  ///
  /// ⚠️ 刻意**不用** `'mini.$tooltip'`：tooltip 会随播放状态在
  /// 「播放 / 暂停」之间变，用它当标签等于每次 play/pause 都换一次
  /// 节点身份 —— 排障时看到的标签会自相矛盾，自动化测试也没法钉住。
  final String debugLabel;

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final FocusNode? nextLeft;
  final FocusNode? nextRight;

  /// ↓ 的去处。底部条已经是最下层：**一律指回自身**，
  /// 不让框架把焦点甩到侧栏或内容区（那会表现得像「按 ↓ 跳走了」）。
  final FocusNode? nextDown;

  /// ↑ = 回正文（由 Shell 提供）。**绝不**在这里展开任何面板。
  final VoidCallback? onArrowUp;

  final bool large;
  final bool strongHalo;

  /// 是否「可用」。
  ///
  /// ⚠️ 刻意**不**把它接到 `canRequestFocus` 上：那样会让底部条的五段焦点链
  /// 在「没有上一首」时少一段，用户按方向键会感觉"跳过了一个"；
  /// 而需求要的是「显示为不可用」—— 置灰 + 按下无操作即可满足，
  /// 焦点仍然可停靠（不会出现有环无动作的死角）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final double box = large ? 54 : 46;
    return Tooltip(
      message: tooltip,
      child: TvFocus(
        focusNode: node,
        debugLabel: debugLabel,
        onPressed: onPressed,
        onArrowUp: onArrowUp,
        nextLeft: nextLeft,
        nextRight: nextRight,
        nextDown: nextDown,
        builder: (BuildContext context, TvFocusStatus s) => SizedBox(
          width: box,
          height: box,
          child: TvFocusRing(
            status: s,
            radius: box / 2,
            padding: EdgeInsets.zero,
            width: box,
            height: box,
            strongHalo: strongHalo,
            baseColor: const Color(0x33FFFFFF),
            child: Icon(
              icon,
              size: large ? 28 : 22,
              color: enabled ? TvColors.text : TvColors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

IconData _modeIcon(PlayMode m) => switch (m) {
      PlayMode.sequence => Icons.trending_flat,
      PlayMode.repeatAll => Icons.repeat,
      PlayMode.shuffle => Icons.shuffle,
      PlayMode.repeatOne => Icons.repeat_one,
    };
