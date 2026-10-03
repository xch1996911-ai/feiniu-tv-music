import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/music_repository.dart';
import 'cover_image.dart';
import 'tv_focus.dart';
import 'tv_glass.dart';

/// 曲目列表项 —— **全项目唯一**的一份实现。
///
/// ## 为什么要统一
/// 旧代码在「全部歌曲」「搜索结果」里各写了一份几乎一样的行，
/// 于是焦点描边、当前播放高亮、字号在三处各不相同，改一处漏两处。
/// 现在所有列表（首页 / 音乐库 / 搜索 / 收藏 / 最近 / 概览详情）都用这一个。
///
/// ## 焦点：行内**两个**节点，左右链显式指定
/// - 行本身 = 播放（OK）
/// - 右侧心形 = 收藏 / 取消收藏
///
/// `行 →(右)→ 心形`、`心形 →(左)→ 行` 都是**显式**指定的；
/// 心形再按右键交回框架（去往侧栏等）。
/// 上下方向交回框架 —— 列表长度不定、位置还在滚动，框架比写死节点更稳。
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

  /// 是否显示可聚焦的「收藏」按钮。
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
  const TrackListEmpty({super.key, required this.text, this.icon});

  final String text;

  /// 可选的图标（收藏空态用「心」、最近空态用「时钟」等）。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: TvGlass(
          radius: 20,
          padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 46, color: TvColors.textFaint),
                const SizedBox(height: 16),
              ],
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 19,
                  height: 1.6,
                  color: TvColors.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
