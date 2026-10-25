import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../focus/stage_focus.dart';
import '../shell/shell_stage.dart';
import '../widgets/cover_image.dart';
import '../widgets/track_row.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_glass.dart';

/// 首页（UI 2.0）。
///
/// ## 版式
/// ```
/// ┌────────────────────────────────────────────────────────────┐
/// │ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐                │
/// │ │  漫游   │ │  收藏   │ │最近播放 │ │最近添加 │  ← Bento 卡    │
/// │ └────────┘ └────────┘ └────────┘ └────────┘                │
/// │  最近播放                            共 N 首 · 查看全部 →    │
/// │  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐  ← 小卡网格      │
/// │  │封面│ │封面│ │封面│ │封面│ │封面│ │封面│                 │
/// │  │歌名│ │歌名│ │歌名│ │歌名│ │歌名│ │歌名│                 │
/// │  └────┘ └────┘ └────┘ └────┘ └────┘ └────┘                 │
/// └────────────────────────────────────────────────────────────┘
/// ```
///
/// ## 四张卡片的真实含义（全部有实际行为，没有装饰性假按钮）
/// - **漫游**  —— 随机播放全部歌曲（切换播放模式为「随机」）；
/// - **收藏**  —— 本机收藏集合（飞牛没有收藏写接口，见 [LocalLibraryRepository]）；
/// - **最近播放** —— 本机收听历史（飞牛无播放历史接口）；
/// - **最近添加** —— 按 `createdAt`（Unix 秒）倒序，**直接进入该列表**。
///
/// 卡片上显示的是**真实统计数**，不是装饰文案。
///
/// ## 列数为什么按宽度算而不是写死 6
/// 逻辑视口最小会到 853×480（720p 面板 + dpr1.5），此时内容区只有
/// 595px：6 列会压到 89px 一列，封面小到看不清「这是哪张专辑」。
/// 因此按「每列 ≥ 96px」反推列数，853 下自然变成 5 列，960 以上 6 列，
/// 大屏最多 8 列（再多单列过宽，反而显得稀疏）。
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
  static const int _maxRecentOnHome = 18;

  /// 网格单列最小宽度（逻辑像素）。低于这个值封面就看不清了。
  static const double _minTile = 96;

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

    // 首页默认首焦点 = **漫游卡**（第一张 Bento 卡）。
    //
    // 为什么不是搜索框、也不是导航栏「首页」：打开电视第一下 OK 应该
    // 直接放歌。落在搜索框上会弹出输入法，落在导航上没有任何动作。
    final StageFocus? stage = StageFocusScope.maybeOf(context)?.stage;
    if (stage != null) {
      // 四张卡都按标签登记：从「最近添加」页 BACK 回来时，
      // 焦点要回到那张卡上，而不是跳回漫游卡或左上角。
      stage
        ..register(_roamNode)
        ..register(_favNode)
        ..register(_recentNode)
        ..register(_addedNode)
        ..registerDefault(_roamNode);
    }

    // 真实统计（都是 O(n) 的轻量计算，不做排序）。
    final int favCount = local.favoriteTracks(library.tracks).length;
    final int addedCount =
        library.tracks.where((Track t) => t.createdAt != null).length;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = c.maxWidth.isFinite
            ? c.maxWidth - TvSpacing.pageH * 2
            : 700;
        final int cols =
            (((width + TvSpacing.sm) / (_minTile + TvSpacing.sm)).floor())
                .clamp(3, 8);
        const double gap = TvSpacing.sm;
        final double tileW = (width - (cols - 1) * gap) / cols;
        // 系统字体缩放（Android「字体大小」）会整体放大文字。
        // 格子的 mainAxisExtent 必须把它算进去 —— 否则 1.3 倍时
        // 歌名+歌手两行会被**静默裁掉**（release 不报错，只是少半行字）。
        final double ts = MediaQuery.textScalerOf(context).scale(1.0);
        final double titleLine = (14 * ts * 1.2).ceilToDouble();
        final double artistLine = (12 * ts * 1.2).ceilToDouble();
        // 文字预算 = 6(间距) + 歌名 + 2 + 歌手；再留 13 = 焦点环 padding 8 + 描边 5
        final double textBudget = 6 + titleLine + 2 + artistLine;
        final double tileExtent = tileW + textBudget + 13;

        return CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  TvSpacing.pageH, 8, TvSpacing.pageH, 0),
              sliver: SliverToBoxAdapter(
                child: _BentoRow(
                  roamNode: _roamNode,
                  favNode: _favNode,
                  recentNode: _recentNode,
                  addedNode: _addedNode,
                  trackCount: library.tracks.length,
                  favCount: favCount,
                  recentCount: recent.length,
                  addedCount: addedCount,
                  onRoam: () => _roam(library.tracks),
                  onFav: () => widget.onOpenStage(ShellStage.favorites),
                  onRecent: () => widget.onOpenStage(ShellStage.recent),
                  onAdded: () => widget.onOpenStage(ShellStage.recentAdded),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  TvSpacing.pageH, TvSpacing.xxl, TvSpacing.pageH, 0),
              sliver: SliverToBoxAdapter(
                child: _SectionHeader(
                  title: '最近播放',
                  subtitle: recent.isEmpty
                      ? '暂无记录'
                      : '共 ${recent.length} 首 · 按播放时间',
                  actionLabel: recent.length > _maxRecentOnHome
                      ? '查看全部 ${recent.length} 首'
                      : null,
                  onAction: () => widget.onOpenStage(ShellStage.recent),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  TvSpacing.pageH, TvSpacing.md, TvSpacing.pageH, 0),
              sliver: shown.isEmpty
                  ? const SliverToBoxAdapter(
                      child: TrackListEmpty(
                        icon: Icons.history,
                        text: '暂无最近播放',
                        hint: '从音乐库挑一首开始播放',
                      ),
                    )
                  : SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: gap,
                        mainAxisSpacing: TvSpacing.md,
                        // 封面（正方形）+ 两行文字 + 焦点环占位，全部由
                        // 上面的 textBudget 算出（含字体缩放），不留魔法数。
                        mainAxisExtent: tileExtent,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (BuildContext context, int i) => _RecentTile(
                          track: shown[i],
                          isCurrent: shown[i].guid == currentGuid,
                          onPressed: () {
                            Log.i('HOME_RECENT 播放 index=$i '
                                'guid=${shown[i].guid}');
                            context.read<PlaybackRepository>().playQueue(
                                  shown,
                                  source: QueueSource.local,
                                  startIndex: i,
                                );
                            widget.onOpenPlayer();
                          },
                        ),
                        childCount: shown.length,
                      ),
                    ),
            ),
            // 底部留白：迷你播放器是悬浮条，内容不该顶着它。
            const SliverToBoxAdapter(child: SizedBox(height: TvSpacing.xl)),
          ],
        );
      },
    );
  }
}

