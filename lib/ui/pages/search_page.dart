import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/artist.dart';
import '../../domain/search_index.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/auth_repository.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../../services/search_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/empty_state.dart';
import '../widgets/track_row.dart';
import '../widgets/tv_focus.dart';

/// 搜索页。
///
/// ## 搜索范围必须如实告知用户
/// 飞牛音乐**没有服务端搜索接口**（`fnos_endpoints.dart` 里不存在 search 端点），
/// 所以搜索是**本地**的，只能命中「已索引进内存的曲目」。
/// 全库整理由 `LibraryRepository.startSync()` 在登录后统一负责（不依赖本页），
/// 本页只如实显示「已索引 N 首 / 全库 M 首」以及「曲库仍在整理」。
///
/// ## 能搜什么（V5 新增拼音）
/// `SearchService` 支持：中文原文、拼音全拼（`zhoujielun`）、
/// 首字母（`zjl`，含前缀 `zj`）、部分拼音（`zhoujie` / `jielun`）、
/// 中英混合（`周jl`）、英文大小写不敏感、空格与全半角归一化，
/// 以及足够长查询的轻微拼写纠错（`zhoujielnu`）。
/// 结果按 **歌曲 / 歌手 / 专辑** 分区展示，歌手与专辑可点开进入详情。
///
/// ## 防抖与过期结果
/// 需求（拼音模糊搜索 §4）明确要求「输入 150–300ms 防抖」且
/// 「防止上一次查询的晚到结果覆盖最新结果」。
/// 前者由 [SearchPage.debounce] 负责，后者由 `SearchOutcome.seq` 负责 ——
/// 只采纳**序号更大**的结果，晚到的旧结果直接丢弃。
///
/// ## 遥控器
/// 输入框靠 `Shortcuts` 显式覆盖上下键（Flutter 默认的
/// `DirectionalFocusIntent.ignoreTextFields == true` 会把输入框里的上下键
/// **静默吞掉**，这是登录页踩过的坑）；结果列表用统一的 [TrackRow]。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.onBack,
    required this.onOpenPlayer,
  });

  final VoidCallback onBack;
  final VoidCallback onOpenPlayer;

  /// 输入防抖时长。需求给的区间是 150–300ms，取中间值。
  static const Duration debounce = Duration(milliseconds: 220);

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputNode = FocusNode(debugLabel: 'search.input');
  final FocusNode _backNode = FocusNode(debugLabel: 'search.back');
  final FocusNode _detailBackNode = FocusNode(debugLabel: 'search.detail.back');

  Timer? _debounce;

  /// 已采纳的最大查询序号（见类文档「防抖与过期结果」）。
  int _acceptedSeq = 0;

  SearchResults _results = SearchResults.empty;
  bool _searched = false;

  /// 打开中的歌手 / 专辑详情；null = 正在看结果列表。
  _EntityDetail? _detail;

  @override
  void initState() {
    super.initState();
    // 进页面就兜底推进全库整理（后台进行，用户可立即输入）。
    // ⚠️ 正常情况下这件事由登录后的 `startSync` 完成，这里只是兜底。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      unawaited(context.read<LibraryRepository>().startSync(
            context.read<AuthRepository>().catalogueIdentity,
          ));
    });
  }

  @override
  void dispose() {
    // ⚠️ timer / controller / node 必须释放。
    _debounce?.cancel();
    _controller.dispose();
    _inputNode.dispose();
    _backNode.dispose();
    _detailBackNode.dispose();
    super.dispose();
  }

  /// 输入变化：立即更新「是否已输入」的状态，但**延迟**真正查询。
  void _onChanged(String raw) {
    final String q = raw.trim();
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() {
        _searched = false;
        _results = SearchResults.empty;
      });
      return;
    }
    if (!_searched) setState(() => _searched = true);
    _debounce = Timer(SearchPage.debounce, () => unawaited(_run(raw)));
  }

  /// 回车（遥控器 OK）：跳过防抖立刻查。
  void _onSubmitted(String raw) {
    _debounce?.cancel();
    unawaited(_run(raw));
  }

  Future<void> _run(String raw) async {
    final String q = raw.trim();
    if (q.isEmpty) return;
    final LibraryRepository library = context.read<LibraryRepository>();
    final SearchService svc = library.searchService;
    // 同步对齐一次：保证「刚打开搜索就能搜到已加载的曲目」。
    svc.ensureSync(
      library.tracks,
      identity: context.read<AuthRepository>().catalogueIdentity,
      complete: library.indexComplete,
    );
    final SearchOutcome out = await svc.search(q);
    if (!mounted) return;
    // ⚠️ 只采纳比已采纳序号更大的结果 —— 晚到的旧结果必须丢弃，
    //    否则界面会从「周杰伦」倒退回一大片无关结果。
    if (out.superseded || out.seq <= _acceptedSeq) {
      Log.i('SEARCH_UI 丢弃过期结果 seq=${out.seq} 已采纳=$_acceptedSeq');
      return;
    }
    _acceptedSeq = out.seq;
    setState(() {
      _results = out.results;
      _searched = true;
    });
    Log.i('SEARCH_UI 采纳 seq=${out.seq} 歌曲=${out.results.songs.length} '
        '歌手=${out.results.artists.length} 专辑=${out.results.albums.length} '
        '模糊=${out.results.fuzzyUsed}');
  }

  void _playSongs(List<Track> tracks, int index) {
    if (index < 0 || index >= tracks.length) return;
    Log.i('SEARCH_PLAY index=$index guid=${tracks[index].guid}');
    // 搜索结果建立**独立**队列，不污染「全部歌曲」队列。
    context.read<PlaybackRepository>().playQueue(
          tracks,
          source: QueueSource.search,
          startIndex: index,
        );
    widget.onOpenPlayer();
  }

  void _openEntity(EntityHit hit, {required bool isArtist}) {
    final List<Track> tracks = _tracksOfEntity(hit, isArtist: isArtist);
    if (tracks.isEmpty) return;
    Log.i('SEARCH_OPEN_ENTITY artist=$isArtist name=${hit.name} '
        'tracks=${tracks.length}');
    setState(() {
      _detail = _EntityDetail(
        name: hit.name,
        coverId: hit.coverId,
        tracks: tracks,
        isArtist: isArtist,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      // ⚠️ 必须显式 requestFocus：进入详情后原来那一行被卸载，
      //    焦点会「无处可去」，遥控器下一次按键就是没反应。
      _detailBackNode.requestFocus();
    });
  }

  void _closeDetail() {
    if (_detail == null) return;
    setState(() => _detail = null);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      // 结果是本页搜出来的，焦点交给输入框最自然。
      _inputNode.requestFocus();
    });
  }

  /// 把实体的曲目取出来。
  ///
  /// 用**与曲库概览页相同的分组口径**（专辑按 guid 优先、名字兜底），
  /// 这样「搜索结果点进去」和「专辑页点进去」看到的是同一批曲目。
  List<Track> _tracksOfEntity(EntityHit hit, {required bool isArtist}) {
    final List<Track> all = context.read<LibraryRepository>().tracks;
    if (isArtist) {
      return <Track>[
        for (final Track t in all)
          if (t.artists.any((ArtistRef a) => a.name.trim() == hit.name)) t,
      ];
    }
    return <Track>[
      for (final Track t in all)
        if ('al:${t.album.guid}' == hit.key ||
            (t.album.guid.trim().isEmpty && t.album.name.trim() == hit.name))
          t,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final LibraryRepository library = context.watch<LibraryRepository>();
    final String? currentGuid = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.current?.guid,
    );

    final _EntityDetail? detail = _detail;
    if (detail != null) {
      return _buildDetail(detail, currentGuid);
    }

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
            indexing: library.syncStatus.syncing,
            onBack: widget.onBack,
            onSubmit: _onSubmitted,
            onChanged: _onChanged,
          ),
          Expanded(child: _buildBody(library, currentGuid)),
        ],
      ),
    );
  }

  Widget _buildBody(LibraryRepository library, String? currentGuid) {
    // 曲库还一首都没来 → 如实提示正在整理（不是「没找到」）。
    if (library.tracks.isEmpty && library.syncStatus.syncing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在更新曲库…',
                style: TextStyle(fontSize: 18, color: TvColors.textFaint)),
          ],
        ),
      );
    }

    if (!_searched) {
      return const EmptyState(
        title: '输入歌名 / 歌手 / 专辑',
        icon: Icons.search,
        hint: '支持拼音与首字母（zjl → 周杰伦）',
      );
    }

    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: '没有找到匹配的歌曲',
        hint: library.syncStatus.complete
            ? '已搜索全库 ${_results.indexedTracks} 首'
            : '已搜索 ${_results.indexedTracks} 首 · 曲库仍在整理',
      );
    }

    final List<SearchHit> songs = _results.songs;
    final List<EntityHit> artists = _results.artists;
    final List<EntityHit> albums = _results.albums;
    final List<Track> songTracks = <Track>[
      for (final SearchHit h in songs) h.track,
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: <Widget>[
        _ResultScope(
          total: _results.totalSongs,
          indexed: _results.indexedTracks,
          complete: _results.indexComplete,
          fuzzyUsed: _results.fuzzyUsed,
        ),
        if (artists.isNotEmpty) ...<Widget>[
          const _SectionTitle('歌手'),
          for (final EntityHit e in artists)
            _EntityRow(
              hit: e,
              round: true,
              onPressed: () => _openEntity(e, isArtist: true),
            ),
        ],
        if (albums.isNotEmpty) ...<Widget>[
          const _SectionTitle('专辑'),
          for (final EntityHit e in albums)
            _EntityRow(
              hit: e,
              round: false,
              onPressed: () => _openEntity(e, isArtist: false),
            ),
        ],
        if (songTracks.isNotEmpty) ...<Widget>[
          const _SectionTitle('歌曲'),
          for (int i = 0; i < songTracks.length; i++)
            TrackRow(
              track: songTracks[i],
              isCurrent: songTracks[i].guid == currentGuid,
              onPressed: () => _playSongs(songTracks, i),
            ),
        ],
      ],
    );
  }

  // ── 歌手 / 专辑详情 ────────────────────────────────────────

  Widget _buildDetail(_EntityDetail d, String? currentGuid) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Row(
            children: <Widget>[
              TvFocus(
                focusNode: _detailBackNode,
                debugLabel: 'search.detail.back',
                onPressed: _closeDetail,
                builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
                  status: s,
                  radius: 22,
                  padding: EdgeInsets.zero,
                  width: 46,
                  height: 46,
                  baseColor: const Color(0x33FFFFFF),
                  child: const Icon(Icons.arrow_back,
                      size: 24, color: TvColors.text),
                ),
              ),
              const SizedBox(width: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(d.isArtist ? 26 : 10),
                child: CoverImage(
                  music: context.read<MusicRepository>(),
                  coverId: d.coverId,
                  size: 52,
                  radius: d.isArtist ? 26 : 10,
                  iconScale: 0.4,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      d.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: TvColors.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${d.tracks.length} 首',
                      style: const TextStyle(
                          fontSize: 15, color: TvColors.textFaint),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            itemCount: d.tracks.length,
            itemBuilder: (BuildContext context, int i) => TrackRow(
              track: d.tracks[i],
              isCurrent: d.tracks[i].guid == currentGuid,
              onPressed: () => _playSongs(d.tracks, i),
            ),
          ),
        ),
      ],
    );
  }
}

