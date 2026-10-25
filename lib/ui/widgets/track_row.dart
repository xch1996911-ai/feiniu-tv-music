import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/music_repository.dart';
import 'cover_image.dart';
import 'empty_state.dart';
import 'tv_focus.dart';
import 'tv_glass.dart';

/// 曲目列表的**行焦点池**。
///
/// ## 为什么要有池
/// [TrackRow] 的上下键必须知道「上一行 / 下一行的整行节点」。
/// 行自己建节点的话彼此不可见，只能交回框架的就近搜索 ——
/// 在滚动中的列表里那是不可靠的（见 [TrackRow] 类注释）。
///
/// 池由**页面**持有：页面知道总共有多少行、哪一行是第一行，
/// 也只有页面能在 `dispose` 时统一释放（节点不能在 build 里循环创建后泄漏）。
///
/// ## 用下标而不是 guid
/// 「最近添加」按入库时间排序，用户停留在第 3 行时列表可能因为同步推进
/// 而插入新歌。用 guid 做键会让焦点跟着歌跑（用户视角是「焦点自己跳了」）；
/// 用下标则焦点留在**同一屏位置**，符合遥控器的空间直觉。
class TrackRowFocus {
  TrackRowFocus(this.prefix);

  /// 节点标签前缀，形如 `list.row` → `list.row.0` / `list.row.1` …
  ///
  /// 只用于排障与测试断言，不参与焦点逻辑。
  final String prefix;

  final List<FocusNode> _nodes = <FocusNode>[];

  /// 第 i 行的节点（按需创建，重复调用返回同一个）。
  FocusNode at(int i) {
    while (_nodes.length <= i) {
      _nodes.add(FocusNode(debugLabel: '$prefix.${_nodes.length}'));
    }
    return _nodes[i];
  }

  /// 上一行的整行节点；第一行返回 null（交给页面决定去哪）。
  FocusNode? above(int i) => i > 0 ? at(i - 1) : null;

  /// 下一行的整行节点；最后一行返回 null（交给页面决定去哪）。
  FocusNode? below(int i, int count) => i + 1 < count ? at(i + 1) : null;

  @visibleForTesting
  int get debugLength => _nodes.length;

  void dispose() {
    for (final FocusNode n in _nodes) {
      n.dispose();
    }
    _nodes.clear();
  }
}

