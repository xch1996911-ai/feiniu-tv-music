import 'package:flutter/foundation.dart';

import '../core/diagnostics.dart';
import '../core/log.dart';
import '../domain/genre.dart';
import '../domain/genre_inferencer.dart';
import '../domain/track.dart';
import '../services/catalogue_store.dart';
import 'music_repository.dart';

/// 曲库加载阶段。
///
/// 顶层枚举（不嵌套在 `LibraryRepository` 里）：嵌套枚举在
/// `LibraryRepository.LibraryPhase.ready` 这种引用形式下容易解析不出，
/// 顶层更省心。
enum LibraryPhase {
  /// 尚未发起任何加载。
  idle,

  /// 正在恢复本地索引（启动时，通常几毫秒）。
  restoring,

  /// 首屏加载中。
  loading,

  /// 首屏已就绪，可继续续页。
  ready,

  /// 续页（滚动加载更多）中。
  loadingMore,

  /// 全库整理（后台把全部页拉完并重建统计）。
  syncing,

  /// 加载失败（可重试）。
  error,

  /// 服务端已无更多数据。
  noMore,
}

/// 曲库整理状态 —— 供 UI 显示「正在整理曲库：已处理 X 首」。
///
/// 需求 §三-A.6 要求「提供简短的『正在整理曲库：已处理X首』状态与手动刷新」，
/// §三-A.7 要求「不能把部分数量显示成全库最终数量」。
/// 两者都要求把「已索引」与「全库总数」**分开**暴露，所以它是独立的
/// 状态对象而不是一个整数。
class CatalogueSyncStatus {
  /// 是否正在整理。
  final bool syncing;

  /// 已索引的**去重后**曲目数。
  final int indexed;

  /// 服务端报告的全库总数。null = 还没拿到（首屏未回）。
  final int? serverTotal;

  /// 索引是否**确认完整**（拉完了全部页且数量与总数一致）。
  final bool complete;

  /// 本次启动是否直接用上了上次的本地索引。
  final bool restoredFromCache;

  /// 上次完成整理的时间。
  final DateTime? savedAt;

  /// 整理过程中的错误（非 null 表示本次未完成）。
  final String? error;

  const CatalogueSyncStatus({
    required this.syncing,
    required this.indexed,
    required this.serverTotal,
    required this.complete,
    required this.restoredFromCache,
    this.savedAt,
    this.error,
  });

  /// 给用户看的**短**状态文案。技术细节在诊断页。
  String get label {
    if (syncing) {
      final int? total = serverTotal;
      return total == null
          ? '正在整理曲库：已处理 $indexed 首'
          : '正在整理曲库：已处理 $indexed/$total 首';
    }
    if (error != null) {
      return complete ? '曲库 $indexed 首（本次更新未完成）' : '曲库未整理完成：$indexed 首';
    }
    if (complete) return '曲库 $indexed 首';
    return '已加载 $indexed 首';
  }
}

/// 全曲库索引 + 分页仓储 —— **歌手/专辑/风格的唯一数据源**。
///
/// ## 为什么重写（V5 §三-A / §三-B 的根因）
///
/// 实机现象：**刚启动时歌手/专辑不全，点开「音乐库」并让它扫到全部音乐后，
/// 分类就恢复正常。**
///
/// 代码层面的根因非常直接：V4 里概览页的数据源是 `library.tracks`，
/// 而它只包含「**用户滚动过的那几页**」：
///
/// - `app_shell` 启动时只调 `loadFirst()`（50 首）；
/// - 只有 `song_list_page` 滚到底才会 `loadMore()`；
/// - `buildFullIndex()` 虽然存在，但**只有一个调用点** —— `search_page`
///   打开时。也就是说：不点搜索、不进音乐库，就永远只有 50 首参与分类。
///
/// 于是「歌手 157 首 / 专辑 25 张」这类统计全都是**首批 50 首的统计**，
/// 而首页卡片里的 2796 首是服务端 `total` —— 两者口径不同，截图里对不上。
///
/// ## V5 的职责
///
/// 本类成为「**完整曲库索引服务**」：
/// 1. **与页面无关**：登录恢复后即可由装配层调用 [startSync]，不要求用户
///    先打开音乐库、先滚动列表；
/// 2. **缓存优先**：启动先读本地索引（[CatalogueStore]），**立刻**给出完整
///    歌手/专辑/风格，再后台核对新增/删除/变更（§三-B.2）；
/// 3. **分页拉全**：按契约用 `page` + `size` 逐页取，直到 `hasMore == false`
///    或数量与 `total` 一致（§三-A.2）；不靠把 pageSize 调大；
/// 4. **去重 + 边界保护**：按稳定 `guid` 去重，检测重复页 / 空页 /
///    总数漂移（§三-A.3）；
/// 5. **半成品不覆盖成品**：分页失败时保留上一次完整索引，只标记未完成
///    （§三-B.3 / §三-A.7）；
/// 6. **不碰播放队列**：全库索引**只**服务分类统计。当前队列仍由用户的
///    播放入口决定（§三-A.10），所以后台整理**不会**调用
///    [onPageLoaded]（那是「播放到队列末尾续页」用的钩子）。
class LibraryRepository extends ChangeNotifier {
  LibraryRepository(this._music, {CatalogueStore? store})
      : _store = store ?? CatalogueStore();

