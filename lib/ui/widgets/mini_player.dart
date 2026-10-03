import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
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
    final MusicRepository music = context.read<MusicRepository>();

    // 没有播放过任何歌曲 → 不渲染（Shell 也会判一次，这里是二道保险）
    if (song == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TvGlass(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          height: 86,
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
                    size: 62,
                    radius: 8,
                    iconScale: 0.42,
                  ),
                ),
              ),
              const SizedBox(width: 14),
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
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: TvColors.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      song.artistNames.isEmpty
                          ? song.album.name
                          : '${song.artistNames} · ${song.album.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
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
                tooltip: '上一首',
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
            ],
          ),
        ),
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

  @override
  Widget build(BuildContext context) {
    final double box = large ? 60 : 52;
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
            child: Icon(icon, size: large ? 32 : 25, color: TvColors.text),
          ),
        ),
      ),
    );
  }
}