/// 四张 Bento 卡一行。
///
/// ## 焦点链
/// 显式左右串联 `漫游 ↔ 收藏 ↔ 最近播放 ↔ 最近添加`，两端不环回
/// （左端的 ← 与右端的 → 交给框架 —— 左边是导航栏、右边没有内容）。
/// 向下进入网格交给框架的空间搜索：网格列数随视口变化，
/// 写死「第一张卡 → 第一格」反而会在某些列数下跳到奇怪的位置。
class _BentoRow extends StatelessWidget {
  const _BentoRow({
    required this.roamNode,
    required this.favNode,
    required this.recentNode,
    required this.addedNode,
    required this.trackCount,
    required this.favCount,
    required this.recentCount,
    required this.addedCount,
    required this.onRoam,
    required this.onFav,
    required this.onRecent,
    required this.onAdded,
  });

  final FocusNode roamNode;
  final FocusNode favNode;
  final FocusNode recentNode;
  final FocusNode addedNode;
  final int trackCount;
  final int favCount;
  final int recentCount;
  final int addedCount;
  final VoidCallback onRoam;
  final VoidCallback onFav;
  final VoidCallback onRecent;
  final VoidCallback onAdded;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth.isFinite ? c.maxWidth : 700;
        const double gap = 14;
        final double cardW = (w - gap * 3) / 4;
        // 卡片高度 = max(按宽度比例, 内容必需高度)，再夹上限：
        // 只按 0.62×宽 算的话，853×480 下高度会被压到 85 → 内容必需
        // 20(icon) + 3 + 两行字 + 24(padding)，字体 1.3 倍时直接溢出。
        final double ts = MediaQuery.textScalerOf(context).scale(1.0);
        final double need = 22 +
            3 +
            (19 * ts * 1.2).ceilToDouble() +
            3 +
            (13 * ts * 1.2).ceilToDouble() +
            24;
        final double base = cardW * 0.62;
        // 手写而不是 clamp：clamp 要求 lower ≤ upper，字体极端放大时
        // `need + 6` 会超过 172，clamp 直接抛 assert。
        final double h = base < need + 6 ? need + 6 : (base > 172 ? 172 : base);