  final MusicRepository _music;
  final CatalogueStore _store;

  /// 每页条数。服务端对 `pageSize` / `limit` 会忽略，只认 `size`。
  static const int pageSize = 50;

  /// 分页硬上限（防御性）：1000 页 = 5 万首。
  ///
  /// 超过就停止并标记未完成，而不是无限请求 —— 服务端若因异常一直返回
  /// `hasMore = true`，没有这个闸门会变成无限循环。
  static const int maxPages = 1000;

  /// 单次整理允许的「总数漂移重扫」次数。
  ///
  /// 扫描期间用户可能正在别的设备上加歌，导致 `total` 变化、页数与总数
  /// 对不上。此时**自动重扫一次**对齐；仍不一致就如实标记未完成。
  static const int maxRealignAttempts = 1;

  /// 进度通知节流间隔（避免每页都触发整页重建）。
  static const Duration _notifyThrottle = Duration(milliseconds: 200);

  // ── 可见曲库（UI 与分类都读它）────────────────────────────

  List<Track> _tracks = const <Track>[];

  /// 分页游标（1 起）。0 = 还没加载过任何页。
  int _page = 0;

  /// 服务端报告的总数。
  int? _total;

  bool _hasMore = true;
  bool _loading = false;
  String? _error;
  bool _noMore = false;
  LibraryPhase _phase = LibraryPhase.idle;

  // ── 索引状态 ──────────────────────────────────────────────

  String? _identity;
  bool _complete = false;
  DateTime? _savedAt;
  int _loadedRuleVersion = 0;
  bool _restoredFromCache = false;
  bool _syncing = false;
  Future<void>? _syncFuture;
  Map<String, List<GenreAssignment>> _genres = <String, List<GenreAssignment>>{};
  GenreInferenceResult? _inference;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  // ── 只读状态 ──────────────────────────────────────────────

  /// 已索引的曲目（去重）。**分类统计与列表渲染都基于它。**
  List<Track> get tracks => _tracks;

  /// 服务端全库总数（未知时退回已加载数量）。
  ///
  /// ⚠️ UI **必须**用 [syncStatus] 区分「已索引」与「全库总数」，
  /// 不能把 `tracks.length` 当成全库（§三-A.7）。
  int get total => _total ?? _tracks.length;

  /// 服务端总数是否已知。
  int? get serverTotalOrNull => _total;

  int get loadedPages => _page;
  bool get hasMore => _hasMore;
  bool get isLoading => _loading;
  bool get isLoadingMore => _phase == LibraryPhase.loadingMore;
  String? get error => _error;
  LibraryPhase get phase => _phase;

  /// 索引是否已确认完整。
  bool get indexComplete => _complete;

  /// 整理状态（供 UI 显示进度与手动刷新）。
  CatalogueSyncStatus get syncStatus => CatalogueSyncStatus(
        syncing: _syncing,
        indexed: _tracks.length,
        serverTotal: _total,
        complete: _complete,
        restoredFromCache: _restoredFromCache,
        savedAt: _savedAt,
        error: _error,
      );

  /// 全库索引进度（兼容旧调用点）。
  String get indexProgressLabel => syncStatus.label;

  /// 风格归纳结果（可能为 null：还没整理或库里没有任何曲目）。
  GenreInferenceResult? get genreInference => _inference;

