import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diagnostics.dart';
import '../core/log.dart';
import '../domain/artist.dart';
import '../domain/pinyin_service.dart';
import '../domain/search_index.dart';
import '../domain/text_norm.dart';
import '../domain/track.dart';
import 'search_index_store.dart';

/// 一次查询的结果 + 它的**序号**。
///
/// ## 为什么必须带序号
///
/// 需求（拼音模糊搜索 §4）明确要求：
/// 「输入适当防抖；防止上一次查询的晚到结果覆盖最新查询结果」。
///
/// 防抖只能减少请求数，**不能**保证返回顺序：用户快速输入 `z` → `zj` → `zjl`
/// 时，如果 `z` 的结果因为任何原因最后才回来，界面就会从「周杰伦」倒退回
/// 一大片无关结果，而且看上去像是「搜索错了」。
///
/// 因此把「这次结果是第几次查询」一起交给调用方：UI 只接受
/// `outcome.seq == 自己记的最新序号` 的结果，其余一律丢弃。
/// [superseded] 只是一个便利判据（`seq != 最新`）。
class SearchOutcome {
  const SearchOutcome({
    required this.seq,
    required this.superseded,
    required this.results,
  });

  /// 本次查询的序号（从 1 开始，单调递增）。
  final int seq;

  /// 结果生成之后，是否又有更新的查询发起过。为 true 时调用方**必须丢弃**。
  final bool superseded;

  final SearchResults results;

  static const SearchOutcome idle = SearchOutcome(
    seq: 0,
    superseded: false,
    results: SearchResults.empty,
  );
}

/// 全库搜索服务 —— **电视端与手机遥控共用的唯一搜索入口**。
///
/// ## 职责
/// 1. **建索引**：把 `LibraryRepository` 已经整理好的同一批 `Track` 对象
///    转成可检索的键（归一化原文 + 逐字拼音 + 首字母）；
/// 2. **增量维护**：按 guid 复用未变化条目的键，只重算真正变了的曲目
///    （需求 §4「后台曲库增删改时增量维护」）；
/// 3. **持久缓存**：落盘到 `SearchIndexStore`，重启后直接可搜索
///    （需求 §4「拼音索引要持久缓存，账号/服务器隔离」）；
/// 4. **不阻塞**：全量转换按 [chunkSize] 分片，每片之间让出一次事件循环，
///    避免在低端电视盒子上出现「输入卡住」或音频掉帧；
/// 5. **防过期**：见 [SearchOutcome]。
///
/// ## 为什么不另建数据源
/// 需求 §6 明确禁止「另起一套平行的曲库数据源」。
/// 本服务**不持有自己的曲目池**：[sync] 的入参就是 `LibraryRepository.tracks`，
/// 索引项里也只保存「检索键」，曲目本体是同一个 `Track` 引用。
///
/// ## 为什么用分片而不是 isolate
/// `pinyin` 包的字表/词组表是 2MB 级的 Dart 常量数据，spawn 一个新 isolate
/// 会把它们**再加载一遍**（电视盒子内存本来就不宽裕），而且跨 isolate 传
/// 几千条结果还要序列化。真正的诉求是「不要卡住播放和界面」，分片让出
/// 事件循环以极低的代价达到同一效果，且行为完全可预测、可测试。
class SearchService extends ChangeNotifier {
  SearchService({SearchIndexStore? store})
      : _store = store ?? SearchIndexStore();

  final SearchIndexStore _store;

  /// 分片大小：每处理这么多首就让出一次事件循环。
  static const int chunkSize = 160;

  /// 单次查询默认返回的歌曲条数上限。
  static const int defaultLimit = 200;

  /// 歌手 / 专辑分区的条数上限。
  static const int defaultEntityLimit = 24;

  SearchIndex _index = SearchIndex.emptyIndex;

  /// 当前索引对应的「NAS + 账户」身份（多账户隔离，需求 §4）。
  String _identity = '';

  bool _building = false;
  int _built = 0;
  int _target = 0;
  bool _indexComplete = false;
  int _querySeq = 0;
  bool _disposed = false;

  /// 从磁盘缓存读回的检索键（按 guid）。
  Map<String, CachedSearchDoc> _cache = <String, CachedSearchDoc>{};
  bool _cacheLoaded = false;
  bool _cacheHit = false;

  // ── 排队的构建请求（合并 + 串行）──────────────────────────
  List<Track>? _pendingTracks;
  String? _pendingIdentity;
  bool _pendingComplete = false;
  bool _pendingForce = false;
  Future<void>? _runner;
  Future<void>? _persisting;

