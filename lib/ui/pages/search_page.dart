import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/track_row.dart';
import '../widgets/tv_focus.dart';

/// 搜索页。
///
/// ## ⚠️ 搜索范围必须如实告知用户
/// 飞牛音乐**没有服务端搜索接口**（`fnos_endpoints.dart` 里不存在 search 端点），
/// 所以搜索是**本地**的，只能命中「已加载进内存的曲目」。
///
/// 因此本页必须：
/// - 顶部常驻显示「已索引 N 首」（或 `已索引 N/总数`）；
/// - 后台自动把曲库分页拉完（[LibraryRepository.buildFullIndex]），
///   让搜索最终能覆盖全库 —— 用户在输入时不必等待；
/// - **绝不能**让用户以为「搜不到 = 曲库里没有」。
///
/// ## 遥控器
/// 输入框靠 `Shortcuts` 显式覆盖上下键（Flutter 默认的
/// `DirectionalFocusIntent.ignoreTextFields == true` 会把输入框里的上下键
/// **静默吞掉**，这正是登录页踩过的坑）；结果列表用统一的 [TrackRow]。
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
  final FocusNode _inputNode = FocusNode(debugLabel: 'search.input');
  final FocusNode _backNode = FocusNode(debugLabel: 'search.back');

  String _keyword = '';
  List<Track> _results = const <Track>[];
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    // 进页面就开始建全库索引（后台进行，用户可立即开始输入）
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      context.read<LibraryRepository>().buildFullIndex(); // 不 await：后台慢慢拉
    });
  }

  @override
  void dispose() {
    // ⚠️ controller / node 必须释放。
    _controller.dispose();
    _inputNode.dispose();
    _backNode.dispose();
    super.dispose();
  }

  void _doSearch(String raw) {
    final String q = raw.trim();
    setState(() {
      _keyword = q;
      _results =
          q.isEmpty ? const <Track>[] : context.read<LibraryRepository>().search(q);
      _searched = q.isNotEmpty;
    });
    Log.i('SEARCH_REQUEST keyword=${q.isEmpty ? '(空)' : q} hits=${_results.length}');
  }

  void _play(Track track) {
    final List<Track> results = _results;
    final int index = results.indexWhere((Track t) => t.guid == track.guid);
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
    final String? currentGuid = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.current?.guid,
    );

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
          TraversalDirection.down,
          ignoreTextFields: false,
        ),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
          TraversalDirection.up,
          ignoreTextFields: false,
        ),
      },
      child: Column(
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
      ),
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
                style: TextStyle(fontSize: 18, color: TvColors.textFaint)),
          ],
        ),
      );
    }

    if (!_searched) {
      return const TrackListEmpty(text: '输入歌名 / 歌手 / 专辑开始搜索');
    }

    if (_results.isEmpty) {
      return TrackListEmpty(
        text: '没有匹配「$_keyword」的歌曲\n\n'
            '当前已索引 ${library.tracks.length} 首，'
            '${library.isIndexing ? '索引仍在进行，可稍后再试' : '索引已完成'}。',
      );
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 0, 26, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '找到 ${_results.length} 首（在已索引的 ${library.tracks.length} 首中）',
              style: const TextStyle(fontSize: 16, color: TvColors.textFaint),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            itemCount: _results.length,
            itemBuilder: (BuildContext context, int i) {
              final Track t = _results[i];
              return TrackRow(
                track: t,
                isCurrent: t.guid == currentGuid,
                onPressed: () => _play(t),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SearchHeader extends StatelessWidget {
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

  final TextEditingController controller;
  final FocusNode inputNode;
  final FocusNode backNode;

  /// 搜索范围说明（必须如实显示）。
  final String scopeLabel;
  final bool indexing;

  final VoidCallback onBack;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 14, 26, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              TvFocus(
                focusNode: backNode,
                debugLabel: 'search.back',
                onPressed: onBack,
                builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
                  status: s,
                  radius: 22,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  baseColor: TvColors.panel,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.arrow_back, size: 22, color: TvColors.text),
                      SizedBox(width: 8),
                      Text('返回',
                          style: TextStyle(fontSize: 18, color: TvColors.text)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: inputNode,
                  autofocus: true,
                  style: const TextStyle(fontSize: 20),
                  textInputAction: TextInputAction.search,
                  onChanged: onChanged,
                  onSubmitted: onSubmit,
                  inputFormatters: <TextInputFormatter>[
                    LengthLimitingTextInputFormatter(50),
                  ],
                  decoration: InputDecoration(
                    hintText: '搜索歌名 / 歌手 / 专辑',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: TvColors.panel,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 16),
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
                color: TvColors.textFaint,
              ),
              const SizedBox(width: 6),
              Text(
                indexing ? '正在建立曲库索引 · $scopeLabel' : '搜索范围：$scopeLabel',
                style: const TextStyle(fontSize: 14, color: TvColors.textFaint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
