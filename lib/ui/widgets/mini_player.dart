import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import 'cover_image.dart';
import 'tv_focus.dart';
import 'tv_glass.dart';

/// 底部迷你播放器（参考图二/图三的底部播放条）。
///
/// ## 存在意义
/// 曲库浏览时不必回播放页就能看到「现在在放什么」并控制播放 —— 这是
/// 「拿电视长期听歌」的基本要求。
///
/// ## 焦点顺序（需求明确要求，本组件据此重排）
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
/// ## 节点归属
/// 五个 `FocusNode` **由 AppShell 创建并释放**（不在这里建）：
/// 关闭全屏播放页后要把焦点**恢复**到底部播放条上，
/// 而 Shell 是唯一知道「播放页刚被关掉」的地方。
/// 迷你播放器的固定高度（V5：从 86 降到 72）。
///
/// 需求 §四-A.4：「底部迷你播放器适度降低高度」—— 它每减少 14px，
/// 正文列表就多显示近半行内容，在 720p 上尤其明显。
///
/// ⚠️ 这是**固定高度行**，里面的每个 `Text` 都必须显式写 `height`：
/// M3 主题的 `DefaultTextStyle` 行高是 **1.43**（不是 1.0），
/// 18 号字不写 height 会占 26px 而不是 22px —— 两行文字加起来就把
/// 72px 撑爆，表现为 `RenderFlex overflowed`（电视上是黄黑条纹）。
const double _miniHeight = 72;

/// 行高倍率。⚠️ 「字号 × 行高」必须是整数（Flutter 逐行向上取整）。
/// 18×1.2=21.6→22、14×1.2=16.8→17，剩余 72-22-2-17=31px 余量充足。
const double _textHeight = 1.2;

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.onOpenPlayer,
    required this.onOpenQueue,
    required this.coverNode,
    required this.prevNode,
    required this.playNode,
    required this.nextNode,
    required this.queueNode,
  });

  final VoidCallback onOpenPlayer;
  final VoidCallback onOpenQueue;

  final FocusNode coverNode;
  final FocusNode prevNode;
  final FocusNode playNode;
  final FocusNode nextNode;
  final FocusNode queueNode;

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
    // 当前模式：四处 UI 状态同步的一部分（只展示，见 [_ModeChip]）。
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: TvGlass(
        radius: 16,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: SizedBox(
          height: _miniHeight,
          child: Row(
            children: <Widget>[
              // ── 封面：默认焦点，OK 打开完整播放页 ──────────────
              TvFocus(
                focusNode: coverNode,
                debugLabel: 'mini.cover',
                onPressed: () {
                  Log.i('UI 打开完整播放页 (mini 封面)');
                  onOpenPlayer();
                },
                nextRight: prevNode,
                builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
                  status: s,
                  radius: 12,
                  padding: const EdgeInsets.all(5),
                  child: CoverImage(
                    music: music,
                    coverId: song.effectiveCoverId,
                    size: 52,
                    radius: 8,
                    iconScale: 0.45,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // ── 曲目信息：**不可聚焦**（只展示）────────────────
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
                node: prevNode,
                debugLabel: 'mini.prev',
                icon: Icons.skip_previous,
                tooltip: canPrevious ? '上一首' : '没有上一首',
                enabled: canPrevious,
                nextLeft: coverNode,
                nextRight: playNode,
                onPressed: () {
                  Log.i('SKIP_PREVIOUS (mini player)');
                  context.read<PlaybackRepository>().previous();
                },
              ),
              const SizedBox(width: 8),
              _MiniButton(
                node: playNode,
                debugLabel: 'mini.play',
                icon: playing ? Icons.pause : Icons.play_arrow,
                tooltip: playing ? '暂停' : '播放',
                large: true,
                nextLeft: prevNode,
                nextRight: nextNode,
                onPressed: () {
                  Log.i('PLAY_TOGGLE ${playing ? '暂停' : '播放'} (mini player)');
                  context.read<PlaybackRepository>().togglePlay();
                },
              ),
              const SizedBox(width: 8),
              _MiniButton(
                node: nextNode,
                debugLabel: 'mini.next',
                icon: Icons.skip_next,
                tooltip: '下一首',
                nextLeft: playNode,
                nextRight: queueNode,
                onPressed: () {
                  Log.i('SKIP_NEXT (mini player)');
                  context.read<PlaybackRepository>().next();
                },
              ),
              const SizedBox(width: 10),
              // 队列按钮：与播放页里的是**同一份**队列
              _MiniButton(
                node: queueNode,
                debugLabel: 'mini.queue',
                icon: Icons.queue_music,
                tooltip: '播放队列',
                nextLeft: nextNode,
                nextRight: null,
                onPressed: () {
                  Log.i('UI 打开播放队列 (mini player)');
                  onOpenQueue();
                },
              ),
              const SizedBox(width: 10),
              // ── 当前播放模式（**不可聚焦**，只做四处 UI 的状态同步）──
              // 需求「播放模式补充要求」§7：当前模式必须在迷你播放栏、
              // 全屏播放器、队列面板、手机遥控四处保持一致。
              // 这里只展示，不提供切换入口 —— 底部条的焦点链固定是
              // 封面 → 上一首 → 播放/暂停 → 下一首 → 队列 五段。
              _ModeChip(mode: mode),
            ],
          ),
        ),
      ),
    );
  }
}

/// 迷你播放栏右端的模式徽标（只读）。
class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode});

  final PlayMode mode;

  IconData get _icon => switch (mode) {
        PlayMode.sequence => Icons.format_list_numbered,
        PlayMode.repeatAll => Icons.repeat,
        PlayMode.shuffle => Icons.shuffle,
        PlayMode.repeatOne => Icons.repeat_one,
      };

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: mode.label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(_icon, size: 16, color: TvColors.textFaint),
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
    this.large = false,
    this.enabled = true,
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
  final bool large;

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
        nextLeft: nextLeft,
        nextRight: nextRight,
        builder: (BuildContext context, TvFocusStatus s) => SizedBox(
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
              size: large ? 28 : 22,
              color: enabled ? TvColors.text : TvColors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}
