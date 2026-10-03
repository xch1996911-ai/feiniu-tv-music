import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diagnostics.dart';
import '../core/log.dart';
import '../domain/genre.dart';
import '../domain/genre_inferencer.dart';
import '../domain/player_layout.dart';
import '../domain/track.dart';
import '../services/catalogue_store.dart';
import '../services/secure_store.dart';

/// 一份「概览」条目（歌手 / 专辑 / 风格各一条）。
///
/// 这是**概览 → 详情**两级浏览里第一级的数据形态：
/// 概览页只画 [trackCount] / [albumCount] 这类统计，不展开曲目；
/// 用户点进去才用 [tracks] 建详情页。
///
/// ## 统计口径（全部由仓储层算，UI 不做任何拼凑）
/// - 同一首歌在同一个分组里**只计一次**（分页合并可能带来重复 guid）；
/// - 「歌手」计入**全部**演唱者（合唱曲目会同时出现在两位歌手名下），
///   因此各歌手歌曲数之和**可能大于曲库总数** —— 这是正确行为；
/// - 「专辑」一首歌只属一张（`album.guid` 优先，缺失时退回专辑名）；
/// - 「风格」一首歌可属多个，同上。
class LibraryOverview {
  /// 稳定标识：`a:<guid>` / `al:<name>` / `g:<name>`。
  ///
  /// 详情页返回时靠它定位原来的位置（而不是靠显示名 —— 重名会串位）。
  final String key;

  /// 显示名（歌手名 / 专辑名 / 风格名）。
  final String title;

  /// 副标题（专辑概览用来显示歌手名；其余为空）。
  final String? subtitle;

  /// 概览用的封面（`coverId`，含前缀）。
  final String? coverId;

  /// 该条目下的歌曲数。
  final int trackCount;

  /// 该条目涉及的**去重专辑数**（歌手概览用；其余为 0）。
  final int albumCount;

/// 该条目下的曲目（曲库原顺序），供详情页建队列。
  final List<Track> tracks;

  /// 该条目的风格是否**全部来自推断**（而非服务端标签或用户手动确认）。
  ///
  /// 概览页据此显示「推断」标识 —— 需求 §三.4：
  /// 「风格概览可显示『推断』标识，避免把推断当作原始标签」。
  final bool inferred;

  const LibraryOverview({
    required this.key,
    required this.title,
    required this.trackCount,
    required this.tracks,
    this.subtitle,
    this.coverId,
    this.albumCount = 0,
    this.inferred = false,
  });
}

/// 本机状态仓储：**最近播放 / 收藏 / 界面偏好**，以及**曲库的概览视图**。
///
/// ## 为什么这些不放在 `LibraryRepository`
/// [LibraryRepository] 的职责是「把服务端曲库分页拉全」，它已经够长了。
/// 这里只做**对已加载曲目的再组织**，数据源就是 `LibraryRepository.tracks`。
///
/// ## 为什么「最近播放」要自己记
/// 飞牛**没有播放历史接口**（`fnOS_API_真实契约.md` §9 路径表里没有
/// play-history），只能客户端记录。仅存 guid、上限 50 条、与凭据分开存。
///
/// ## 为什么「收藏」也要自己记
/// 服务端只有**只读**的 `Track.isFavorite`，**没有加/取消收藏的写接口**
/// （详见 [SecureStore] 里收藏区的说明）。需求要求「按下立即更新并持久保存」，
/// 所以用本机集合作为**唯一**数据源，并在首次把服务端值**播种**进来一次。
class LocalLibraryRepository extends ChangeNotifier {
  LocalLibraryRepository({SecureStore? store, CatalogueStore? catalogue})
      : _store = store ?? SecureStore(),
        _catalogue = catalogue ?? CatalogueStore();

  final SecureStore _store;

  /// 用户手动风格用**文件**存（非敏感、可能较长），与曲库索引**分离**：
  /// 重建索引整份替换 `catalogue_*.json`，但永远不碰 `genre_overrides.json`
  /// （需求 §三-B.7：刷新/重建索引不能无故重置用户记忆）。
  final CatalogueStore _catalogue;

  // ── 用户手动风格（最高优先级）────────────────────────────

