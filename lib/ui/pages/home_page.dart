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

/// 首页（参考图二）。
///
/// 版式：四张快捷卡片 + 「最近播放」列表；顶部搜索栏与左侧导航由 AppShell 提供。
///
/// ## 四张卡片的真实含义（全部有实际行为，没有装饰性假按钮）
/// - **漫游**  —— 随机播放全部歌曲（切换播放模式为「随机」）；
/// - **收藏**  —— 曲库里 `isFavorite == true` 的曲目（服务端字段，不本地另存）；
/// - **最近播放** —— 本机收听历史（飞牛无播放历史接口，见
///   [LocalLibraryRepository] 的说明）；
/// - **最近添加** —— 按 `createdAt`（Unix 秒）倒序。
///
/// ## 性能
/// 只 `select` 当前曲目 guid，**不 watch 整个播放仓储**：
/// 播放位置每秒都在变，watch 会让首页（含十几张网络封面）反复重建。
/// `select` 后只有「换歌」那一下才重建。
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(26, 6, 26, 26),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _ShortcutCard(
                icon: Icons.album,
                label: '漫游',
                colors: const <Color>[Color(0xFFFF4D4F), Color(0xFFFFB199)],
                node: _roamNode,
                nextLeft: null,
                nextRight: _favNode,
                onPressed: () => _roam(library.tracks),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _ShortcutCard(
                icon: Icons.favorite,
                label: '收藏',
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
                icon: Icons.add,
                label: '最近添加',
                colors: const <Color>[Color(0xFF6E6E7E), Color(0xFFB9B9C6)],
                node: _addedNode,
                nextLeft: _recentNode,
                nextRight: null,
                onPressed: () => widget.onOpenStage(ShellStage.recentAdded),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
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
            text: '还没有播放记录\n\n'
                '从下面的「音乐库」里挑一首开始播放，这里就会留下痕迹。',
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

/// 首页快捷卡片（图二里的四张渐变卡）。
class _ShortcutCard extends StatelessWidget {
  const _ShortcutCard({
    required this.icon,
    required this.label,
    required this.colors,
    required this.node,
    required this.onPressed,
    this.nextLeft,
    this.nextRight,
  });

  final IconData icon;
  final String label;
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
        radius: 16,
        padding: EdgeInsets.zero,
        // 渐变卡片自带底色的情况下，焦点填充要淡一些，否则会盖掉渐变色
        focusColor: const Color(0x33FFFFFF),
        pressedColor: const Color(0x66FFFFFF),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 138,
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              ),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Icon(icon, size: 28, color: Colors.white),
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
