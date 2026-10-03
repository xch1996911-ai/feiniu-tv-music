import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/cover_image.dart';

/// 搜索页。
///
/// ## ⚠️ 搜索范围必须如实告知用户（V2 §12 硬要求）
/// 飞牛音乐**没有服务端搜索接口**（`fnos_endpoints.dart` 里不存在 search 端点），
/// 所以搜索是**本地**的，只能命中「已加载进内存的曲目」。
///
/// 因此本页必须：
/// - 顶部常驻显示 `已索引 N 首`（或 `已索引 N/总数`）；
/// - 后台自动把曲库分页拉完（[LibraryRepository.buildFullIndex]），
///   让搜索最终能覆盖全库 —— 用户在输入时不必等待；
/// - **绝不能**让用户误以为「搜不到 = 曲库里没有」。
class SearchPage extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onOpenPlayer;

  const SearchPage({
    super.key,
    required this.onBack,
    required this.onOpenPlayer,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputNode = FocusNode();
  final FocusNode _backNode = FocusNode();

  String _keyword = '';
  List<Track> _results = const [];
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    // 进页面就开始建全库索引（后台进行，用户可立即开始输入）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final library = context.read<LibraryRepository>();
      library.buildFullIndex(); // 不 await：后台慢慢拉
    });
  }

  @override
  void dispose() {
    // ⚠️ controller / node 必须释放（V2 §29 检查项）
    _controller.dispose();
    _inputNode.dispose();
    _backNode.dispose();
    super.dispose();
  }

  void _doSearch(String raw) {
    final q = raw.trim();
    setState(() {
      _keyword = q;
      _results = q.isEmpty ? const <Track>[] : context.read<LibraryRepository>().search(q);
      _searched = q.isNotEmpty;
    });
    Log.i('SEARCH_REQUEST keyword=${q.isEmpty ? '(空)' : q} '
        'hits=${_results.length}');
  }

  void _play(Track track) {
    final results = _results;
    final index = results.indexWhere((t) => t.guid == track.guid);
    if (index < 0) return;
    Log.i('SEARCH_RESULT 播放 index=$index guid=${track.guid}');
    // 搜索结果建立**独立**队列，不污染「全部歌曲」队列
    context.read<PlaybackRepository>().playQueue(
          results,
          source: QueueSource.search,
          startIndex: index,
        );
    widget.onOpenPlayer();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryRepository>();
    final playback = context.watch<PlaybackRepository>();
    final currentGuid = playback.current?.guid;

    return Column(
      children: <Widget>[
        _SearchHeader(
          controller: _controller,
          inputNode: _inputNode,
          backNode: _backNode,
          scopeLabel: library.indexProgressLabel,
          indexing: library.isIndexing,
          onBack: widget.onBack,
          onSubmit: _doSearch,
          onChanged: _doSearch,
        ),
        Expanded(child: _buildBody(library, currentGuid)),
      ],
    );
  }

  Widget _buildBody(LibraryRepository library, String? currentGuid) {
    // 首屏曲库都还没来 → 提示正在建索引
    if (library.tracks.isEmpty && library.isIndexing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在建立曲库索引…',
                style: TextStyle(fontSize: 18, color: Colors.white54)),
          ],
        ),
      );
    }

    if (!_searched) {
      return const Center(
        child: Text('输入歌名 / 歌手 / 专辑开始搜索',
            style: TextStyle(fontSize: 20, color: Colors.white38)),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            '没有匹配「$_keyword」的歌曲\n'
            '（当前已索引 ${library.tracks.length} 首，'
            '${library.isIndexing ? '索引仍在进行，可稍后再试' : '索引已完成'}）',
            style: const TextStyle(fontSize: 18, color: Colors.white54),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '找到 ${_results.length} 首（在已索引的 ${library.tracks.length} 首中）',
              style: const TextStyle(fontSize: 16, color: Colors.white38),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, i) {
              final t = _results[i];
              return _ResultRow(
                track: t,
                isCurrent: t.guid == currentGuid,
                onPlay: () => _play(t),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SearchHeader extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode inputNode;
  final FocusNode backNode;

  /// 搜索范围说明（必须如实显示）。
  final String scopeLabel;
  final bool indexing;

  final VoidCallback onBack;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onChanged;

  const _SearchHeader({
    required this.controller,
    required this.inputNode,
    required this.backNode,
    required this.scopeLabel,
    required this.indexing,
    required this.onBack,
    required this.onSubmit,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ElevatedButton.icon(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back, size: 22),
                label: const Text('返回', style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: inputNode,
                  style: const TextStyle(fontSize: 20),
                  textInputAction: TextInputAction.search,
                  // 电视上常用遥控器「搜索键」直接聚焦到这里
                  autofocus: true,
                  onChanged: onChanged,
                  onSubmitted: onSubmit,
                  inputFormatters: <TextInputFormatter>[
                    LengthLimitingTextInputFormatter(50),
                  ],
                  decoration: InputDecoration(
                    hintText: '搜索歌名 / 歌手 / 专辑',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ⚠️ 必须如实告知搜索范围：飞牛没有服务端搜索 API。
          Row(
            children: <Widget>[
              Icon(
                indexing ? Icons.sync : Icons.cloud_done,
                size: 16,
                color: Colors.white38,
              ),
              const SizedBox(width: 6),
              Text(
                indexing ? '正在建立曲库索引 · $scopeLabel' : '搜索范围：$scopeLabel',
                style: const TextStyle(fontSize: 14, color: Colors.white38),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final Track track;
  final bool isCurrent;
  final VoidCallback onPlay;

  const _ResultRow({
    required this.track,
    required this.isCurrent,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final music = context.read<MusicRepository>();
    return Container(
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
                  child:
                      Icon(Icons.play_circle_fill, color: Colors.blue, size: 20),
                ),
            ],
          ),
        ),
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 19,
            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
            color: isCurrent ? Colors.blue : Colors.white,
          ),
        ),
        subtitle: Text(
          '${track.artistNames} · ${track.album.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, color: Colors.white54),
        ),
      ),
    );
  }
}