  final Map<String, List<String>> _genreOverrides = <String, List<String>>{};

  /// 曲目标识 → 用户手动确认的风格。**只读**视图。
  Map<String, List<String>> get genreOverrides =>
      Map<String, List<String>>.unmodifiable(_genreOverrides);

  bool get hasGenreOverrides => _genreOverrides.isNotEmpty;

  /// 某首歌的用户手动风格（空表示未手动指定）。
  List<String> trackedGenres(String guid) =>
      List<String>.unmodifiable(_genreOverrides[guid] ?? const <String>[]);

  /// 用户改过风格后触发曲库层重算（由装配层注入）。
  VoidCallback? onGenreOverrideChanged;

  /// 设置/清除某首歌的手动风格。
  ///
  /// 传空列表 = 取消手动指定（之后回落到自动归纳结果）。
  /// 手动结果**永远优先**，自动归纳不会覆盖它（见 [GenreSource.rank]）。
  Future<void> setTrackGenres(String guid, List<String> genres) async {
    if (guid.isEmpty) return;
    final List<String> cleaned = <String>[
      for (final String g in genres)
        if (g.trim().isNotEmpty) g.trim(),
    ];
    if (cleaned.isEmpty) {
      _genreOverrides.remove(guid);
    } else {
      _genreOverrides[guid] = cleaned;
    }
    Log.i('GENRE_OVERRIDE guid=$guid → '
        '${cleaned.isEmpty ? '(取消手动)' : cleaned.join('/')}');
    Diagnostics.note('风格手动确认', '已累计 ${_genreOverrides.length} 首');
    _safeNotify();
    onGenreOverrideChanged?.call();
    try {
      await _catalogue.saveOverrides(_genreOverrides);
    } catch (e) {
      Log.w('GENRE_OVERRIDE 保存失败（内存已生效，重启后会丢失）：$e');
    }
  }

  // ── 最近播放 ──────────────────────────────────────────────

  /// 最近播放的 guid，**新的在前**（数组顺序就是时间倒序）。
  final List<String> _recent = <String>[];

  List<String> get recentGuids => List<String>.unmodifiable(_recent);

  bool get hasRecent => _recent.isNotEmpty;

  // ── 收藏 ──────────────────────────────────────────────────

  /// 本机收藏的 guid。**UI 只认这一份**。
  final Set<String> _favorites = <String>{};

  /// 是否已用服务端 `isFavorite` 播种过。
  bool _favoritesSeeded = false;

  bool get favoritesSeeded => _favoritesSeeded;

  int get favoriteCount => _favorites.length;

  bool isFavorite(String guid) => guid.isNotEmpty && _favorites.contains(guid);

  // ── 界面偏好 ──────────────────────────────────────────────

  PlayerLayout _playerLayout = PlayerLayout.stage;

  PlayerLayout get playerLayout => _playerLayout;

  // ── 生命周期 ──────────────────────────────────────────────

  /// 启动时恢复本机状态。**失败一律降级为空**，绝不影响启动。
  Future<void> restore() async {
    try {
      final results = await Future.wait<Object?>(<Future<Object?>>[
        _store.readRecentGuids(),
        _store.readFavoriteGuids(),
        _store.readFavoritesSeeded(),
        _store.readPlayerLayoutKey(),
        _catalogue.loadOverrides(),
      ]).timeout(const Duration(seconds: 4));

      _recent
        ..clear()
        ..addAll((results[0] as List<String>).take(SecureStore.maxRecentTracks));

      _favorites
        ..clear()
        ..addAll(results[1] as List<String>);

      _favoritesSeeded = results[2] as bool;
      _playerLayout = PlayerLayout.fromStorage(results[3] as String?);

      _genreOverrides
        ..clear()
        ..addAll(results[4] as Map<String, List<String>>);

      Log.i('LOCAL_RESTORE 最近 ${_recent.length} 条 · 收藏 ${_favorites.length} 首 · '
          '播种=${_favoritesSeeded ? '是' : '否'} · 播放页=${_playerLayout.storageKey} · '
          '手动风格 ${_genreOverrides.length} 首');
      if (_genreOverrides.isNotEmpty) {
        Diagnostics.note('风格手动确认', '已恢复 ${_genreOverrides.length} 首用户指定风格');
      }
      _safeNotify();
    } catch (e) {
      Log.w('LOCAL_RESTORE 恢复失败（按空状态继续）：$e');
    }
  }

