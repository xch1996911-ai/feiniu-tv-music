import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../domain/track.dart';
import 'music_repository.dart';

/// 曲库加载阶段。
///
/// 顶层枚举（不嵌套在 `LibraryRepository` 里）：嵌套枚举在
/// `LibraryRepository.LibraryPhase.ready` 这种引用形式下容易解析不出，
/// 顶层更省心。
enum LibraryPhase {
  /// 尚未发起任何加载。
  idle,

  /// 首屏加载中。
  loading,

  /// 首屏已就绪，可继续续页。
  ready,

  /// 续页（滚动加载更多）中。
  loadingMore,

  /// 加载失败（可重试）。
  error,

  /// 服务端已无更多数据。
  noMore,
}

/// 曲库分页仓储：管理「全部歌曲」的完整曲库。
///
/// ## 为什么需要它
/// 原实现每次进页面只请求 `getTracks(1, 30)` —— 30 首就到底了。
/// V2 要求完整曲库：进入页面先出第一批，滚动到底自动续页，
/// 并且**播放队列要能跨过分页边界连续播放**（第 30 首播完接第 31 首）。
///
/// ## 分页状态机
/// ```
///   idle ──loadFirst──▶ loading ──成功──▶ ready
///                          │                 │
///                        失败              滚动到底
///                          ▼                 ▼
///                        error ──retry──▶ loading(下一页)
///                                            │
///                                      hasMore=false → noMore
/// ```
/// - 状态全部在 [_phase]，UI 直接读，不自己推导；
/// - [_loading] 保证**同一页不会被并发请求两次**（快速滚动去重）；
/// - 去重按 `guid`（稳定唯一 ID）。
class LibraryRepository extends ChangeNotifier {
  final MusicRepository _music;

  LibraryRepository(this._music);

  /// 每页条数。服务端对 `pageSize` / `limit` 会忽略，只认 `size`。
  static const int pageSize = 50;

  /// 累计的全部歌曲（已去重）。这是 UI 列表与搜索索引的**唯一**数据源。
  List<Track> _tracks = const [];

  /// 已加载到的页码（1 起）。0 = 还没加载过任何页。
  int _page = 0;

  /// 服务端报告的总数；null = 尚未知（首屏未回来）。
  int? _total;

  /// 是否还有下一页。首屏未回来时为 true（先乐观假设有，避免误判 noMore）。
  bool _hasMore = true;

  /// 正在加载中（首屏或续页共用，保证不并发）。
  bool _loading = false;

  /// 错误信息；非 null 时 UI 显示重试按钮。
  String? _error;

  /// 是否已经试过加载且确认没有更多了。
  bool _noMore = false;

  /// 当前阶段，供 UI 区分「首次加载 / 续页失败」两种不同展示。
  LibraryPhase _phase = LibraryPhase.idle;

  // ── 只读状态 ──────────────────────────────────────────────

  List<Track> get tracks => _tracks;
  int get total => _total ?? _tracks.length;
  int get loadedPages => _page;
  bool get hasMore => _hasMore;
  bool get isLoading => _loading;
  bool get isLoadingMore => _phase == LibraryPhase.loadingMore;
  String? get error => _error;
  LibraryPhase get phase => _phase;

  /// 全库索引进度（供搜索页显示「索引中 320/1200」）。
  String get indexProgressLabel =>
      _total == null ? '已加载 ${_tracks.length} 首' : '已索引 ${_tracks.length}/$_total 首';

  // ── 加载 ────────────────────────────────────────────────

  /// 加载第一页（进入页面时调用）。
  ///
  /// 已加载过则**不重复请求**（页面重建 / 返回时不从第 1 页重来）。
  Future<void> loadFirst() async {
    if (_page > 0) {
      Log.i('LIBRARY_PAGE_LOAD 已有数据 page=$_page，跳过首页加载');
      return;
    }
    await _load(1, isFirst: true);
  }

  /// 加载下一页（滚动到底时调用）。
  ///
  /// 内部三重保护：已在加载 / 没有更多 / 同一页在飞 → 直接返回 false。
  Future<bool> loadMore() async {
    if (_loading) {
      Log.i('LIBRARY_PAGE_LOAD 正在加载中，忽略重复请求 page=${_page + 1}');
      return false;
    }
    if (!_hasMore || _noMore) {
      Log.i('LIBRARY_PAGE_LOAD 无更多数据（hasMore=$_hasMore noMore=$_noMore）');
      return false;
    }
    final ok = await _load(_page + 1, isFirst: false);
    return ok;
  }

  /// 错误后重试：首屏失败重试第 1 页，续页失败重试下一页。
  Future<void> retry() async {
    final target = _page == 0 ? 1 : _page + 1;
    Log.i('LIBRARY_PAGE_LOAD retry page=$target');
    await _load(target, isFirst: _page == 0);
  }

