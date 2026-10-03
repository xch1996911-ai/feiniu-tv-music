import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../domain/player_layout.dart';
import '../domain/track.dart';
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

  const LibraryOverview({
    required this.key,
    required this.title,
    required this.trackCount,
    required this.tracks,
    this.subtitle,
    this.coverId,
    this.albumCount = 0,
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
  LocalLibraryRepository({SecureStore? store})
      : _store = store ?? SecureStore();

  final SecureStore _store;

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
      ]).timeout(const Duration(seconds: 3));

      _recent
        ..clear()
        ..addAll((results[0] as List<String>).take(SecureStore.maxRecentTracks));

      _favorites
        ..clear()
        ..addAll(results[1] as List<String>);

      _favoritesSeeded = results[2] as bool;
      _playerLayout = PlayerLayout.fromStorage(results[3] as String?);

      Log.i('LOCAL_RESTORE 最近 ${_recent.length} 条 · 收藏 ${_favorites.length} 首 · '
          '播种=${_favoritesSeeded ? '是' : '否'} · 播放页=${_playerLayout.storageKey}');
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
      final String key = guid.isNotEmpty
          ? 'al:$guid'
          : (name.isNotEmpty ? 'al:#$name' : 'al:#$unknownAlbum');
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

  /// 风格概览。
  ///
  /// ⚠️ 实测样本里 `genres` 是空数组。曲库完全没有风格标签时返回**空列表**，
  /// UI 必须如实显示「暂无风格标签」——
  /// **绝不能**把全部歌曲归进一个「未知风格」分类来假装有数据。
  static List<LibraryOverview> genreOverviews(List<Track> catalogue) {
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