  // ── 只读状态 ──────────────────────────────────────────────

  SearchIndex get index => _index;

  /// 是否正在建索引（UI 可显示「正在更新曲库」）。
  bool get isBuilding => _building;

  /// 已建好的条数 / 目标条数。
  int get builtCount => _built;
  int get targetCount => _target;

  /// 索引是否覆盖全库（由曲库层判定后告知）。
  bool get indexComplete => _indexComplete;

  /// 索引里有多少首可搜。
  int get length => _index.length;

  /// 是否已经可以搜索（至少有一条）。
  bool get isReady => _index.length > 0;

  /// 本次启动是否用上了磁盘缓存。
  bool get restoredFromCache => _cacheHit;

  /// 等所有排队的构建**与落盘**结束（测试与诊断用）。
  ///
  /// ⚠️ 必须把落盘也等进来：落盘是 `unawaited` 的（不能拖慢搜索），
  /// 如果 `settled` 只等构建，紧接着 `dispose()` / 新建实例读缓存时
  /// 文件可能还没写完 —— 那是一种极难复现的时序性测试失败。
  Future<void> get settled async {
    final Future<void>? running = _runner;
    if (running != null) await running;
    final Future<void>? writing = _persisting;
    if (writing != null) await writing;
  }

  int get querySeq => _querySeq;

  /// 由曲库层告知「索引是否已覆盖全库」。
  ///
  /// 拆成独立方法而不是 [sync] 的参数，是因为「曲库拉全了」这件事
  /// 发生在分页过程中，而搜索索引的构建是异步的 —— 两者不同步。
  void markComplete(bool value) {
    if (_indexComplete == value) return;
    _indexComplete = value;
    _safeNotify();
  }

  // ── 构建 ─────────────────────────────────────────────────

  /// 请求（重新）构建索引。
  ///
  /// 可重入且**请求合并**：构建过程中的多次调用会合并成下一轮，
  /// 而不是排队跑 N 次（快速切页 / 多次曲库通知时非常常见）。
  Future<void> sync(
    List<Track> tracks, {
    String identity = '',
    bool complete = false,
    bool force = false,
  }) {
    _pendingTracks = tracks;
    _pendingIdentity = identity;
    _pendingComplete = complete;
    _pendingForce = _pendingForce || force;

    final Future<void>? running = _runner;
    if (running != null) return running;
    final Future<void> future = _run();
    _runner = future;
    return future;
  }

  /// **同步**整份构建（不 await、不分片）。
  ///
  /// 给「必须立刻拿到结果」的同步调用方用（例如曲库层保留的那个
  /// 同步 `search()` 兼容入口，以及测试）。它会复用内存里的缓存，
  /// 但**不会**去读磁盘 —— 磁盘缓存的读取是异步的。
  void ensureSync(
    List<Track> tracks, {
    String identity = '',
    bool complete = false,
  }) {
    if (!_needsRebuild(tracks, identity)) {
      _indexComplete = complete;
      return;
    }
    final _IndexBuilder b = _IndexBuilder(
      tracks: tracks,
      cache: _cache,
      force: false,
    );
    b.runToEnd();
    _adopt(b, identity, complete: complete);
    _persistIfDirty(b, identity);
  }

  Future<void> _run() async {
    try {
      while (_pendingTracks != null) {
        final List<Track> tracks = _pendingTracks!;
        final String identity = _pendingIdentity ?? '';
        final bool complete = _pendingComplete;
        final bool force = _pendingForce;
        _pendingTracks = null;
        _pendingForce = false;
        await _buildAsync(tracks, identity,
            complete: complete, force: force);
      }
    } catch (e, st) {
      // 建索引失败绝不能影响搜索的其它路径：保留上一份索引并如实记录。
      Log.e('SEARCH_INDEX 构建失败（保留上一份索引）', e, st);
      Diagnostics.event('搜索索引构建失败：$e');
    } finally {
      _building = false;
      _runner = null;
      _safeNotify();
    }
  }

