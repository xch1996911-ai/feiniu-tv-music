import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/playback_repository.dart';
import '../focus/stage_focus.dart';
import '../widgets/empty_state.dart';
import '../widgets/track_row.dart';
import '../widgets/tv_focus.dart';

/// 列表来源。两种来源的**排序依据完全不同**，不能混用：
/// - [recent]：按**实际播放时间**倒序（本机记录）；
/// - [recentlyAdded]：按**入库时间**（`createdAt`，Unix 秒）倒序。
enum TrackListSource {
  /// 最近播放（真实播放历史，不是全曲库）。
  recent,

  /// 最近添加（真实入库顺序，不是全曲库）。
  recentlyAdded,
}

/// 平铺曲目列表页（最近播放 / 最近添加共用）。
///
/// ## 为什么「最近播放」不等于「列一遍曲库」
/// 需求明确要求：最近必须表示**用户实际播放过的歌曲**。
/// 因此这里的数据源是 [LocalLibraryRepository.recentTracks]，
/// 它按 guid **还原并保序**本机记录，曲库里没播放过的歌不会出现。
///
/// 「最近添加」同理 —— 用 [LocalLibraryRepository.recentlyAdded]
/// 按 `createdAt` 倒序，而不是把曲库原样铺开。
///
/// 两者**分成两页**，排序依据不同，绝不合页。
class TrackListPage extends StatefulWidget {
  const TrackListPage({
    super.key,
    required this.source,
    required this.title,
    required this.emptyText,
    required this.emptyIcon,
    required this.onOpenPlayer,
    this.emptyActionLabel,
    this.onEmptyAction,
  });

  final TrackListSource source;
  final String title;
  final String emptyText;
  final IconData emptyIcon;
  final VoidCallback onOpenPlayer;

  /// 空态里的可选操作（例如「去音乐库」）。
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  @override
  State<TrackListPage> createState() => _TrackListPageState();
}

class _TrackListPageState extends State<TrackListPage> {
  final FocusNode _appendNode = FocusNode(debugLabel: 'list.append');
  final FocusNode _emptyActionNode = FocusNode(debugLabel: 'list.emptyaction');

  /// 行焦点池：让每一行的 ↑/↓ 精确指到相邻的**整行**。
  ///
  /// ⚠️ 不能用「每行自己建节点 + 框架就近搜索」：
  /// 行右侧的心形与下一行的心形同 x，框架会把 ↓ 接到下一行的心形，
  /// 于是焦点顺着右侧一列心形滑到底（实机反馈的「收藏按钮抢焦点」）。
  final TrackRowFocus _rows = TrackRowFocus('list.row');

  @override
  void dispose() {
    _appendNode.dispose();
    _emptyActionNode.dispose();
    _rows.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LibraryRepository library = context.watch<LibraryRepository>();
    final LocalLibraryRepository local = context.watch<LocalLibraryRepository>();
    final String? currentGuid = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.current?.guid,
    );

    final List<Track> tracks = switch (widget.source) {
      TrackListSource.recent => local.recentTracks(library.tracks),
      TrackListSource.recentlyAdded =>
        LocalLibraryRepository.recentlyAdded(library.tracks),
    };
    final int count = tracks.length;
    final StageFocusScope? scope = StageFocusScope.maybeOf(context);

    // 本页默认首焦点 = **第一首歌的整行**。
    //
    // 实机 Bug：从首页「最近添加」卡进来后焦点落在左侧导航/收藏上，
    // 用户按 OK 什么都不会播放。现在由页面自己登记，Shell 切页时直接用
    // （见 `StageFocus.registerDefault`），不再一律跳导航第一项。
    if (count > 0) {
      scope?.stage.registerDefault(_rows.at(0));
    } else if (widget.onEmptyAction != null) {
      scope?.stage.registerDefault(_emptyActionNode);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Header(
          title: widget.title,
          subtitle: _subtitleOf(count),
          appendNode: _appendNode,
          // 从「加入播放队列」按 ↓ 直接进第一首歌，不交给框架猜。
          firstRowNode: count > 0 ? _rows.at(0) : null,
          canAppend: count > 0,
          onAppend: () => _appendAll(tracks),
        ),
        if (count == 0)
          Expanded(
            child: _EmptyBlock(
              icon: widget.emptyIcon,
              text: widget.emptyText,
              actionLabel: widget.emptyActionLabel,
              actionNode: _emptyActionNode,
              onAction: widget.onEmptyAction,
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              itemCount: count,
              itemBuilder: (BuildContext context, int i) {
                final Track t = tracks[i];
                return TrackRow(
                  track: t,
                  isCurrent: t.guid == currentGuid,
                  focusNode: _rows.at(i),
                  // 第一行 ↑ = 页头主操作（真实存在的入口），不是导航栏。
                  rowAbove: i == 0 ? _appendNode : _rows.at(i - 1),
                  // 最后一行 ↓ = 迷你播放器封面（列表到底就是播放条）。
                  rowBelow: _rows.below(i, count) ?? scope?.miniCoverIfAlive,
                  onPressed: () {
                    Log.i('LIST_PLAY ${widget.source.name} index=$i guid=${t.guid}');
                    // 从**该条记录**开始播放，队列 = 这份列表，
                    // 因此之后可以顺着这份记录继续播下去。
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

  String _subtitleOf(int n) => switch (widget.source) {
        TrackListSource.recent => n == 0 ? '' : '共 $n 首 · 按最近播放时间',
        TrackListSource.recentlyAdded => n == 0 ? '' : '共 $n 首 · 按入库时间',
      };

  void _appendAll(List<Track> tracks) {
    if (tracks.isEmpty) return;
    final int added = context.read<PlaybackRepository>().appendToQueue(tracks);
    Log.i('LIST_APPEND_TO_QUEUE ${widget.source.name} count=$added');
  }
}

/// 页头：标题 + 数量 + 「加入播放队列」。
class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.appendNode,
    required this.canAppend,
    required this.onAppend,
    this.firstRowNode,
  });

  final String title;
  final String subtitle;
  final FocusNode appendNode;
  final bool canAppend;
  final VoidCallback onAppend;

  /// 列表第一行的整行节点（↓ 的落点）。
  final FocusNode? firstRowNode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 16, 26, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: TvColors.text,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 17, color: TvColors.textFaint),
          ),
          const Spacer(),
          if (canAppend)
            TvFocus(
              focusNode: appendNode,
              debugLabel: 'list.append',
              onPressed: onAppend,
              nextDown: firstRowNode,
              // 页头只有这一个可获焦控件：↑ 到顶，指回自身避免被甩走。
              nextUp: appendNode,
              builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
                status: s,
                radius: 22,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.playlist_add, size: 20, color: TvColors.text),
                    SizedBox(width: 8),
                    Text(
                      '加入播放队列',
                      style: TextStyle(fontSize: 16, color: TvColors.text),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 空态块（带可选操作按钮）。
class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({
    required this.icon,
    required this.text,
    required this.actionLabel,
    required this.actionNode,
    required this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final FocusNode actionNode;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final String? label = actionLabel;
    final VoidCallback? action = onAction;

    // ⚠️ V5：这一块原本是「描边大卡片 + 长技术说明」（实机图2/图3）。
    //    现在统一走 [EmptyState]：低调水印 + 一句短文案 + 可聚焦的操作按钮。
    return EmptyState(
      title: text,
      icon: icon,
      actionLabel: label,
      actionFocusNode: actionNode,
      actionDebugLabel: 'list.emptyaction',
      onAction: action,
    );
  }
}
