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

/// 通用「曲目集合」页：收藏 / 最近播放 / 最近添加 / 歌手 / 专辑 / 风格 共用。
///
/// ## 为什么合并成一个页面
/// 这六种视图的数据形态只有两种：
/// 1. **平铺**（收藏、最近播放、最近添加）——就是一份曲目清单；
/// 2. **分组**（歌手、专辑、风格）——分组标题 + 组内曲目。
///
/// 各写一个页面会产生 6 份「列表 + 焦点 + 空态 + 播放」的重复代码，
/// 改焦点行为时必然漏改。这里用两种构造器表达，行为完全一致。
///
/// ## 分组为什么不做成二级页
/// 电视遥控器上「进入二级页 → 再返回」是迷路高发区（尤其配 BT 遥控器时
/// 有些设备根本没有返回键以外的返回方式）。因此分组用
/// **标题行 + 组内曲目**的单层列表呈现，按下即播，上下即可穿越分组。
///
/// ## 播放队列
/// 平铺视图用整份清单建队列；分组视图用**该分组**建队列
/// （在「歌手」页里点一首，下一首自然是这位歌手的下一首，符合直觉）。
class CollectionPage extends StatefulWidget {
  const CollectionPage.list({
    super.key,
    required this.title,
    required this.emptyHint,
    required this.onOpenPlayer,
    required this.build,
    this.subtitle,
  }) : buildGroups = null;

  const CollectionPage.grouped({
    super.key,
    required this.title,
    required this.emptyHint,
    required this.onOpenPlayer,
    required this.buildGroups,
    this.subtitle,
  }) : build = null;

  final String title;
  final String? subtitle;
  final String emptyHint;
  final VoidCallback onOpenPlayer;

  /// 平铺视图：把整份曲库映射成要展示的曲目清单。
  final List<Track> Function(List<Track> catalogue)? build;

  /// 分组视图：把整份曲库映射成分组。
  final List<TrackGroup> Function(List<Track> catalogue)? buildGroups;

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

/// 列表里的一行：要么是分组标题，要么是一首曲目。
class _Entry {
  const _Entry.header(this.title, this.subtitle)
      : track = null,
        queue = null,
        index = 0;

  const _Entry.track(this.track, this.queue, this.index)
      : title = null,
        subtitle = null;

  final String? title;
  final String? subtitle;
  final Track? track;
  final List<Track>? queue;
  final int index;
}

class _CollectionPageState extends State<CollectionPage> {
  /// 上一次用于计算分组的曲库实例。
  ///
  /// `LibraryRepository` 每次合并新页都会**换一个新的 List 实例**，
  /// 因此用 `identical` 就能精确判断「曲库变了没」，不需要比较内容
  /// （几千首比较内容反而更贵）。
  List<Track>? _source;

  List<_Entry> _entries = const <_Entry>[];

  List<_Entry> _buildEntries(List<Track> catalogue) {
    if (identical(_source, catalogue)) return _entries;
    _source = catalogue;

    final entries = <_Entry>[];

    final grouped = widget.buildGroups;
    if (grouped != null) {
      for (final TrackGroup g in grouped(catalogue)) {
        entries.add(_Entry.header(g.title, g.subtitle));
        final groupTracks = g.tracks;
        for (int i = 0; i < groupTracks.length; i++) {
          entries.add(_Entry.track(groupTracks[i], groupTracks, i));
        }
      }
    } else {
      final flat = widget.build?.call(catalogue) ?? const <Track>[];
      for (int i = 0; i < flat.length; i++) {
        entries.add(_Entry.track(flat[i], flat, i));
      }
    }

    _entries = entries;
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryRepository>();
    final String? currentGuid = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.current?.guid,
    );

    final List<_Entry> entries = _buildEntries(library.tracks);

    if (entries.isEmpty) {
      if (library.phase == LibraryPhase.loading && library.tracks.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(title: widget.title, subtitle: widget.subtitle),
          Expanded(child: TrackListEmpty(text: widget.emptyHint)),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      itemCount: entries.length + 1,
      itemBuilder: (BuildContext context, int i) {
        if (i == 0) {
          return _Header(
            title: widget.title,
            subtitle: widget.subtitle ?? '共 ${entries.length} 项',
          );
        }
        final _Entry e = entries[i - 1];
        final Track? t = e.track;
        if (t == null) {
          return TrackGroupHeader(title: e.title ?? '', subtitle: e.subtitle);
        }
        return TrackRow(
          track: t,
          isCurrent: t.guid == currentGuid,
          onPressed: () {
            final queue = e.queue ?? const <Track>[];
            Log.i('COLLECTION_PLAY ${widget.title} index=${e.index} guid=${t.guid}');
            context.read<PlaybackRepository>().playQueue(
                  queue,
                  source: QueueSource.local,
                  startIndex: e.index,
                );
            widget.onOpenPlayer();
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
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
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: TvColors.text,
              ),
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
            const SizedBox(width: 12),
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 17, color: TvColors.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}
