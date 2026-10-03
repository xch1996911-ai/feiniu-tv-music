import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import 'cover_image.dart';
import 'tv_focus.dart';

/// 底部 Mini Player（参考图二的底部播放条）。
///
/// ## 存在意义
/// 曲库浏览时不必回播放页就能看到「现在在放什么」并控制播放 —— 这是
/// 「拿电视长期听歌」的基本要求。
///
/// ## 焦点
/// 四个可聚焦区（曲目信息 / 上一首 / 播放暂停 / 下一首）的 `FocusNode`
/// **由 AppShell 创建并释放**，并在此显式串联成一条左右链：
/// `信息 → 上一首 → 播放/暂停 → 下一首`，反向同理。
///
/// 为什么节点放在 Shell：关闭全屏播放页后要把焦点**恢复**到底部播放条上，
/// 而 Shell 是唯一知道「播放页刚被关掉」的地方。节点由 Shell 持有才能恢复。
///
/// 上下方向不指定，交回框架 —— 向上自然回到曲库列表。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.onOpenPlayer,
    required this.infoNode,
    required this.prevNode,
    required this.playNode,
    required this.nextNode,
  });

  final VoidCallback onOpenPlayer;
  final FocusNode infoNode;
  final FocusNode prevNode;
  final FocusNode playNode;
  final FocusNode nextNode;

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
    final music = context.read<MusicRepository>();

    // 没有播放过任何歌曲 → 不渲染（Shell 也会判一次，这里是二道保险）
    if (song == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        height: 84,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: TvColors.panelHi,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: TvColors.line),
        ),
        child: Row(
          children: <Widget>[
            CoverImage(
              music: music,
              coverId: song.effectiveCoverId,
              size: 58,
              radius: 8,
              iconScale: 0.42,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: TvFocus(
                focusNode: infoNode,
                debugLabel: 'mini.info',
                onPressed: () {
                  Log.i('UI 打开完整播放页 (mini player)');
                  onOpenPlayer();
                },
                nextRight: prevNode,
                builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
                  status: s,
                  radius: 10,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
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
                      const SizedBox(height: 2),
                      Text(
                        '${song.artistNames} · ${song.album.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          color: TvColors.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _MiniButton(
              node: prevNode,
              icon: Icons.skip_previous,
              tooltip: '上一首',
              nextLeft: infoNode,
              nextRight: playNode,
              onPressed: () {
                Log.i('SKIP_PREVIOUS (mini player)');
                context.read<PlaybackRepository>().previous();
              },
            ),
            const SizedBox(width: 8),
            _MiniButton(
              node: playNode,
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
              icon: Icons.skip_next,
              tooltip: '下一首',
              nextLeft: playNode,
              nextRight: null,
              onPressed: () {
                Log.i('SKIP_NEXT (mini player)');
                context.read<PlaybackRepository>().next();
              },
            ),
          ],
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
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.nextLeft,
    required this.nextRight,
    this.large = false,
  });

  final FocusNode node;
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
        debugLabel: 'mini.$tooltip',
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
            child: Icon(icon, size: large ? 32 : 26, color: TvColors.text),
          ),
        ),
      ),
    );
  }
}
