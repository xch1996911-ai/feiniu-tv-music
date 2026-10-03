import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/track_row.dart';

/// 音乐库：**完整曲库**（全部歌曲）。
///
/// ## 关键行为（相对早期版本）
/// 1. **完整曲库**：不再 `getTracks(1, 30)`，改用 [LibraryRepository] 分页 +
///    滚动到底自动续页；
/// 2. **当前播放标识**：正在播放的曲目高亮 + 喇叭图标，随自动下一首实时更新；
/// 3. **状态保持**：`ScrollController` 保留，切页返回后位置不变。
///
/// ## 数据加载在哪
/// 首屏分页与队列装配已上移到 `AppShell`（所有舞台都要用曲库，
/// 放在首页里会导致「先进音乐库才有人拉数据」的时序问题）。
/// 本页只负责**展示与续页**。
class SongListPage extends StatefulWidget {
  final VoidCallback onOpenPlayer;

  const SongListPage({super.key, required this.onOpenPlayer});

  @override
  State<SongListPage> createState() => _SongListPageState();
}

class _SongListPageState extends State<SongListPage> {
  /// 保留滚动位置（返回不能滚回顶部）。
  final ScrollController _scroll = ScrollController();

  /// 距底部还有多少像素就开始预加载（提前量，避免用户看到空白）。
  static const double _prefetchExtent = 600;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    // ⚠️ ScrollController 必须释放。
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final ScrollPosition pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - _prefetchExtent) {
      // 接近底部 → 请求下一页（仓储内部防并发 + 判 hasMore）
      context.read<LibraryRepository>().loadMore();
    }
  }

  void _play(List<Track> tracks, int index) {
    Log.i('UI 选歌 index=$index guid=${tracks[index].guid}');
    // 用整份曲库建队列 → 跨分页连续播放成立
    context.read<PlaybackRepository>().setQueue(tracks, startIndex: index);
    widget.onOpenPlayer();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryRepository>();
    final String? currentGuid = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.current?.guid,
    );

    return Column(
      children: <Widget>[
        _Header(
          total: library.total,
          loaded: library.tracks.length,
          scanning: library.isIndexing,
        ),
        Expanded(child: _buildBody(library, currentGuid)),
      ],
    );
  }

  Widget _buildBody(LibraryRepository library, String? currentGuid) {
    if (library.phase == LibraryPhase.loading && library.tracks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (library.phase == LibraryPhase.error && library.tracks.isEmpty) {
      return TrackListEmpty(
        text: '曲库加载失败',
        hint: library.error == null ? null : '回到这里再试一次，或检查 NAS 是否在线',
      );
    }

    if (library.tracks.isEmpty) {
      return const TrackListEmpty(text: '暂无歌曲');
    }

    // 底部多一条用于显示「加载更多 / 没有更多了」
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      itemCount: library.tracks.length + 1,
      itemBuilder: (BuildContext context, int i) {
        if (i == library.tracks.length) {
          return _Footer(library: library);
        }
        final Track track = library.tracks[i];
        return TrackRow(
          track: track,
          isCurrent: track.guid == currentGuid,
          onPressed: () => _play(library.tracks, i),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.total,
    required this.loaded,
    required this.scanning,
  });

  final int total;
  final int loaded;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 8, 26, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          const Text(
            '音乐库',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: TvColors.text,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            scanning ? '已加载 $loaded / $total 首 · 正在后台索引' : '共 $loaded 首',
            style: const TextStyle(fontSize: 17, color: TvColors.textFaint),
          ),
        ],
      ),
    );
  }
}

/// 列表底部：加载更多 / 没有更多了 / 出错重试。
class _Footer extends StatelessWidget {
  final LibraryRepository library;

  const _Footer({required this.library});

  @override
  Widget build(BuildContext context) {
    if (library.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (library.phase == LibraryPhase.noMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '已加载全部歌曲',
            style: TextStyle(fontSize: 16, color: TvColors.textFaint),
          ),
        ),
      );
    }
    if (library.error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(
            '加载失败：${library.error}',
            style: const TextStyle(fontSize: 16, color: Color(0xFFFF8A8F)),
          ),
        ),
      );
    }
    return const SizedBox(height: 20);
  }
}
