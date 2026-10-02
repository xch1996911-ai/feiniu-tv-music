import 'json_util.dart';

/// 歌手。
///
/// 字段集来自真实 NAS 实测（`fnOS_API_真实契约.md` §5.3）：
/// `['guid','name','coverId','createdAt','updatedAt','trackCount','albumCount']`
///
/// 注意 `artist/list-all` 返回的字段更少（仅 `guid` / `name` / `coverId` / 时间戳），
/// 是给下拉选择用的轻量形态；两者都能被本模型解析。
class Artist {
  final String guid;
  final String name;

  /// 含前缀的完整封面 ID，如 `artist_<32hex>`。
  final String? coverId;

  /// Unix 秒。
  final DateTime? createdAt;

  /// Unix 秒。
  final DateTime? updatedAt;

  final int trackCount;
  final int albumCount;

  const Artist({
    required this.guid,
    required this.name,
    this.coverId,
    this.createdAt,
    this.updatedAt,
    this.trackCount = 0,
    this.albumCount = 0,
  });

  factory Artist.fromJson(Map<String, dynamic> json) {
    return Artist(
      guid: jsonString(json['guid']),
      name: jsonString(json['name']),
      coverId: jsonStringOrNull(json['coverId']),
      createdAt: jsonUnixSeconds(json['createdAt']),
      updatedAt: jsonUnixSeconds(json['updatedAt']),
      trackCount: jsonInt(json['trackCount']),
      albumCount: jsonInt(json['albumCount']),
    );
  }
}

/// 曲目内嵌的歌手引用（轻量）。
///
/// ⚠️ Phase 1 早期把曲目歌手建模成 `artistNames: String`，与真实结构不符：
/// 真实字段是 `artists: [{guid, name, coverId, createdAt, updatedAt}]`。
class ArtistRef {
  final String guid;
  final String name;
  final String? coverId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const ArtistRef({
    required this.guid,
    required this.name,
    this.coverId,
    this.createdAt,
    this.updatedAt,
  });

  factory ArtistRef.fromJson(Map<String, dynamic> json) {
    return ArtistRef(
      guid: jsonString(json['guid']),
      name: jsonString(json['name']),
      coverId: jsonStringOrNull(json['coverId']),
      createdAt: jsonUnixSeconds(json['createdAt']),
      updatedAt: jsonUnixSeconds(json['updatedAt']),
    );
  }

  /// 解析 `artists` 数组；非 List / 含非 Map 元素时安全跳过。
  static List<ArtistRef> listFromJson(dynamic raw) {
    if (raw is! List) return const <ArtistRef>[];
    return raw
        .whereType<Map>()
        .map((e) => ArtistRef.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}