  /// 曲目标识 → 风格归属。
  Map<String, List<GenreAssignment>> get genreAssignments => _genres;

  // ── 手动风格覆盖的接线 ────────────────────────────────────

  /// 由装配层注入「用户手动风格」的读取器（数据在 `LocalLibraryRepository`）。
  ///
  /// 刻意用回调而不是直接依赖：曲库层不该知道用户数据层。
  Map<String, List<String>> Function()? _overridesProvider;

  /// 用户改过风格后由装配层触发重算。
  VoidCallback? onOverridesChanged;

  void attachGenreOverrides(
      Map<String, List<String>> Function() provider) {
    _overridesProvider = provider;
  }

  // ── 整理（核心）───────────────────────────────────────────

  /// 启动/切换账户时的入口。
  ///
  /// [identity] 是「NAS + 账户」的稳定标识，用于**多账户隔离**
  /// （§三-A.9：切换 NAS/账户时不能串数据）。
  ///
  /// 流程：
  /// 1. 若是首次（或 [force]），先读本地索引 → **立刻**有完整分类；
  /// 2. 然后后台全量核对（[force] 时忽略缓存直接重扫）。
  ///
  /// 可重入：正在整理时重复调用返回同一条 Future。
  Future<void> startSync(String identity, {bool force = false}) {
    if (_syncing && _identity == identity) {
      Log.i('LIBRARY_SYNC 已在进行中，复用当前任务');
      return _syncFuture ?? Future<void>.value();
    }
    final Future<void> future = _startSync(identity, force: force);
    _syncFuture = future;
    return future;
  }

  Future<void> _startSync(String identity, {required bool force}) async {
    _syncing = true;
    if (_identity != identity) {
      // 换了账户 / NAS：先清空上一份索引，避免串数据。
      if (_identity != null) {
        Log.i('LIBRARY_SYNC 身份变更 $_identity → $identity，清空上一份索引');
      }
      _tracks = const <Track>[];
      _page = 0;
      _total = null;
      _hasMore = true;
      _noMore = false;
      _complete = false;
      _savedAt = null;
      _genres = <String, List<GenreAssignment>>{};
      _inference = null;
      _restoredFromCache = false;
      _identity = identity;
    }

    if (!force && !_restoredFromCache && _tracks.isEmpty) {
      _phase = LibraryPhase.restoring;
      _safeNotify(force: true);
      await _restoreCache(identity);
    }

    _safeNotify(force: true);
    await _syncAll();

    _syncing = false;
    if (_phase == LibraryPhase.syncing) {
      _phase = _complete ? LibraryPhase.noMore : LibraryPhase.ready;
    }
    _safeNotify(force: true);
  }

  /// 读取本地索引并采用（不完整索引只在「手上什么都没有」时才采用）。
  Future<void> _restoreCache(String identity) async {
    try {
      final CatalogueSnapshot? snap = await _store.load(identity);
      if (snap == null) return;
      _tracks = List<Track>.unmodifiable(snap.tracks);
      _total = snap.serverTotal > 0 ? snap.serverTotal : snap.tracks.length;
      _complete = snap.complete;
      _savedAt = snap.savedAt;
      _loadedRuleVersion = snap.ruleVersion;
      _restoredFromCache = true;
      _hasMore = !snap.complete;
      _noMore = snap.complete;

      if (snap.ruleVersion == GenreRules.version && snap.genres.isNotEmpty) {
        _genres = snap.genres;
        _inference = GenreInferenceResult(
          byGuid: snap.genres,
          totalTracks: snap.tracks.length,
        );
      } else {
        // 规则版本变了（或当初没存）→ 立刻用新规则重算，不等联网。
        _recomputeGenres();
      }

      Log.i('LIBRARY_SYNC 已采用本地索引 ${snap.tracks.length} 首 · '
          '完整=${snap.complete} · 保存于 ${snap.savedAt}');
      Diagnostics.note('曲库索引',
          '已从本地索引恢复 ${snap.tracks.length} 首（完整=${snap.complete}，'
          '保存于 ${snap.savedAt ?? '未知时间'}）');
    } catch (e) {
      Log.w('LIBRARY_SYNC 读取本地索引失败（按需重新扫描）：$e');
    }
  }

