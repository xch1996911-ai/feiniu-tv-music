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
import '../shell/shell_stage.dart';
import '../widgets/track_row.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_glass.dart';

/// 首页。
///
/// 版式：四张快捷卡片 + 「最近播放」列表；顶部搜索栏与左侧导航由 AppShell 提供。
///
/// ## 四张卡片的真实含义（全部有实际行为，没有装饰性假按钮）
/// - **漫游**  —— 随机播放全部歌曲（切换播放模式为「随机」）；
/// - **收藏**  —— 本机收藏集合（飞牛没有收藏写接口，见 [LocalLibraryRepository]）；
/// - **最近播放** —— 本机收听历史（飞牛无播放历史接口）；
/// - **最近添加** —— 按 `createdAt`（Unix 秒）倒序，**直接进入该列表**。
///
/// 卡片上显示的是**真实统计数**，不是装饰文案。
///
/// ## 性能
/// 只 `select` 当前曲目 guid，**不 watch 整个播放仓储**：
/// 播放位置每秒都在变，watch 会让首页（含十几张网络封面）反复重建。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.onOpenPlayer,
    required this.onOpenStage,
  });

  final VoidCallback onOpenPlayer;
  final ValueChanged<ShellStage> onOpenStage;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 首页最多列几首最近播放（再多就引导去「最近」整页看）。
  static const int _maxRecentOnHome = 12;

  final FocusNode _roamNode = FocusNode(debugLabel: 'home.roam');
  final FocusNode _favNode = FocusNode(debugLabel: 'home.fav');
  final FocusNode _recentNode = FocusNode(debugLabel: 'home.recent');
  final FocusNode _addedNode = FocusNode(debugLabel: 'home.added');

  @override
  void dispose() {
    _roamNode.dispose();
    _favNode.dispose();
    _recentNode.dispose();
    _addedNode.dispose();
    super.dispose();
  }

  /// 漫游：随机播放全部歌曲。
  void _roam(List<Track> tracks) {
    if (tracks.isEmpty) {
      Log.w('UI 漫游：曲库为空，忽略');
      return;
    }
    final playback = context.read<PlaybackRepository>();
    final int start = Random().nextInt(tracks.length);
    Log.i('UI 漫游 随机播放全部歌曲 start=$start/${tracks.length}');
    playback.setMode(PlayMode.shuffle);
    playback.setQueue(tracks, startIndex: start);
    widget.onOpenPlayer();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryRepository>();
    final local = context.watch<LocalLibraryRepository>();
    final String? currentGuid = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.current?.guid,
    );

    final List<Track> recent = local.recentTracks(library.tracks);
    final List<Track> shown = recent.take(_maxRecentOnHome).toList();

    // 真实统计（都是 O(n) 的轻量计算，不做排序）。
    final int favCount = local.favoriteTracks(library.tracks).length;
    final int addedCount =
        library.tracks.where((Track t) => t.createdAt != null).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(26, 6, 26, 26),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _ShortcutCard(
                icon: Icons.album,
                label: '漫游',
                count: '${library.tracks.length} 首',
                colors: const <Color>[Color(0xFFFF4D4F), Color(0xFFFFB199)],
                node: _roamNode,
                nextRight: _favNode,
                onPressed: () => _roam(library.tracks),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _ShortcutCard(
                icon: Icons.favorite,
                label: '收藏',
                count: '$favCount 首',
                colors: const <Color>[Color(0xFFFF9A3D), Color(0xFFFFD08A)],
                node: _favNode,
                nextLeft: _roamNode,
                nextRight: _recentNode,
                onPressed: () => widget.onOpenStage(ShellStage.favorites),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _ShortcutCard(
                icon: Icons.history,
                label: '最近播放',
                count: '${recent.length} 首',
                colors: const <Color>[Color(0xFF1FA36B), Color(0xFF7BD8A8)],
                node: _recentNode,
                nextLeft: _favNode,
                nextRight: _addedNode,
                onPressed: () => widget.onOpenStage(ShellStage.recent),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _ShortcutCard(
                icon: Icons.fiber_new,
                label: '最近添加',
                count: '$addedCount 首',
                colors: const <Color>[Color(0xFF5B6EF5), Color(0xFF9FB0FF)],
                node: _addedNode,
                nextLeft: _recentNode,
                onPressed: () => widget.onOpenStage(ShellStage.recentAdded),
              ),
            ),
          ],
        ),
        const SizedBox(height: 26),
        Row(
          children: <Widget>[
            const Text(
              '最近播放',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: TvColors.text,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              recent.isEmpty ? '暂无记录' : '共 ${recent.length} 首 · 按播放时间',
              style: const TextStyle(fontSize: 15, color: TvColors.textFaint),
            ),
            const Spacer(),
            if (recent.length > _maxRecentOnHome)
              _LinkChip(
                label: '查看全部 ${recent.length} 首',
                onPressed: () => widget.onOpenStage(ShellStage.recent),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (shown.isEmpty)
          const TrackListEmpty(
            icon: Icons.history,
            text: '暂无最近播放\n\n'
                '从「音乐库」里挑一首开始播放，这里就会留下痕迹。',
          )
        else
          for (int i = 0; i < shown.length; i++)
            TrackRow(
              track: shown[i],
              isCurrent: shown[i].guid == currentGuid,
              onPressed: () {
                Log.i('HOME_RECENT 播放 index=$i guid=${shown[i].guid}');
                context.read<PlaybackRepository>().playQueue(
                      shown,
                      source: QueueSource.local,
                      startIndex: i,
                    );
                widget.onOpenPlayer();
              },
            ),
      ],
    );
  }
}

/// 首页快捷卡片。
///
/// 视觉上属于全站毛玻璃体系：玻璃底 + 一层低透明度渐变（保留四张卡的
/// 色彩识别度，同时不像旧版那样是四块「贴上去的纯色板」）。
class _ShortcutCard extends StatelessWidget {
  const _ShortcutCard({
    required this.icon,
    required this.label,
    required this.count,
    required this.colors,
    required this.node,
    required this.onPressed,
    this.nextLeft,
    this.nextRight,
  });

  final IconData icon;
  final String label;

  /// 真实统计（如「128 首」）。
  final String count;

  final List<Color> colors;
  final FocusNode node;
  final FocusNode? nextLeft;
  final FocusNode? nextRight;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: node,
      debugLabel: 'home.$label',
      onPressed: onPressed,
      nextLeft: nextLeft,
      nextRight: nextRight,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 18,
        padding: EdgeInsets.zero,
        // 卡片自带渐变底色，焦点填充要淡一些，否则会盖掉渐变
        focusColor: const Color(0x33FFFFFF),
        pressedColor: const Color(0x66FFFFFF),
        child: TvGlass(
          radius: 18,
          // 4 张卡片并排，面积不小 → 不做模糊，只保留玻璃色与细边线。
          blur: false,
          tint: const Color(0x1FFFFFFF),
          padding: EdgeInsets.zero,
          child: Container(
            height: 136,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                // 低透明度叠加：既有色彩区分，又能透出背后的玻璃底。
                colors: <Color>[
                  colors[0].withValues(alpha: 0.72),
                  colors[1].withValues(alpha: 0.34),
                ],
              ),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Icon(icon, size: 28, color: Colors.white),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      count,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xCCFFFFFF),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 文字链式按钮（「查看全部 42 首」）。
class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      onPressed: onPressed,
      debugLabel: 'home.link',
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          label,
          style: const TextStyle(fontSize: 17, color: TvColors.textDim),
        ),
      ),
    );
  }
}