/// 曲目列表项 —— **全项目唯一**的一份实现。
///
/// ## 为什么要统一
/// 旧代码在「全部歌曲」「搜索结果」里各写了一份几乎一样的行，
/// 于是焦点描边、当前播放高亮、字号在三处各不相同，改一处漏两处。
/// 现在所有列表（首页 / 音乐库 / 搜索 / 收藏 / 最近 / 概览详情）都用这一个。
///
/// ## 焦点：**整行是唯一主焦点**
/// - 行本身 = 播放（OK），页面进入时默认焦点必须落在**第一行的整行**；
/// - 右侧心形是**次级**控件：只有用户主动按 → 才进得去，
///   进去后 ← 回整行、上下回到**相邻行的整行**。
///
/// ### 为什么心形的上下必须显式指到相邻行
/// 心形在每一行的同一个 x 上，框架的「就近搜索」会把 `心形 N ↓`
/// 接到 `心形 N+1`（同 x、垂直最近）。结果就是：用户往下按，
/// 焦点在右侧一条**心形纵列**里一路滑到底，永远回不到歌名 ——
/// 实机反馈的「主操作和收藏操作混在一起」正是这个机制造成的。
/// 显式指定后，心形只是「这一行的一个附属按钮」，不是独立一列。
///
/// ### 为什么上下在行与行之间也不交给框架
/// 列表随时在滚动，框架用的是**当前 rect**；刚滚动过、布局还没稳定的那一帧
/// 会算出错误的落点（「有时能跳下一行，有时跳到上上行」）。
/// 页面把相邻行的节点直接传进来（[rowAbove] / [rowBelow]）就没有这个不确定性。
///
/// ## 收藏为什么在这里读仓储
/// 收藏状态是**每首歌一份**的，只有行自己知道该订阅哪一首。
/// 用 `select` 精确到单曲：某一首被收藏/取消时，**只有那一行**重建，
/// 其余几百行不受影响（否则每次点收藏整页都会重建、焦点会抖）。
class TrackRow extends StatefulWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.isCurrent,
    required this.onPressed,
    this.trailingText,
    this.focusNode,
    this.rowAbove,
    this.rowBelow,
    this.showFavorite = true,
  });

  final Track track;

  /// 是否是当前正在播放的曲目（高亮 + 图标）。
  final bool isCurrent;

  /// OK 键：播放这首。
  final VoidCallback onPressed;

  /// 右侧文案。默认显示时长。
  final String? trailingText;

  /// 外部焦点节点（一般不需要传）。
  final FocusNode? focusNode;

  /// ↑ 要去的地方：通常是**上一行的整行节点**；第一行交给页面传
  /// 「页头的主操作」（如「加入播放队列」）。
  ///
  /// null = 交回框架兜底。
  final FocusNode? rowAbove;

  /// ↓ 要去的地方：**下一行的整行节点**；最后一行由页面传 Mini Player。
  final FocusNode? rowBelow;

  /// 是否显示「收藏」按钮。
  ///
  /// ⚠️ 即便显示，它也是**次级**控件：只有 → 才进得去，
  /// 页面进入时绝不聚焦它（否则用户会以为整页的主操作是收藏）。
  final bool showFavorite;

  static String formatDuration(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  State<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<TrackRow> {
  /// 行节点：外部没传时自己建（必须自己建 —— 收藏按钮的 `nextLeft`
  /// 需要指向它，拿不到节点就只能靠框架瞎猜）。
  FocusNode? _ownRowNode;

  final FocusNode _favNode = FocusNode(debugLabel: 'track.fav');

  FocusNode get _rowNode =>
      widget.focusNode ?? (_ownRowNode ??= FocusNode(debugLabel: 'track.row'));

  @override
  void didUpdateWidget(covariant TrackRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode) &&
        oldWidget.focusNode == null) {
      _ownRowNode?.dispose();
      _ownRowNode = null;
    }
  }

  @override
  void dispose() {
    _ownRowNode?.dispose();
    _favNode.dispose();
    super.dispose();
  }

  Future<void> _toggleFavorite() async {
    final repo = context.read<LocalLibraryRepository>();
    final bool now = await repo.toggleFavorite(widget.track.guid);
    Log.i('UI ${now ? '收藏' : '取消收藏'} ${widget.track.title}');
  }

  @override
  Widget build(BuildContext context) {
    final music = context.read<MusicRepository>();
    final String sub = widget.track.artistNames.isEmpty
        ? widget.track.album.name
        : '${widget.track.artistNames} · ${widget.track.album.name}';

    // 精确到单曲订阅：只有这一行的收藏态变化才重建。
    final bool fav = widget.showFavorite
        ? context.select<LocalLibraryRepository, bool>(
            (LocalLibraryRepository l) => l.isFavorite(widget.track.guid),
          )
        : false;

    return TvFocus(
      focusNode: _rowNode,
      debugLabel: 'track.${widget.track.guid}',
      onPressed: widget.onPressed,
      // 上下显式串到相邻行的整行节点（见类注释）。
      nextUp: widget.rowAbove,
      nextDown: widget.rowBelow,
      nextRight: widget.showFavorite ? _favNode : null,
      builder: (BuildContext context, TvFocusStatus s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: TvFocusRing(
          status: s,
          radius: 12,
          padding: EdgeInsets.zero,
          child: TvGlass(
            // ⚠️ 行会同时出现几十个 → **不做背景模糊**，只上玻璃色。
            //    这是「毛玻璃视觉」与「电视端性能」之间的取舍点。
            blur: false,
            radius: 12,
            showBorder: false,
            shadow: false,
            tint: widget.isCurrent
                ? const Color(0x3D4F8CFF)
                : const Color(0x14FFFFFF),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: <Widget>[
                  CoverImage(
                    music: music,
                    coverId: widget.track.effectiveCoverId,
                    size: 46,
                    radius: 6,
                    iconScale: 0.42,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          widget.track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: widget.isCurrent
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: widget.isCurrent
                                ? TvColors.accent
                                : TvColors.text,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          sub,
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
                  const SizedBox(width: 12),
                  if (widget.isCurrent)
                    const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: Icon(Icons.volume_up,
                          size: 20, color: TvColors.accent),
                    ),
                  if (widget.showFavorite)
                    TvFocus(
                      focusNode: _favNode,
                      debugLabel: 'track.fav.${widget.track.guid}',
                      onPressed: _toggleFavorite,
                      nextLeft: _rowNode,
                      // → 到这里已经是右边界：指回自身，别让框架甩到侧栏。
                      nextRight: _favNode,
                      // ⚠️ 上下回**相邻行的整行**，不留在心形列（见类注释）。
                      nextUp: widget.rowAbove,
                      nextDown: widget.rowBelow,
                      builder: (BuildContext context, TvFocusStatus fs) =>
                          SizedBox(
                        width: 40,
                        height: 40,
                        child: TvFocusRing(
                          status: fs,
                          radius: 20,
                          padding: EdgeInsets.zero,
                          width: 40,
                          height: 40,
                          child: Icon(
                            fav ? Icons.favorite : Icons.favorite_border,
                            size: 21,
                            color: fav ? TvColors.brand : TvColors.textFaint,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 8),
                  Text(
                    widget.trailingText ??
                        TrackRow.formatDuration(widget.track.duration),
                    style: const TextStyle(
                        fontSize: 15, color: TvColors.textFaint),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 分组标题行（保留给需要「标题 + 曲目平铺」的场景）。
///
/// **刻意不可聚焦**：分组只是视觉分隔，能聚焦就必须处理
/// 「选中分组之后做什么」，而电视上多一层跳转就多一次迷路。
/// 需要真正的两级浏览请用 `OverviewPage`。
class TrackGroupHeader extends StatelessWidget {
  const TrackGroupHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: TvColors.text,
              ),
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
            const SizedBox(width: 10),
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 15, color: TvColors.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

/// 列表里的空态提示（毛玻璃卡片，与全局视觉一致）。
class TrackListEmpty extends StatelessWidget {
  const TrackListEmpty({
    super.key,
    required this.text,
    this.icon,
    this.hint,
    this.actionLabel,
    this.onAction,
    this.actionNode,
    this.actionAutofocus = false,
  });

  /// 主文案（**必须短**，例如「暂无最近播放」）。
  final String text;

  /// 可选的图标（收藏空态用「心」、最近空态用「时钟」等）。
  final IconData? icon;

  /// 第二行短提示（例如「从音乐库挑一首开始播放」）。可为空。
  final String? hint;

  /// 操作按钮文案与回调（可聚焦）。
  final String? actionLabel;
  final VoidCallback? onAction;
  final FocusNode? actionNode;
  final bool actionAutofocus;

  @override
  Widget build(BuildContext context) {
    // ⚠️ V5：这里曾经是一个「描边圆角大框 + 居中技术说明」的卡片。
    //    实机（图2）效果是：一个几乎占满内容区的大框，把「这里是空的」
    //    渲染成了「这里出错了」，框线比页面标题还抢眼。
    //    现在统一收敛到 [EmptyState]（低调水印 + 短文案 + 可选操作）。
    return EmptyState(
      title: text,
      icon: icon ?? Icons.inbox_outlined,
      hint: hint,
      actionLabel: actionLabel,
      onAction: onAction,
      actionFocusNode: actionNode,
      actionDebugLabel: 'empty.action',
      actionAutofocus: actionAutofocus,
    );
  }
}