  Future<void> _buildAsync(
    List<Track> tracks,
    String identity, {
    required bool complete,
    required bool force,
  }) async {
    if (_identity != identity) {
      // 换了 NAS / 账户：先清空上一份索引，避免串数据（需求 §4）。
      Log.i('SEARCH_INDEX 身份变更，清空索引缓存');
      _identity = identity;
      _index = SearchIndex.emptyIndex;
      _cache = <String, CachedSearchDoc>{};
      _cacheLoaded = false;
      _cacheHit = false;
      _target = 0;
      _built = 0;
    }

    if (!_cacheLoaded) {
      _cacheLoaded = true;
      try {
        final SearchIndexSnapshot? snap = await _store.load(identity);
        if (snap != null) {
          _cache = snap.docs;
          _cacheHit = true;
          Log.i('SEARCH_INDEX 命中磁盘缓存 ${snap.docs.length} 条检索键');
        }
      } catch (e) {
        // 缓存不可用只是冷启动，不是错误。
        Log.w('SEARCH_INDEX 读取拼音索引缓存失败（将重建）：$e');
      }
    }

    if (!force && !_needsRebuild(tracks, identity)) {
      _indexComplete = complete;
      _built = _index.length;
      _target = tracks.length;
      _safeNotify();
      return;
    }

    _building = true;
    _target = tracks.length;
    _built = 0;
    _safeNotify();

    final _IndexBuilder b = _IndexBuilder(
      tracks: tracks,
      cache: _cache,
      force: force,
    );
    while (!b.done) {
      final int end = b.i + chunkSize;
      while (!b.done && b.i < end) {
        b.step();
      }
      _built = b.i;
      _safeNotify();
      if (!b.done) {
        // 让出事件循环：这一行就是「不阻塞播放与遥控」的关键。
        await Future<void>.delayed(Duration.zero);
      }
    }

    _adopt(b, identity, complete: complete);
    _persistIfDirty(b, identity);
  }

  /// 索引与当前曲目列表是否已经对齐（长度 + 每个 guid 的指纹）。
  ///
  /// 用长度 + 首尾 + 抽样指纹做**廉价**判断：真正的逐条比对在建索引时做。
  /// 这里只是为了「什么都没变就别重建」，判断偏保守（宁可多建一次）。
  bool _needsRebuild(List<Track> tracks, String identity) {
    if (_identity != identity) return true;
    final List<SearchDoc> docs = _index.docs;
    if (docs.length != tracks.length) return true;
    if (tracks.isEmpty) return false;
    for (int i = 0; i < tracks.length; i++) {
      final SearchDoc d = docs[i];
      final Track t = tracks[i];
      if (d.track.guid != t.guid) return true;
      if (d.order != i) return true;
      final CachedSearchDoc? c = _cache[t.guid];
      if (c == null || c.fingerprint != fingerprintOf(t)) return true;
    }
    return false;
  }

  void _adopt(_IndexBuilder b, String identity, {required bool complete}) {
    _identity = identity;
    _index = b.finish();
    _cache = b.next;
    _indexComplete = complete;
    _built = _index.length;
    _target = b.tracks.length;
    _building = false;
    Log.i('SEARCH_INDEX 就绪：${_index.length} 首 · 复用 ${b.reused} 条 · '
        '重建 ${_index.length - b.reused} 条 · 完整=$complete');
    Diagnostics.note(
        '搜索索引',
        '${_index.length} 首可搜（复用缓存 ${b.reused} 条）· '
        '拼音库 v${PinyinService.version} · 归一化 v${TextNorm.version}');
    _safeNotify();
  }

  void _persistIfDirty(_IndexBuilder b, String identity) {
    if (!b.dirty && _cacheHit) return;
    final SearchIndexSnapshot snap = SearchIndexSnapshot(
      identity: identity,
      savedAt: DateTime.now(),
      trackCount: b.tracks.length,
      docs: b.next,
    );
    // 落盘失败只影响下次启动要重算，不该让本次搜索不可用 ——
    // 因此不 await；但把 Future 记下来，供 `settled` 等待。
    _persisting = _store.save(snap).catchError((Object e) {
      Log.w('SEARCH_INDEX 缓存落盘失败（内存索引仍可用）：$e');
    });
    _cacheHit = true;
  }

  // ── 查询 ─────────────────────────────────────────────────

