import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../domain/track.dart';
import '../services/secure_store.dart';

/// 一个分组（歌手 / 专辑 / 风格）。
///
/// UI 上用「分组标题行 + 组内曲目行」的**单层列表**呈现，
/// 而不是「点进二级页」—— 电视遥控器上多一层跳转就多一次迷路的机会。
class TrackGroup {
  final String title;

  /// 副标题（如「12 首」）。
  final String subtitle;

  final List<Track> tracks;

  const TrackGroup({
    required this.title,
    required this.tracks,
    this.subtitle = '',
  });
}

/// 纯本地（不联网）的曲库视图仓储：最近播放、收藏、最近添加、分组。
///
/// ## 为什么这些不放在 `LibraryRepository`
/// [LibraryRepository] 的职责是「把服务端曲库分页拉全」，它已经够长了。
/// 这里只做**对已加载曲目的再组织**，数据源就是 `LibraryRepository.tracks`。
///
/// ## 为什么「最近播放」要自己记
/// 飞牛**没有播放历史接口**（`fnOS_API_真实契约.md` §9 路径表里没有
/// play-history），只能客户端记录。仅存 guid、上限 50 条、与凭据分开存。
///
/// ## 为什么「收藏」不自己记
/// `Track.isFavorite` 是服务端返回的字段，直接拿来用即可，
/// 本地再存一份必然与服务器不一致。
class LocalLibraryRepository extends ChangeNotifier {
  LocalLibraryRepository({SecureStore? store})
      : _store = store ?? SecureStore();

  final SecureStore _store;

  /// 最近播放的 guid，**新的在前**。
  final List<String> _recent = <String>[];

  List<String> get recentGuids => List<String>.unmodifiable(_recent);

  bool get hasRecent => _recent.isNotEmpty;

  /// 启动时恢复本机收听历史。**失败一律降级为空**，绝不影响启动。
  Future<void> restore() async {
    try {
      final list = await _store
          .readRecentGuids()
          .timeout(const Duration(seconds: 3));
      _recent
        ..clear()
        ..addAll(list.take(SecureStore.maxRecentTracks));
      if (_recent.isNotEmpty) {
        Log.i('LOCAL_RECENT 恢复 ${_recent.length} 条本机收听历史');
      }
      _safeNotify();
    } catch (e) {
      Log.w('LOCAL_RECENT 恢复失败（按空历史继续）：$e');
    }
  }

  /// 记录一次播放。
  ///
  /// 同一首重复触发（进度刷新会反复回调）直接短路，避免无谓的重排与写盘。
  void recordPlayed(String guid) {
    if (guid.isEmpty) return;
    if (_recent.isNotEmpty && _recent.first == guid) return;
    _recent.remove(guid);
    _recent.insert(0, guid);
    if (_recent.length > SecureStore.maxRecentTracks) {
      _recent.removeRange(SecureStore.maxRecentTracks, _recent.length);
    }
    _safeNotify();
    // 落盘失败不影响播放（历史只是锦上添花）。
    unawaited(_store.writeRecentGuids(_recent).catchError((Object e) {
      Log.w('LOCAL_RECENT 保存失败（忽略）：$e');
    }));
  }

  /// 把最近播放的 guid 还原成曲目。已从曲库删除的自动跳过。
  List<Track> recentTracks(List<Track> catalogue) {
    if (_recent.isEmpty || catalogue.isEmpty) return const <Track>[];
    final byGuid = <String, Track>{for (final t in catalogue) t.guid: t};
    final out = <Track>[];
    for (final g in _recent) {
      final t = byGuid[g];
      if (t != null) out.add(t);
    }
    return List<Track>.unmodifiable(out);
  }

  // ── 纯函数视图（无状态，方便单测）──────────────────────────

  /// 收藏：直接用服务端下发的 `isFavorite`。
  static List<Track> favorites(List<Track> catalogue) => List<Track>.unmodifiable(
        catalogue.where((t) => t.isFavorite),
      );

  /// 最近添加：按 `createdAt` 倒序（未知时间的排在最后）。
  ///
  /// ⚠️ `Track.createdAt` 单位是 **Unix 秒**（契约 §5.1），已由 domain 层转成
  /// [DateTime]，这里只做排序，不做单位换算。
  static List<Track> recentlyAdded(
    List<Track> catalogue, {
    int limit = 100,
  }) {
    final sorted = List<Track>.of(catalogue);
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

  /// 按歌手分组（取第一位歌手；无歌手归入「未知歌手」）。
  static List<TrackGroup> groupByArtist(List<Track> catalogue) {
    const String unknown = '未知歌手';
    final map = <String, List<Track>>{};
    for (final t in catalogue) {
      final name = t.artists.isNotEmpty && t.artists.first.name.isNotEmpty
          ? t.artists.first.name
          : unknown;
      (map[name] ??= <Track>[]).add(t);
    }
    return _toGroups(map);
  }

  /// 按专辑分组（无专辑名归入「未知专辑」）。
  static List<TrackGroup> groupByAlbum(List<Track> catalogue) {
    const String unknown = '未知专辑';
    final map = <String, List<Track>>{};
    for (final t in catalogue) {
      final name = t.album.name.isNotEmpty ? t.album.name : unknown;
      (map[name] ??= <Track>[]).add(t);
    }
    return _toGroups(map);
  }

  /// 按风格分组。一首歌可属于多个风格，因此**会出现在多个分组里**。
  ///
  /// ⚠️ 实测样本里 `genres` 是空数组。曲库完全没有风格标签时返回空列表，
  /// UI 必须如实显示「曲库没有风格标签」，不能假装有数据。
  static List<TrackGroup> groupByGenre(List<Track> catalogue) {
    final map = <String, List<Track>>{};
    for (final t in catalogue) {
      for (final g in t.genres) {
        final name = g.trim();
        if (name.isEmpty) continue;
        (map[name] ??= <Track>[]).add(t);
      }
    }
    return _toGroups(map);
  }

  static List<TrackGroup> _toGroups(Map<String, List<Track>> map) {
    final keys = map.keys.toList()
      ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return List<TrackGroup>.unmodifiable(<TrackGroup>[
      for (final k in keys)
        TrackGroup(
          title: k,
          subtitle: '${map[k]!.length} 首',
          tracks: List<Track>.unmodifiable(map[k]!),
        ),
    ]);
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