/// 打开中的歌手 / 专辑详情。
class _EntityDetail {
  const _EntityDetail({
    required this.name,
    required this.coverId,
    required this.tracks,
    required this.isArtist,
  });

  final String name;
  final String? coverId;
  final List<Track> tracks;
  final bool isArtist;
}

/// 搜索范围与新能力的**如实说明**。
class _ResultScope extends StatelessWidget {
  const _ResultScope({
    required this.total,
    required this.indexed,
    required this.complete,
    required this.fuzzyUsed,
  });

  final int total;
  final int indexed;
  final bool complete;
  final bool fuzzyUsed;

  @override
  Widget build(BuildContext context) {
    final String scope =
        complete ? '已搜索全库 $indexed 首' : '已搜索 $indexed 首 · 曲库仍在整理';
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
      child: Row(
        children: <Widget>[
          Text(
            '找到 $total 首 · $scope',
            style: const TextStyle(fontSize: 15, color: TvColors.textFaint),
          ),
          if (fuzzyUsed) ...<Widget>[
            const SizedBox(width: 10),
            const Text(
              '（含近似匹配）',
              style: TextStyle(fontSize: 14, color: TvColors.warn),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: TvColors.textDim,
          ),
        ),
      );
}

/// 歌手 / 专辑结果行。
class _EntityRow extends StatelessWidget {
  const _EntityRow({
    required this.hit,
    required this.round,
    required this.onPressed,
  });

  final EntityHit hit;
  final bool round;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      debugLabel: 'search.entity.${hit.key}',
      onPressed: onPressed,
      builder: (BuildContext context, TvFocusStatus s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: TvFocusRing(
          status: s,
          radius: 14,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(round ? 20 : 8),
                child: CoverImage(
                  music: context.read<MusicRepository>(),
                  coverId: hit.coverId,
                  size: 40,
                  radius: round ? 20 : 8,
                  iconScale: 0.44,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  hit.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: TvColors.text,
                  ),
                ),
              ),
              Text(
                '${hit.trackCount} 首',
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.2,
                  color: TvColors.textFaint,
                ),
              ),
              const SizedBox(width: 10),
              const Icon(Icons.chevron_right,
                  size: 22, color: TvColors.textFaint),
            ],
          ),
        ),
      ),
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
                  decoration: const InputDecoration(
                    // ⚠️ 提示文字必须把「支持拼音与首字母」说清楚，
                    //    否则遥控器用户根本不知道能打字母找中文歌。
                    hintText: '搜索歌曲 / 歌手 / 专辑，支持拼音与首字母',
                    hintStyle:
                        TextStyle(fontSize: 17, color: TvColors.textFaint),
                    prefixIcon: Icon(Icons.search),
                    filled: true,
                    fillColor: TvColors.panel,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(24)),
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 18, vertical: 16),
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
                indexing ? '正在更新曲库 · $scopeLabel' : '搜索范围：$scopeLabel',
                style: const TextStyle(fontSize: 14, color: TvColors.textFaint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
