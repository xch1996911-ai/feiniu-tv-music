import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/track_row.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_glass.dart';

/// 收藏页（参考图三）。
///
/// 版式：左侧**收藏主题卡**（暖色渐变 + 心形），右侧标题与
/// 「播放 / 随机」入口，下方是收藏歌曲列表。
/// 空收藏时显示明确空态 + 「去音乐库」入口。
///
/// ## 数据源：只用本机集合
/// ⚠️ **不使用** `Track.isFavorite` 作为列表依据。原因是飞牛**没有**
/// 加/取消收藏的写接口（见 [SecureStore] 收藏区说明），若一边显示服务端值、
/// 一边写本机集合，两边必然对不上。
///
/// 现在只有一个数据源：[LocalLibraryRepository.isFavorite]。
/// 服务端 `isFavorite` 只在**首次播种**时作为初始值导入一次。
///
/// ## 队列只从收藏里建
/// 「播放」「随机」都用**收藏列表本身**建队列，
/// 绝不会把整个曲库塞进队列（需求明确要求）。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({
    super.key,
    required this.onOpenPlayer,
    required this.onOpenLibrary,
  });

  final VoidCallback onOpenPlayer;

  /// 空态里的「去音乐库」。
  final VoidCallback onOpenLibrary;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  final FocusNode _playNode = FocusNode(debugLabel: 'fav.play');
  final FocusNode _shuffleNode = FocusNode(debugLabel: 'fav.shuffle');
  final FocusNode _browseNode = FocusNode(debugLabel: 'fav.browse');

  @override
  void dispose() {
    _playNode.dispose();
    _shuffleNode.dispose();
    _browseNode.dispose();
    super.dispose();
  }

  void _play(List<Track> tracks, {required bool shuffle}) {
    if (tracks.isEmpty) return;
    final PlaybackRepository p = context.read<PlaybackRepository>();
    final int start = shuffle ? Random().nextInt(tracks.length) : 0;
    Log.i('FAVORITE_PLAY ${shuffle ? '随机' : '顺序'} count=${tracks.length}');
    if (shuffle) p.setMode(PlayMode.shuffle);
    p.playQueue(tracks, source: QueueSource.local, startIndex: start);
    widget.onOpenPlayer();
  }

  @override
  Widget build(BuildContext context) {
    final LibraryRepository library = context.watch<LibraryRepository>();
    // watch 收藏仓储：收藏/取消收藏后列表要立即变化（需求要求「立即更新」）。
    final LocalLibraryRepository local = context.watch<LocalLibraryRepository>();
    final String? currentGuid = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.current?.guid,
    );

    final List<Track> tracks = local.favoriteTracks(library.tracks);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _HeroHeader(
          count: tracks.length,
          playNode: _playNode,
          shuffleNode: _shuffleNode,
          browseNode: _browseNode,
          onPlay: () => _play(tracks, shuffle: false),
          onShuffle: () => _play(tracks, shuffle: true),
          onBrowse: widget.onOpenLibrary,
          isEmpty: tracks.isEmpty,
        ),
        if (tracks.isEmpty)
          const Expanded(
            child: TrackListEmpty(
              icon: Icons.favorite_border,
              text: '暂无收藏',
              hint: '在歌曲行上按右键即可收藏',
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              itemCount: tracks.length,
              itemBuilder: (BuildContext context, int i) {
                final Track t = tracks[i];
                return TrackRow(
                  track: t,
                  isCurrent: t.guid == currentGuid,
                  onPressed: () {
                    Log.i('FAVORITE_PLAY index=$i guid=${t.guid}');
                    context.read<PlaybackRepository>().playQueue(
                          tracks,
                          source: QueueSource.local,
                          startIndex: i,
                        );
                    widget.onOpenPlayer();
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}

/// 收藏主题区（图三的暖色心形卡 + 标题 + 播放/随机）。
class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.count,
    required this.playNode,
    required this.shuffleNode,
    required this.browseNode,
    required this.onPlay,
    required this.onShuffle,
    required this.onBrowse,
    required this.isEmpty,
  });

  final int count;
  final FocusNode playNode;
  final FocusNode shuffleNode;
  final FocusNode browseNode;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final VoidCallback onBrowse;
  final bool isEmpty;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 8, 26, 14),
      child: TvGlass(
        radius: 20,
        padding: const EdgeInsets.all(18),
        child: Row(
          children: <Widget>[
            // 主题卡：暖色渐变 + 心形（对应图三的橙色方块）
            Container(
              width: 132,
              height: 132,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Color(0xFFFF7A18), Color(0xFFFFC24B)],
                ),
              ),
              child: const Icon(
                Icons.favorite,
                size: 58,
                color: Color(0xE6FFFFFF),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    '收藏',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: TvColors.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    count == 0 ? '还没有收藏的歌曲' : '共 $count 首收藏的歌曲',
                    style: const TextStyle(
                      fontSize: 17,
                      color: TvColors.textDim,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '收藏记录保存在电视本机（飞牛没有收藏写接口）',
                    style: TextStyle(fontSize: 13, color: TvColors.textFaint),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      if (isEmpty)
                        _HeroAction(
                          node: browseNode,
                          icon: Icons.library_music,
                          label: '去音乐库',
                          onPressed: onBrowse,
                          nextRight: null,
                        )
                      else ...<Widget>[
                        _HeroAction(
                          node: playNode,
                          icon: Icons.play_arrow,
                          label: '播放',
                          onPressed: onPlay,
                          nextRight: shuffleNode,
                          filled: true,
                        ),
                        const SizedBox(width: 12),
                        _HeroAction(
                          node: shuffleNode,
                          icon: Icons.shuffle,
                          label: '随机',
                          onPressed: onShuffle,
                          nextRight: null,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主题区里的胶囊按钮。
class _HeroAction extends StatelessWidget {
  const _HeroAction({
    required this.node,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.nextRight,
    this.filled = false,
  });

  final FocusNode node;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode? nextRight;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    // ⚠️ 这里**不再**传 `TvFocus.debugLabel`：
    //    节点是外部传进来的（`initState` 里建，标签是稳定的 `fav.play` 等），
    //    `TvFocus.debugLabel` 只在自己建节点时才生效 —— 留在这里会是
    //    一份永远不生效、还随按钮文案变化的「第二份标签」，只会误导排障。
    return TvFocus(
      focusNode: node,
      onPressed: onPressed,
      nextRight: nextRight,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 24,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        baseColor: filled ? const Color(0xF2FFFFFF) : const Color(0x33FFFFFF),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 22,
              color: filled ? const Color(0xFF16161F) : TvColors.text,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: filled ? const Color(0xFF16161F) : TvColors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