  /// 记录一次播放。
  ///
  /// 同一首重复触发（进度刷新会反复回调）直接短路，避免无谓的重排与写盘；
  /// 重复播放会把它**移到最前**（不是追加），因此不会无限堆叠。
  void recordPlayed(String guid) {
    if (guid.isEmpty) return;
    if (_recent.isNotEmpty && _recent.first == guid) return;
    _recent.remove(guid);
    _recent.insert(0, guid);
    if (_recent.length > SecureStore.maxRecentTracks) {
      _recent.removeRange(SecureStore.maxRecentTracks, _recent.length);
    }
    _safeNotify();
    unawaited(_store.writeRecentGuids(_recent).catchError((Object e) {
      Log.w('LOCAL_RECENT 保存失败（忽略）：$e');
    }));
  }

  /// 把最近播放的 guid 还原成曲目。已从曲库删除的自动跳过。
  ///
  /// 顺序 = `_recent` 的顺序 = **最近播放时间倒序**。
  List<Track> recentTracks(List<Track> catalogue) {
    if (_recent.isEmpty || catalogue.isEmpty) return const <Track>[];
    final byGuid = <String, Track>{for (final t in catalogue) t.guid: t};
    final out = <Track>[];
    final seen = <String>{};
    for (final g in _recent) {
      final t = byGuid[g];
      if (t != null && seen.add(g)) out.add(t);
    }
    return List<Track>.unmodifiable(out);
  }

  // ── 收藏写操作 ────────────────────────────────────────────

  /// 切换收藏状态。返回切换**之后**是否已收藏。
  ///
  /// 界面立即更新（先改内存再落盘），落盘失败只记日志 ——
  /// 收藏写盘失败不该阻断用户操作。
  Future<bool> toggleFavorite(String guid) async {
    if (guid.isEmpty) return false;
    final bool nowFavorite;
    if (_favorites.contains(guid)) {
      _favorites.remove(guid);
      nowFavorite = false;
    } else {
      _favorites.add(guid);
      nowFavorite = true;
    }
    _safeNotify();
    Log.i('FAVORITE ${nowFavorite ? '收藏' : '取消收藏'} guid=$guid '
        '（共 ${_favorites.length} 首）');
    try {
      await _store.writeFavoriteGuids(_favorites.toList(growable: false));
    } catch (e) {
      Log.w('FAVORITE 保存失败（内存已更新，重启后会丢失）：$e');
    }
    return nowFavorite;
  }

  /// 首次把服务端 `isFavorite` 播种到本机集合。
  ///
  /// 只在**从未播种过**时执行一次，且只在曲库确实加载出内容时执行
  /// （否则会把「还没加载完的空曲库」误判成「服务端没有收藏」并置上标记）。
  ///
  /// 播种后本机集合即为唯一数据源；用户此后在 TV 端的增删都不会再被覆盖。
  Future<void> seedFavoritesIfNeeded(List<Track> catalogue) async {
    if (_favoritesSeeded || catalogue.isEmpty) return;
    final fromServer = <String>{
      for (final Track t in catalogue)
        if (t.isFavorite && t.guid.isNotEmpty) t.guid,
    };
    _favoritesSeeded = true;
    _favorites.addAll(fromServer);
    _safeNotify();
    Log.i('FAVORITE 首次播种：从服务端 isFavorite 导入 ${fromServer.length} 首');
    try {
      await _store.writeFavoriteGuids(_favorites.toList(growable: false));
      await _store.writeFavoritesSeeded(true);
    } catch (e) {
      Log.w('FAVORITE 播种落盘失败（内存已生效）：$e');
    }
  }

  /// 收藏曲目（按曲库顺序）。
  ///
  /// ⚠️ **不使用** `Track.isFavorite` —— 那只是播种时的初始来源，
  /// 之后本机集合才是唯一依据（服务端没有写接口，无法回写）。
  List<Track> favoriteTracks(List<Track> catalogue) => List<Track>.unmodifiable(
        catalogue.where((Track t) => t.guid.isNotEmpty && _favorites.contains(t.guid)),
      );