  /// 后台把全部页拉完。
  Future<void> _syncAll() async {
    if (_loading) {
      Log.i('LIBRARY_SYNC 有分页请求在飞，跳过本次整理');
      return;
    }
    _phase = LibraryPhase.syncing;
    _error = null;
    _safeNotify(force: true);

    final List<Track> previous = _tracks;
    final bool hadComplete = _complete;

    for (int attempt = 0; attempt <= maxRealignAttempts; attempt++) {
      final _ScanResult res = await _scanPages(attempt: attempt);
      if (res.error != null) {
        _error = res.error;
        _phase = LibraryPhase.error;
        // ⚠️ 半成品不覆盖已完成的索引（§三-B.3）。
        if (!hadComplete && res.tracks.isNotEmpty) {
          _tracks = List<Track>.unmodifiable(res.tracks);
        } else if (hadComplete) {
          _tracks = previous;
        }
        _complete = false;
        Diagnostics.note('曲库索引',
            '本次整理未完成（第 ${res.pages} 页失败）：${res.error}；'
            '当前显示 ${_tracks.length} 首');
        Diagnostics.event('曲库整理中断：${res.error}');
        _recomputeGenres();
        return;
      }

      // 数量与总数一致（或服务端已明确没有更多）→ 认为拉全了。
      final bool consistent = res.tracks.length == res.serverTotal ||
          res.serverTotal == 0;
      if (consistent || attempt == maxRealignAttempts) {
        _tracks = List<Track>.unmodifiable(res.tracks);
        _total = res.serverTotal > 0 ? res.serverTotal : res.tracks.length;
        _complete = consistent;
        _savedAt = DateTime.now();
        _noMore = _complete;
        _hasMore = !_complete;
        _page = res.pages;
        _phase = _complete ? LibraryPhase.noMore : LibraryPhase.ready;

        _recomputeGenres();
        _reportRescan(previous, res);

        if (_complete) {
          await _persist();
        } else {
          Log.w('LIBRARY_SYNC 未能对齐：索引 ${res.tracks.length} 首 '
              '≠ 服务端总数 ${res.serverTotal}（可能扫描期间曲库有变更）');
          Diagnostics.note(
              '曲库索引',
              '未完成对齐：已索引 ${res.tracks.length} 首，服务端报告 '
              '${res.serverTotal} 首 —— 不会把它显示成全库最终数量');
        }
        return;
      }

      Log.w('LIBRARY_SYNC 第 ${attempt + 1} 次扫描数量不符'
          '（${res.tracks.length}/${res.serverTotal}），重扫对齐');
      Diagnostics.event('曲库数量不符（${res.tracks.length}/${res.serverTotal}），'
          '自动重扫第 ${attempt + 2} 次');
    }
  }

  /// 逐页扫描。返回**去重后**的全部曲目与完成情况。
  Future<_ScanResult> _scanPages({required int attempt}) async {
    final List<Track> acc = <Track>[];
    final Set<String> seen = <String>{};
    int page = 1;
    int? serverTotal;
    int guard = 0;

    while (guard < maxPages) {
      guard++;
      final res = await _music.getTracks(page, pageSize);
      if (res.isErr) {
        Log.w('LIBRARY_SYNC 第 $page 页失败：${res.error.message}');
        // 失败时**保留已取得的数据**（§三-A.7），并回报错误。
        return _ScanResult(
          tracks: acc,
          serverTotal: serverTotal ?? acc.length,
          pages: page - 1,
          error: res.error.message,
        );
      }
      final paged = res.value;
      serverTotal = paged.total;

      int fresh = 0;
      for (final Track t in paged.items) {
        if (t.guid.isEmpty) continue;
        if (seen.add(t.guid)) {
          acc.add(t);
          fresh++;
        }
      }

      if (page == 1) {
        _safeNotify(force: true); // 首屏尽快可见
      } else {
        _safeNotify();
      }

      // 空页 / 全重复页：服务端没有更多有效数据了（防止游标不前进导致死循环）。
      if (paged.items.isEmpty || fresh == 0) {
        Log.i('LIBRARY_SYNC 第 $page 页无新增（items=${paged.items.length} '
            'fresh=$fresh），停止扫描');
        break;
      }
      if (!paged.hasMore) break;
      page++;
    }

    final int total = serverTotal ?? acc.length;
    final bool reachedEnd = guard < maxPages;
    return _ScanResult(
      tracks: acc,
      serverTotal: total,
      pages: page,
      error: reachedEnd ? null : '分页超出上限（$maxPages 页），已停止以免无限请求',
    );
  }

