import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/log.dart';
import '../../domain/track.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/cover_image.dart';

/// 全部歌曲（曲库）页。
///
/// ## V2 关键改造（相对 V1）
/// 1. **完整曲库**：不再 `getTracks(1, 30)`，改用 [LibraryRepository] 分页 + 无限滚动；
/// 2. **当前播放标识**：正在播放的曲目高亮 + ▶ 标记，随自动下一首实时更新；
/// 3. **状态保持**：`ScrollController` 保留，返回本页时位置不变（V2 §13）。
class SongListPage extends StatefulWidget {
  final VoidCallback onOpenPlayer;
  final VoidCallback onOpenSearch;

  const SongListPage({
    super.key,
    required this.onOpenPlayer,
    required this.onOpenSearch,
  });

  @override
  State<SongListPage> createState() => _SongListPageState();
}

class _SongListPageState extends State<SongListPage> {
  /// 保留滚动位置（V2 §13：返回不能滚回顶部）。
  final ScrollController _scroll = ScrollController();

  /// 距底部还有多少像素就开始预加载（提前量，避免用户看到空白）。
  static const double _prefetchExtent = 600;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 首屏加载；曲库仓储内部保证「已有数据不重复请求」。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    // ⚠️ ScrollController 必须释放（V2 §29 检查项）。
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - _prefetchExtent) {
      // 接近底部 → 请求下一页（仓储内部防并发 + 判 hasMore）
      context.read<LibraryRepository>().loadMore();
    }
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    final library = context.read<LibraryRepository>();
    final playback = context.read<PlaybackRepository>();

    await library.loadFirst();
    if (!mounted) return;

    // 播放队列与曲库对齐（跨分页连续播放的前提）
    playback.adoptQueue(library.tracks);

    // 恢复上次播放位置（只定位，不自动播放）
    if (playback.current == null && playback.pendingRestoreGuid != null) {
      if (playback.restoreToTrack(library.tracks)) {
        Log.i('STATE_RESTORE UI 已定位上次播放（未自动播放）');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryRepository>();
    final playback = context.watch<PlaybackRepository>();

    return Column(
      children: <Widget>[
        _Header(
          title: '全部歌曲',
          subtitle: library.tracks.isEmpty
              ? null
              : '${library.tracks.length} 首${library.hasMore ? ' …' : ''}',
          onSearch: widget.onOpenSearch,
        ),
        Expanded(child: _buildBody(library, playback)),
      ],
    );
  }

  Widget _buildBody(LibraryRepository library, PlaybackRepository playback) {
    if (library.phase == LibraryPhase.loading &&
        library.tracks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (library.phase == LibraryPhase.error &&
        library.tracks.isEmpty) {
      return _ErrorView(
        message: library.error ?? '加载失败',
        onRetry: () => library.retry(),
      );
    }

    if (library.tracks.isEmpty) {
      return const Center(
        child: Text('曲库为空',
            style: TextStyle(fontSize: 22, color: Colors.white38)),
      );
    }

    final currentGuid = playback.current?.guid;

    return ListView.builder(
      controller: _scroll,
      // 底部多一条用于显示「加载更多 / 没有更多了」
      itemCount: library.tracks.length + 1,
      itemBuilder: (context, i) {
        if (i == library.tracks.length) {
          return _Footer(library: library);
        }
        final track = library.tracks[i];
        return _TrackRow(
          track: track,
          index: i,
          isCurrent: track.guid == currentGuid,
          onPlay: () {
            Log.i('UI 选歌 index=$i guid=${track.guid}');
            // 用整份曲库建队列 → 跨分页连续播放成立
            playback.setQueue(library.tracks, startIndex: i);
            widget.onOpenPlayer();
          },
        );
      },
    );
  }
}

/// 顶部标题栏 + 搜索入口。
class _Header extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback onSearch;

  const _Header({
    required this.title,
    required this.subtitle,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(width: 12),
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 18, color: Colors.white38),
            ),
          ],
          const Spacer(),
          ElevatedButton.icon(
            onPressed: onSearch,
            icon: const Icon(Icons.search, size: 22),
            label: const Text('搜索', style: TextStyle(fontSize: 18)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white12,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
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
          child: Text('已加载全部歌曲',
              style: TextStyle(fontSize: 16, color: Colors.white30)),
        ),
      );
    }
    if (library.error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: ElevatedButton.icon(
            onPressed: () => library.retry(),
            icon: const Icon(Icons.refresh, size: 20),
            label: const Text('加载失败，点此重试', style: TextStyle(fontSize: 16)),
          ),
        ),
      );
    }
    return const SizedBox(height: 20);
  }
}

/// 错误视图。
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            message,
            style: const TextStyle(fontSize: 20, color: Colors.redAccent),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 20),
            label: const Text('重试', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }
}

/// 单行曲目。
///
/// **性能（V2 §19）**：`ListView.builder` 懒构建；行内**不**订阅 position 流
/// （否则每 200ms 整个列表 rebuild）。当前播放状态由父级传入，
/// 只有「从当前曲变为非当前曲」的那几行会重建。
class _TrackRow extends StatelessWidget {
  final Track track;
  final int index;

  /// 是否是当前播放的曲目（V2 §5）。
  final bool isCurrent;

  final VoidCallback onPlay;

  const _TrackRow({
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final music = context.read<MusicRepository>();
    return Container(
      // 正在播放的行用背景色 + 左侧色条明显区分
      color: isCurrent ? const Color(0x1A4F8CFF) : Colors.transparent,
      child: ListTile(
        onTap: onPlay,
        selected: isCurrent,
        selectedTileColor: Colors.transparent,
        leading: SizedBox(
          width: 60,
          child: Stack(
            children: <Widget>[
              CoverImage(
                music: music,
                coverId: track.effectiveCoverId,
                size: 48,
                radius: 4,
              ),
              if (isCurrent)
                const Positioned(
                  right: 0,
                  bottom: 0,
                  child: Icon(Icons.play_circle_fill,
                      color: Colors.blue, size: 20),
                ),
            ],
          ),
        ),
        title: Row(
          children: <Widget>[
            Flexible(
              child: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight:
                      isCurrent ? FontWeight.w700 : FontWeight.w400,
                  color: isCurrent ? Colors.blue : Colors.white,
                ),
              ),
            ),
            if (isCurrent) ...<Widget>[
              const SizedBox(width: 8),
              const Text(
                '正在播放',
                style: TextStyle(fontSize: 14, color: Colors.blue),
              ),
            ],
          ],
        ),
        subtitle: Text(
          '${track.artistNames} · ${track.album.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, color: Colors.white54),
        ),
        trailing: Text(
          track.audioSpec.display,
          style: const TextStyle(fontSize: 14, color: Colors.white38),
        ),
      ),
    );
  }
}