  /// 执行一次查询。
  ///
  /// 返回的对象带序号；调用方拿 `outcome.seq` 与自己的最新序号比对，
  /// 或者直接用 `outcome.superseded` 判断是否该丢弃。
  Future<SearchOutcome> search(
    String raw, {
    int limit = defaultLimit,
    int entityLimit = defaultEntityLimit,
    bool allowFuzzy = true,
  }) async {
    final int seq = ++_querySeq;
    final String query = raw.trim();
    if (query.isEmpty) {
      return SearchOutcome(seq: seq, superseded: false, results: SearchResults.empty);
    }

    // 让出一次事件循环：保证「本次查询」与「在这期间发起的新查询」之间
    // 一定有机会交错 —— 这样序号才有意义，也让防抖后的连击输入
    // 不会把主线程连着占满。
    await Future<void>.delayed(Duration.zero);

    final SearchResults results = _index.query(
      query,
      limit: limit,
      entityLimit: entityLimit,
      indexComplete: _indexComplete,
      allowFuzzy: allowFuzzy,
    );
    final bool superseded = seq != _querySeq;
    if (superseded) {
      Log.i('SEARCH_QUERY 丢弃过期结果 seq=$seq 最新=$_querySeq');
    }
    return SearchOutcome(seq: seq, superseded: superseded, results: results);
  }

  /// **同步**查询（不 await、不带序号）。
  ///
  /// 给必须同步拿结果的调用方用（曲库层的兼容入口、手机遥控）。
  /// 需要防过期时请用 [search]。
  SearchResults querySync(
    String raw, {
    int limit = defaultLimit,
    int entityLimit = defaultEntityLimit,
    bool allowFuzzy = true,
  }) {
    final String query = raw.trim();
    if (query.isEmpty) return SearchResults.empty;
    return _index.query(
      query,
      limit: limit,
      entityLimit: entityLimit,
      indexComplete: _indexComplete,
      allowFuzzy: allowFuzzy,
    );
  }

  /// 清空（退出登录 / 切换账户时由装配层调用）。
  void reset() {
    _index = SearchIndex.emptyIndex;
    _cache = <String, CachedSearchDoc>{};
    _cacheLoaded = false;
    _cacheHit = false;
    _identity = '';
    _built = 0;
    _target = 0;
    _indexComplete = false;
    _pendingTracks = null;
    _pendingForce = false;
    _safeNotify();
  }

  // ── 指纹 ─────────────────────────────────────────────────

  /// 曲目的**变更指纹**：参与检索的三个字段 + 更新时间。
  ///
  /// 刻意存明文而不是哈希：几千条曲目下多出的百来 KB 完全可以接受，
  /// 换来的是**零碰撞**（哈希撞车会导致「改了名却搜不到新名字」，
  /// 而且几乎不可能复现）。指纹变了才重算该条的拼音。
  static String fingerprintOf(Track t) => '${t.title}\u0001'
      '${t.artistNames}\u0001'
      '${t.album.name}\u0001'
      '${t.updatedAt?.millisecondsSinceEpoch ?? 0}';

  // ── 生命周期 ──────────────────────────────────────────────

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

/// 逐条构建器 —— [SearchService] 的同步路径与分片异步路径**共用同一套逻辑**。
///
/// 抽出来的意义：两条路径如果各写一份，迟早会出现「异步路径修了、同步路径
/// 没修」的分叉（例如缓存复用条件），而这种分叉在测试里往往只覆盖一条路径。
class _IndexBuilder {
  _IndexBuilder({
    required this.tracks,
    required Map<String, CachedSearchDoc> cache,
    required this.force,
  }) : _cache = cache;

  final List<Track> tracks;
  final Map<String, CachedSearchDoc> _cache;
  final bool force;

  final List<SearchDoc> docs = <SearchDoc>[];
  final Map<String, CachedSearchDoc> next = <String, CachedSearchDoc>{};
  final Set<String> _seen = <String>{};

  int i = 0;
  int reused = 0;

  /// 是否有条目被重算（决定要不要落盘）。
  bool dirty = false;

  bool get done => i >= tracks.length;

  void runToEnd() {
    while (!done) {
      step();
    }
  }

  /// 处理第 [i] 首，然后 `i++`。
  void step() {
    final Track t = tracks[i];
    final int order = i;
    i++;

    if (t.guid.isEmpty) return; // 没有稳定标识的曲目无法建索引
    if (!_seen.add(t.guid)) return; // 同一首出现两次只索引一次

    final String fp = SearchService.fingerprintOf(t);
    final CachedSearchDoc? cached = force ? null : _cache[t.guid];

    SearchDoc? doc;
    if (cached != null && cached.fingerprint == fp) {
      doc = _fromCache(t, order, cached);
      if (doc != null) reused++;
    }
    if (doc == null) {
      doc = _build(t, order);
      dirty = true;
    }

    docs.add(doc);
    next[t.guid] = CachedSearchDoc(
      guid: t.guid,
      fingerprint: fp,
      titleSyllables: SearchIndexStore.encodeSyllables(doc.title.syllables),
      artistSyllables: SearchIndexStore.encodeSyllables(doc.artist.syllables),
      albumSyllables: SearchIndexStore.encodeSyllables(doc.album.syllables),
    );
  }