  /// 重算风格归纳（纯本地、无网络）。
  void _recomputeGenres() {
    try {
      final Map<String, List<String>> overrides =
          _overridesProvider?.call() ?? const <String, List<String>>{};
      final GenreInferenceResult result =
          GenreInferencer.infer(_tracks, overrides: overrides);
      _inference = result;
      _genres = result.byGuid;
      _loadedRuleVersion = result.ruleVersion;
      Log.i('LIBRARY_GENRE 归纳完成：有结论 ${result.classified} 首 · '
          '待分类 ${result.unclassified} 首 · 规则版本 ${result.ruleVersion}');
      Diagnostics.note(
          '风格归纳',
          '规则版本 ${result.ruleVersion}：有结论 ${result.classified} 首，'
          '待分类 ${result.unclassified} 首（共 ${result.totalTracks} 首）');
    } catch (e, st) {
      Log.e('LIBRARY_GENRE 归纳失败（风格页将显示空态）', e, st);
      Diagnostics.event('风格归纳失败：$e');
    }
  }

  /// 用户改了手动风格后重算。
  void refreshGenres() {
    _recomputeGenres();
    // 归纳结果变了：同步落盘，避免重启后又回到旧结论。
    if (_complete) {
      _persist();
    }
    _safeNotify(force: true);
  }

  void _reportRescan(List<Track> previous, _ScanResult res) {
    if (previous.isEmpty) return;
    final Map<String, Track> before = <String, Track>{
      for (final Track t in previous) t.guid: t,
    };
    final Map<String, Track> after = <String, Track>{
      for (final Track t in res.tracks) t.guid: t,
    };
    final int added = after.keys.where((String g) => !before.containsKey(g)).length;
    final int removed =
        before.keys.where((String g) => !after.containsKey(g)).length;
    int changed = 0;
    for (final MapEntry<String, Track> e in after.entries) {
      final Track? old = before[e.key];
      if (old == null) continue;
      if (old.title != e.value.title ||
          old.updatedAt != e.value.updatedAt ||
          old.genres.length != e.value.genres.length) {
        changed++;
      }
    }
    Log.i('LIBRARY_SYNC 增量核对：新增 $added · 删除 $removed · 变更 $changed '
        '（上次 ${previous.length} 首 → 本次 ${res.tracks.length} 首）');
    if (added != 0 || removed != 0 || changed != 0) {
      Diagnostics.event(
          '曲库增量核对：新增 $added 首、删除 $removed 首、变更 $changed 首');
    }
  }

  Future<void> _persist() async {
    final String? identity = _identity;
    if (identity == null) return;
    try {
      await _store.save(CatalogueSnapshot(
        identity: identity,
        savedAt: _savedAt ?? DateTime.now(),
        complete: _complete,
        serverTotal: _total ?? _tracks.length,
        tracks: _tracks,
        genres: _genres,
        ruleVersion: _loadedRuleVersion,
      ));
    } catch (e) {
      Log.w('LIBRARY_SYNC 索引落盘失败（内存已生效）：$e');
    }
  }

  /// 手动「刷新曲库 / 重建索引」（§三-A.6 / §三-B.6）。
  ///
  /// 语义与首次整理一致：**不**清空当前分类再逐页重建（那会让页面闪烁），
  /// 而是后台扫完后原子切换；扫描失败则保留当前数据。
  Future<void> rebuildIndex() async {
    final String? identity = _identity;
    if (identity == null) {
      Log.w('LIBRARY_SYNC 尚未绑定身份，无法重建索引');
      return;
    }
    Diagnostics.event('用户手动触发重建索引');
    await startSync(identity, force: true);
  }

  // ── 分页（列表页仍按需加载，不做一次性创建全部控件）────────────

  /// 加载第一页（进入列表页时调用）。已加载过则跳过。
  Future<void> loadFirst() async {
    if (_page > 0) {
      Log.i('LIBRARY_PAGE_LOAD 已有数据 page=$_page，跳过首页加载');
      return;
    }
    await _load(1, isFirst: true);
  }