        return Row(
          children: <Widget>[
            Expanded(
              child: _BentoCard(
                node: roamNode,
                icon: Icons.explore_outlined,
                label: '漫游',
                count: '$trackCount 首',
                colors: const <Color>[Color(0xFF6C56B8), Color(0xFF8A5E9E)],
                height: h,
                nextRight: favNode,
                onPressed: onRoam,
              ),
            ),
            const SizedBox(width: gap),
            Expanded(
              child: _BentoCard(
                node: favNode,
                icon: Icons.favorite_border,
                label: '收藏',
                count: '$favCount 首',
                colors: const <Color>[Color(0xFF8A5560), Color(0xFF9A6448)],
                height: h,
                nextLeft: roamNode,
                nextRight: recentNode,
                onPressed: onFav,
              ),
            ),
            const SizedBox(width: gap),
            Expanded(
              child: _BentoCard(
                node: recentNode,
                icon: Icons.history,
                label: '最近播放',
                count: '$recentCount 首',
                colors: const <Color>[Color(0xFF2F6250), Color(0xFF42705C)],
                height: h,
                nextLeft: favNode,
                nextRight: addedNode,
                onPressed: onRecent,
              ),
            ),
            const SizedBox(width: gap),
            Expanded(
              child: _BentoCard(
                node: addedNode,
                icon: Icons.fiber_new_outlined,
                label: '最近添加',
                count: '$addedCount 首',
                colors: const <Color>[Color(0xFF3C4C7E), Color(0xFF4C5F92)],
                height: h,
                nextLeft: recentNode,
                onPressed: onAdded,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 首页 Bento 卡（玻璃底 + 低饱和渐变 + 轻微浮起）。
class _BentoCard extends StatelessWidget {
  const _BentoCard({
    required this.node,
    required this.icon,
    required this.label,
    required this.count,
    required this.colors,
    required this.height,
    required this.onPressed,
    this.nextLeft,
    this.nextRight,
  });

  final FocusNode node;
  final IconData icon;
  final String label;

  /// 真实统计（如「128 首」）。
  final String count;

  final List<Color> colors;
  final double height;
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
        radius: TvRadii.card,
        padding: EdgeInsets.zero,
        // 卡片自带渐变，焦点填充不能盖掉它
        focusColor: const Color(0x2EFFFFFF),
        pressedColor: const Color(0x4DFFFFFF),
        // ⚠️ 只有卡片允许浮起；列表行/网格格一律 1.0（见 TvLift 说明）
        lift: TvLift.card,
        child: TvGlass(
          radius: TvRadii.card,
          // 四张卡并排面积不小 → 不做实时模糊，只保留玻璃色与细边线。
          blur: false,
          tint: const Color(0x1AFFFFFF),
          padding: EdgeInsets.zero,
          child: Container(
            height: height,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(TvRadii.card),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                // 低透明度叠加：保留色彩区分度，又能透出玻璃底。
                colors: <Color>[
                  colors[0].withValues(alpha: 0.62),
                  colors[1].withValues(alpha: 0.28),
                ],
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Icon(icon, size: 22, color: Colors.white70),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 19,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      count,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.2,
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

/// 区块标题行（最近播放 / 查看全部）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.onAction,
    this.actionLabel,
  });

  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(
            fontSize: 24,
            height: 1.2,
            fontWeight: FontWeight.w700,
            color: TvColors.text,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              height: 1.2,
              color: TvColors.textFaint,
            ),
          ),
        ),
        if (actionLabel != null)
          _LinkChip(label: actionLabel!, onPressed: onAction),
      ],
    );
  }
}

/// 最近播放小卡（封面 + 歌名 + 歌手）。
///
/// ⚠️ 高度预算写死在 [HomePage] 的 `mainAxisExtent`（tileW + 40）里，
/// 这里每个 `Text` 都必须显式 `height`，否则 M3 默认 1.43 会撑破格子
/// （release 下是**静默裁切**，格子里只剩半行字）。
class _RecentTile extends StatelessWidget {
  const _RecentTile({
    required this.track,
    required this.isCurrent,
    required this.onPressed,
  });

  final Track track;
  final bool isCurrent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final MusicRepository music = context.read<MusicRepository>();

    return TvFocus(
      debugLabel: 'home.tile',
      onPressed: onPressed,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: TvRadii.tile,
        padding: const EdgeInsets.all(4),
        // 网格内的格子不放大（会压到相邻格），靠描边 + 光环表达焦点。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints c) {
                      final double side = c.maxWidth.isFinite
                          ? min(c.maxWidth, c.maxHeight.isFinite
                              ? c.maxHeight
                              : c.maxWidth)
                          : 96;
                      return Align(
                        alignment: Alignment.topLeft,
                        child: CoverImage(
                          music: music,
                          coverId: track.effectiveCoverId,
                          size: side,
                          radius: TvRadii.tile,
                          iconScale: 0.32,
                        ),
                      );
                    },
                  ),
                  if (isCurrent)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.graphic_eq,
                                size: 12, color: TvColors.accent),
                            SizedBox(width: 3),
                            Text(
                              '播放中',
                              style: TextStyle(
                                fontSize: 10,
                                height: 1.2,
                                color: TvColors.text,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                height: 1.2,
                fontWeight: FontWeight.w500,
                color: isCurrent ? TvColors.accent : TvColors.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              track.artistNames.isEmpty ? track.album.name : track.artistNames,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                height: 1.2,
                color: TvColors.textFaint,
              ),
            ),
          ],
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
        radius: TvRadii.pill,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            height: 1.2,
            color: TvColors.textDim,
          ),
        ),
      ),
    );
  }
}