  // ── 界面偏好写操作 ────────────────────────────────────────

  Future<void> setPlayerLayout(PlayerLayout value) async {
    if (_playerLayout == value) return;
    _playerLayout = value;
    _safeNotify();
    Log.i('UI 播放页布局切换为 ${value.storageKey}');
    try {
      await _store.writePlayerLayoutKey(value.storageKey);
    } catch (e) {
      Log.w('UI 播放页布局保存失败（内存已生效）：$e');
    }
  }

  // ── 纯函数视图（无状态，方便单测）──────────────────────────

  /// 最近添加：按 `createdAt` 倒序（未知时间的排在最后）。
  ///
  /// ⚠️ `Track.createdAt` 单位是 **Unix 秒**（契约 §5.1），已由 domain 层转成
  /// [DateTime]，这里只做排序，不做单位换算。
  ///
  /// 与「最近播放」是**两个不同的概念**：这里按**入库时间**，那里按**播放时间**。
  static List<Track> recentlyAdded(
    List<Track> catalogue, {
    int limit = 300,
  }) {
    final seen = <String>{};
    final sorted = <Track>[];
    for (final Track t in catalogue) {
      final String dedup = t.guid.isNotEmpty ? t.guid : '${t.title}\u0000${t.artistNames}';
      if (seen.add(dedup)) sorted.add(t);
    }
    sorted.sort((Track a, Track b) {
      final DateTime? ta = a.createdAt;
      final DateTime? tb = b.createdAt;
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1; // 无时间的沉底
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    return List<Track>.unmodifiable(sorted.take(limit));
  }

  // ── 概览（纯静态，便于单测）────────────────────────────────

  /// 无歌手 / 无专辑名时的兜底分类名。
  static const String unknownArtist = '未知歌手';
  static const String unknownAlbum = '未知专辑';

  /// 歌手概览。
  ///
  /// - 计入 **全部** `artists`（合唱曲目同时出现在每位歌手名下）；
  /// - `artists` 为空 → 归入「未知歌手」（唯一兜底分类，不会凭空造歌手）；
  /// - `albumCount` = 该歌手曲目涉及的**去重专辑数**。
  ///
  /// 排序：歌曲数降序 → 同名时按名称升序（保证顺序稳定、可复现）。
  static List<LibraryOverview> artistOverviews(List<Track> catalogue) {
    final buckets = <String, _Bucket>{};
    for (final Track t in catalogue) {
      if (t.artists.isEmpty) {
        _bucketFor(buckets, 'a:#$unknownArtist', unknownArtist).add(t);
        continue;
      }
      for (final artist in t.artists) {
        final String name = artist.name.trim();
        final String guid = artist.guid.trim();
        if (name.isEmpty && guid.isEmpty) continue; // 空值跳过，不造「未知」
        final String key = guid.isNotEmpty ? 'a:$guid' : 'a:#$name';
        final _Bucket b =
            _bucketFor(buckets, key, name.isEmpty ? unknownArtist : name);
        // 歌手头像优先于曲目封面（`artist.<coverId>` 是歌手专用图）
        b.setCoverIfEmpty(artist.coverId);
        b.add(t);
      }
    }
    return _finish(buckets, withAlbums: true);
  }

  /// 专辑概览：每项显示封面、专辑名、歌手、歌曲数。
  static List<LibraryOverview> albumOverviews(List<Track> catalogue) {
    final buckets = <String, _Bucket>{};
    for (final Track t in catalogue) {
      final String name = t.album.name.trim();
      final String guid = t.album.guid.trim();
      // ⚠️ V5 修复：只用「专辑名」当分组键是不够的。
      //    不同歌手的同名专辑（《精选集》《Best》《Live》…）会被合并成一张，
      //    表现为「某张专辑歌曲数莫名很多、歌手名只显示第一位」。
      //    契约 §5.1 里 `track.album.guid` 是存在的，正常都能拿到；
      //    拿不到时用「专辑名 + 首位歌手」兜底 —— 比只用专辑名安全得多。
      final String fallbackArtist =
          t.artists.isEmpty ? '' : t.artists.first.name.trim();
      final String key = guid.isNotEmpty
          ? 'al:$guid'
          : (name.isNotEmpty
              ? 'al:#$name\u0000$fallbackArtist'
              : 'al:#$unknownAlbum');
      final _Bucket b = _bucketFor(
        buckets,
        key,
        name.isEmpty ? unknownAlbum : name,
      );
      // 专辑封面优先用专辑自身的 coverId
      b.setCoverIfEmpty(t.album.coverId);
      b.add(t);
      // 专辑的副标题 = 首位歌手名（图三：专辑名下方显示歌手）
      b.subtitle ??=
          t.artistNames.isEmpty ? unknownArtist : t.artists.first.name;
    }
    final List<LibraryOverview> out = _finish(buckets, withAlbums: false);
    // 专辑按名称升序更利于查找（图三是网格，顺序无关）
    final List<LibraryOverview> sorted = List<LibraryOverview>.of(out)
      ..sort((LibraryOverview a, LibraryOverview b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return List<LibraryOverview>.unmodifiable(sorted);
  }

  /// 风格概览：**服务端标签 + 自动归纳 + 待分类**。
  ///
  /// ⚠️ V5 变化（需求 §三）：
  /// - V4 只读 `Track.genres`。实测曲库的 `genres` **全是空数组**，
  ///   于是风格页永远只有一个「暂无风格标签」空态 —— 功能等于不存在；
  /// - 现在以 [GenreInferencer] 的归纳结果为数据源：有结论的按风格分组，
  ///   **证据不足的进「待分类」**，而不是伪造成「流行」或「未知风格」。
  ///
  /// [inference] 为 null 时退回「只认服务端标签」的旧口径，
  /// 保证调用方没接线时也不会崩。
  ///
  /// 一个关键点：**「待分类」也要带真实曲目列表** ——
  /// 用户点进去要能看到「哪些歌还没分类」并手动指定。
  /// 只显示一个数字而不给曲目，等于没有可操作性。
  List<LibraryOverview> genreOverviewsOf(
    List<Track> catalogue, {
    GenreInferenceResult? inference,
  }) {
    final GenreInferenceResult? inf = inference;
    if (inf == null) {
      return explicitGenreOverviews(catalogue);
    }

    final Map<String, _Bucket> buckets = <String, _Bucket>{};
    final _Bucket pending =
        _Bucket(key: 'g:#${GenreRules.unclassified}', title: GenreRules.unclassified);

    // 标识 → Track，便于按归纳结果回填曲目。
    final Map<String, Track> byKey = <String, Track>{};
    for (final Track t in catalogue) {
      final String key =
          t.guid.isNotEmpty ? t.guid : '${t.title}\u0000${t.artistNames}';
      byKey.putIfAbsent(key, () => t);
    }

    for (final MapEntry<String, List<GenreAssignment>> e in inf.byGuid.entries) {
      final Track? t = byKey[e.key];
      if (t == null) continue; // 索引里的曲目已不在当前曲库
      for (final GenreAssignment a in e.value) {
        final _Bucket b = _bucketFor(buckets, 'g:#${a.genre}', a.genre);
        b.setCoverIfEmpty(t.effectiveCoverId);
        b.add(t);
      }
    }

    // 归纳没给出结论的 → 待分类
    for (final MapEntry<String, Track> e in byKey.entries) {
      if (inf.byGuid.containsKey(e.key)) continue;
      pending.setCoverIfEmpty(e.value.effectiveCoverId);
      pending.add(e.value);
    }

    final List<LibraryOverview> out = <LibraryOverview>[
      for (final _Bucket b in buckets.values)
        LibraryOverview(
          key: b.key,
          title: b.title,
          coverId: b.coverId,
          trackCount: b.tracks.length,
          tracks: List<Track>.unmodifiable(b.tracks),
          inferred: inf.isGenreFullyInferred(b.title),
        ),
      if (pending.tracks.isNotEmpty)
        LibraryOverview(
          key: pending.key,
          title: pending.title,
          coverId: pending.coverId,
          trackCount: pending.tracks.length,
          tracks: List<Track>.unmodifiable(pending.tracks),
        ),
    ];

    // 排序：曲目多的在前；统一集合内按声明顺序；「待分类」永远沉底。
    final List<String> order = GenreRules.unified;
    out.sort((LibraryOverview a, LibraryOverview b) {
      final bool ap = a.title == GenreRules.unclassified;
      final bool bp = b.title == GenreRules.unclassified;
      if (ap != bp) return ap ? 1 : -1;
      final int c = b.trackCount.compareTo(a.trackCount);
      if (c != 0) return c;
      final int ia = order.indexOf(a.title);
      final int ib = order.indexOf(b.title);
      if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
      if (ia >= 0) return -1;
      if (ib >= 0) return 1;
      return a.title.compareTo(b.title);
    });
    return List<LibraryOverview>.unmodifiable(out);
  }

  /// 「只认服务端标签」的旧口径（V4 行为），保留给未接线的调用方与测试。
  static List<LibraryOverview> explicitGenreOverviews(List<Track> catalogue) {
    final buckets = <String, _Bucket>{};
    for (final Track t in catalogue) {
      for (final String g in t.genres) {
        final String name = g.trim();
        if (name.isEmpty) continue; // 空白串忽略
        _bucketFor(buckets, 'g:#$name', name).add(t);
      }
    }
    return _finish(buckets, withAlbums: false);
  }

  static _Bucket _bucketFor(
    Map<String, _Bucket> buckets,
    String key,
    String title,
  ) =>
      buckets.putIfAbsent(key, () => _Bucket(key: key, title: title));

  static List<LibraryOverview> _finish(
    Map<String, _Bucket> buckets, {
    required bool withAlbums,
  }) {
    final List<LibraryOverview> out = <LibraryOverview>[
      for (final _Bucket b in buckets.values)
        LibraryOverview(
          key: b.key,
          title: b.title,
          subtitle: b.subtitle,
          coverId: b.coverId,
          trackCount: b.tracks.length,
          albumCount: withAlbums ? b.albums.length : 0,
          tracks: List<Track>.unmodifiable(b.tracks),
        ),
    ];
    out.sort((LibraryOverview a, LibraryOverview b) {
      if (withAlbums) {
        final int c = b.trackCount.compareTo(a.trackCount);
        if (c != 0) return c;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return List<LibraryOverview>.unmodifiable(out);
  }

  // ── 生命周期工具 ──────────────────────────────────────────

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

/// 分组累加器。
class _Bucket {
  final String key;
  final String title;
  String? subtitle;

  /// 已计入的曲目标识，用于**去重**（同一首歌只算一次）。
  final Set<String> _seen = <String>{};

  final List<Track> tracks = <Track>[];

  /// 该分组涉及的专辑标识（去重）。
  final Set<String> albums = <String>{};

  String? coverId;

  _Bucket({required this.key, required this.title});

  /// 仅在还没有封面时采用传入的 coverId。
  ///
  /// 调用方在 [add] **之前**调用它，就能让「歌手头像 / 专辑封面」
  /// 优先于「曲目封面」——[add] 里的兜底只在仍为空时生效。
  void setCoverIfEmpty(String? id) {
    if (coverId != null && coverId!.isNotEmpty) return;
    if (id == null || id.isEmpty) return;
    coverId = id;
  }

  void add(Track t) {
    final String dedup = t.guid.isNotEmpty
        ? t.guid
        : '${t.title}\u0000${t.artistNames}';
    if (!_seen.add(dedup)) return;

    tracks.add(t);

    if (coverId == null || coverId!.isEmpty) {
      final String? c = t.effectiveCoverId;
      if (c != null && c.isNotEmpty) coverId = c;
    }

    // 专辑标识：guid 优先，缺失退回名字；两者都没有则不计入
    final String albumGuid = t.album.guid.trim();
    final String albumName = t.album.name.trim();
    if (albumGuid.isNotEmpty) {
      albums.add('al:$albumGuid');
    } else if (albumName.isNotEmpty) {
      albums.add('al:#$albumName');
    }
  }
}