  /// 加载下一页（滚动到底时调用）。
  Future<bool> loadMore() async {
    if (_loading) {
      Log.i('LIBRARY_PAGE_LOAD 正在加载中，忽略重复请求 page=${_page + 1}');
      return false;
    }
    if (!_hasMore || _noMore) {
      Log.i('LIBRARY_PAGE_LOAD 无更多数据（hasMore=$_hasMore noMore=$_noMore）');
      return false;
    }
    return _load(_page + 1, isFirst: false);
  }

  /// 错误后重试。
  Future<void> retry() async {
    final int target = _page == 0 ? 1 : _page + 1;
    Log.i('LIBRARY_PAGE_LOAD retry page=$target');
    await _load(target, isFirst: _page == 0);
  }

  Future<bool> _load(int page, {required bool isFirst}) async {
    if (_loading) return false;
    _loading = true;
    _error = null;
    _phase = isFirst ? LibraryPhase.loading : LibraryPhase.loadingMore;
    _safeNotify(force: true);
    Log.i('LIBRARY_PAGE_LOAD page=$page size=$pageSize isFirst=$isFirst');

    final res = await _music.getTracks(page, pageSize);

    _loading = false;

    if (res.isErr) {
      _error = res.error.message;
      _phase = LibraryPhase.error;
      Log.w('LIBRARY_PAGE_ERROR page=$page error=${res.error.kind} '
          '${res.error.message}');
      _safeNotify(force: true);
      return false;
    }

    final paged = res.value;
    final int added = _merge(paged.items);

    _page = page;
    _total = paged.total;
    _hasMore = paged.hasMore && (paged.items.isNotEmpty || added > 0);
    if (!_hasMore) {
      _noMore = true;
      _phase = LibraryPhase.noMore;
    } else {
      _phase = LibraryPhase.ready;
    }

    Log.i('LIBRARY_PAGE_SUCCESS page=$page received=${paged.items.length} '
        'added=$added total=${_tracks.length}/$_total hasMore=$_hasMore');
    // 通知播放层：队列末尾要能接上这一页。
    //
    // ⚠️ 只有「播放到队列末尾触发续页」这条路径才该调用它。
    //    后台全库整理**不调用**（§三-A.10：索引不得把整个曲库塞进播放队列）。
    onPageLoaded?.call(added);
    _recomputeGenres();
    _safeNotify(force: true);
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
    final Set<String> seen = <String>{for (final Track t in _tracks) t.guid};
    final List<Track> fresh = <Track>[];
    for (final Track t in incoming) {
      if (t.guid.isEmpty) continue;
      if (seen.add(t.guid)) fresh.add(t);
    }
    if (fresh.isNotEmpty) {
      _tracks = List<Track>.unmodifiable(<Track>[..._tracks, ...fresh]);
    }
    return fresh.length;
  }

  // ── 搜索 ────────────────────────────────────────────────

  /// 本地搜索：匹配歌名 / 歌手 / 专辑名。
  ///
  /// ⚠️ 飞牛**没有搜索接口**，因此只覆盖已索引的 [_tracks]。
  /// 全库整理完成后即为全库范围；未完成时 UI 必须如实说明范围
  /// （见 [syncStatus] 的 `complete`）。
  List<Track> search(String keyword) {
    final String q = keyword.trim().toLowerCase();
    if (q.isEmpty) return const <Track>[];
    return _tracks.where((Track t) {
      if (t.title.toLowerCase().contains(q)) return true;
      if (t.artistNames.toLowerCase().contains(q)) return true;
      if (t.album.name.toLowerCase().contains(q)) return true;
      return false;
    }).toList(growable: false);
  }

  // ── 生命周期 ──────────────────────────────────────────────

  bool _disposed = false;

  void _safeNotify({bool force = false}) {
    if (_disposed) return;
    if (!force) {
      final DateTime now = DateTime.now();
      if (now.difference(_lastNotify) < _notifyThrottle) return;
      _lastNotify = now;
    } else {
      _lastNotify = DateTime.now();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 一次全量扫描的结果。
class _ScanResult {
  final List<Track> tracks;
  final int serverTotal;
  final int pages;
  final String? error;

  const _ScanResult({
    required this.tracks,
    required this.serverTotal,
    required this.pages,
    required this.error,
  });
}