  Future<bool> _load(int page, {required bool isFirst}) async {
    // ⚠️ 最后一层并发保护：即使调用方没判 _loading，这里也不会重复发请求。
    if (_loading) return false;
    _loading = true;
    _error = null;
    _phase = isFirst ? LibraryPhase.loading : LibraryPhase.loadingMore;
    _safeNotify();
    Log.i('LIBRARY_PAGE_LOAD page=$page size=$pageSize isFirst=$isFirst');

    final res = await _music.getTracks(page, pageSize);

    _loading = false;

    if (res.isErr) {
      _error = res.error.message;
      _phase = LibraryPhase.error;
      Log.w('LIBRARY_PAGE_ERROR page=$page error=${res.error.kind} ${res.error.message}');
      _safeNotify();
      return false;
    }

    final paged = res.value;
    final added = _merge(paged.items);

    _page = page;
    _total = paged.total;
    // 服务端可能返回空页（如刚好删过歌），此时以「本次没有新数据」为准，
    // 避免因 total 口径差异而无限请求同一页。
    _hasMore = paged.hasMore && (paged.items.isNotEmpty || added > 0);
    if (!_hasMore) {
      _noMore = true;
      _phase = LibraryPhase.noMore;
    } else {
      _phase = LibraryPhase.ready;
    }

    Log.i('LIBRARY_PAGE_SUCCESS page=$page '
        'received=${paged.items.length} added=$added total=${_tracks.length}/$_total '
        'hasMore=$_hasMore');
    // 通知播放层：队列末尾要能接上这一页
    onPageLoaded?.call(added);
    _safeNotify();
    return true;
  }

  /// 分页加载完成回调（由装配层注入，用于把新曲目喂给播放队列）。
  ///
  /// 刻意用回调而不是直接依赖 `PlaybackRepository`：
  /// 曲库层不该知道播放层的存在（反向依赖会让两边都难测）。
  void Function(int addedCount)? onPageLoaded;

  /// 追加曲目并按 guid 去重，返回真正新增的数量。
  int _merge(List<Track> incoming) {
    if (incoming.isEmpty) return 0;
    final seen = <String>{for (final t in _tracks) t.guid};
    final fresh = <Track>[];
    for (final t in incoming) {
      if (t.guid.isEmpty) continue; // 无 id 的曲目无法去重，直接丢弃更安全
      if (seen.add(t.guid)) fresh.add(t);
    }
    if (fresh.isNotEmpty) {
      _tracks = List<Track>.unmodifiable(<Track>[..._tracks, ...fresh]);
    }
    return fresh.length;
  }

  // ── 全库索引（供搜索覆盖全库） ────────────────────────────

  bool _indexing = false;

  /// 是否正在后台建全库索引。
  bool get isIndexing => _indexing;

  /// 后台把曲库分页拉完，用于「搜索全库」。
  ///
  /// ## 为什么要这个
  /// 飞牛**没有搜索 API**（`fnos_endpoints.dart` 里不存在 search 端点），
  /// 只能本地搜。要搜全库，就必须先把全库拉到本地。
  ///
  /// ## 行为约定
  /// - **不阻塞 UI**：首页照常只加载第一页，索引在后台慢慢推进；
  /// - **可重入安全**：重复调用直接复用同一条 Future；
  /// - **失败即停**：任一页失败就结束（不无限重试刷请求），
  ///   用户可稍后再次触发；
  /// - 每页都会通过 [onPageLoaded] 通知播放层，
  ///   因此「正在建索引」的同时全库也在陆续进入播放队列。
  Future<void> buildFullIndex() {
    if (_indexing) {
      Log.i('LIBRARY_INDEX 已在进行中，复用当前任务');
      return _indexFuture ?? Future<void>.value();
    }
    final future = _buildIndex();
    _indexFuture = future;
    return future;
  }

  Future<void>? _indexFuture;

  Future<void> _buildIndex() async {
    _indexing = true;
    Log.i('LIBRARY_INDEX 开始建全库索引（当前 ${_tracks.length} 首）');
    try {
      // 最多 500 页 = 25000 首，超过就认为曲库规模超出预期，停止以免无限拉取。
      var guard = 0;
      while (_hasMore && !_noMore && guard < 500) {
        guard++;
        final ok = await loadMore();
        if (!ok) break; // 已在加载 / 无更多 / 出错 —— 都停
      }
      Log.i('LIBRARY_INDEX 完成，共 ${_tracks.length} '
          '($page 页) hasMore=$_hasMore');
    } finally {
      _indexing = false;
      _safeNotify();
    }
  }

  // ── 搜索 ────────────────────────────────────────────────

  /// 本地搜索：匹配歌名 / 歌手 / 专辑名。
  ///
  /// ⚠️ **只覆盖已加载的 [_tracks]**，因为服务端没有搜索接口。
  /// UI 必须如实告知用户搜索范围（见 [indexProgressLabel]），
  /// 绝不能让用户误以为搜的是全库。
  List<Track> search(String keyword) {
    final q = keyword.trim().toLowerCase();
    if (q.isEmpty) return const <Track>[];
    return _tracks.where((t) {
      if (t.title.toLowerCase().contains(q)) return true;
      if (t.artistNames.toLowerCase().contains(q)) return true;
      if (t.album.name.toLowerCase().contains(q)) return true;
      return false;
    }).toList(growable: false);
  }

  // ── 生命周期 ──────────────────────────────────────────────

  bool _disposed = false;

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