  SearchIndex finish() => SearchIndex(
        docs: docs,
        artistSeeds: _artistSeeds(),
        albumSeeds: _albumSeeds(),
      );

  static SearchDoc _build(Track t, int order) {
    PinyinService.ensureReady();
    return SearchDoc(
      track: t,
      order: order,
      title: PinyinService.align(TextNorm.key(t.title)),
      artist: PinyinService.align(TextNorm.key(t.artistNames)),
      album: PinyinService.align(TextNorm.key(t.album.name)),
      versionTags: TextNorm.versionTags(t.title),
    );
  }

  /// 用缓存里的音节表重建（不跑拼音转换 —— 这正是缓存的意义）。
  ///
  /// 音节个数与原文对不上（缓存损坏 / 规则漂移）时返回 null，
  /// 调用方会回落到完整重建，**绝不**用错误的对齐结果。
  static SearchDoc? _fromCache(Track t, int order, CachedSearchDoc c) {
    final AlignedText? title = _alignFromCache(c.titleSyllables, t.title);
    final AlignedText? artist = _alignFromCache(c.artistSyllables, t.artistNames);
    final AlignedText? album = _alignFromCache(c.albumSyllables, t.album.name);
    if (title == null || artist == null || album == null) return null;
    return SearchDoc(
      track: t,
      order: order,
      title: title,
      artist: artist,
      album: album,
      versionTags: TextNorm.versionTags(t.title),
    );
  }

  static AlignedText? _alignFromCache(String raw, String original) {
    final String key = TextNorm.key(original);
    if (key.isEmpty) {
      return raw.isEmpty ? AlignedText.empty : null;
    }
    final String text = PinyinService.alignedSource(key);
    return AlignedText.fromSyllables(
      text,
      SearchIndexStore.decodeSyllables(raw),
    );
  }

  // ── 实体池（歌手 / 专辑）───────────────────────────────────

  static const String unknownArtist = '未知歌手';
  static const String unknownAlbum = '未知专辑';

  List<EntityHit> _artistSeeds() {
    final Map<String, _Seed> map = <String, _Seed>{};
    for (final Track t in tracks) {
      if (t.artists.isEmpty) {
        map.putIfAbsent(
          unknownArtist,
          () => _Seed(key: 'a:$unknownArtist', name: unknownArtist, sample: t),
        ).count++;
        continue;
      }
      for (final ArtistRef a in t.artists) {
        final String name = a.name.trim();
        if (name.isEmpty) continue;
        final _Seed s = map.putIfAbsent(
          name,
          () => _Seed(key: 'a:$name', name: name, sample: t),
        );
        s.count++;
        s.coverId ??= a.coverId;
      }
    }
    return <EntityHit>[
      for (final _Seed s in map.values)
        EntityHit.seed(
          name: s.name,
          key: s.key,
          coverId: s.coverId,
          trackCount: s.count,
          sample: s.sample,
        ),
    ];
  }

  List<EntityHit> _albumSeeds() {
    final Map<String, _Seed> map = <String, _Seed>{};
    for (final Track t in tracks) {
      final String name = t.album.name.trim();
      // ⚠️ 只按专辑名分组会**误合并同名专辑**（不同歌手的同名专辑很常见）。
      //    曲库概览页用 `al:<guid>` + 名字兜底，这里保持一致口径。
      final String guid = t.album.guid.trim();
      final String fallbackArtist =
          t.artists.isEmpty ? '' : t.artists.first.name.trim();
      final String key = guid.isNotEmpty
          ? 'al:$guid'
          : (name.isNotEmpty ? 'al:#$name\u0000$fallbackArtist' : 'al:#$unknownAlbum');
      final _Seed s = map.putIfAbsent(
        key,
        () => _Seed(
          key: key,
          name: name.isEmpty ? unknownAlbum : name,
          sample: t,
        ),
      );
      s.count++;
      s.coverId ??= t.effectiveCoverId;
    }
    return <EntityHit>[
      for (final _Seed s in map.values)
        EntityHit.seed(
          name: s.name,
          key: s.key,
          coverId: s.coverId,
          trackCount: s.count,
          sample: s.sample,
        ),
    ];
  }
}

class _Seed {
  _Seed({required this.key, required this.name, required this.sample});

  final String key;
  final String name;
  final Track sample;
  String? coverId;
  int count = 0;
}
