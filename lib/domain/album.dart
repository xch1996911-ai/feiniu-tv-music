import 'artist.dart';
import 'json_util.dart';

/// 专辑。
///
/// 字段集来自真实 NAS 实测（`fnOS_API_真实契约.md` §5.2）：
/// `['guid','name','coverId','releaseDate','barcode','createdAt','updatedAt','artists','trackCount']`
///
/// ⚠️ 与 Phase 1 早期推测的差异：**没有** `originalReleaseYear`，
/// 真实年份字段是 `releaseDate`（字符串，如 `"2002"`）。
class Album {
  final String guid;
  final String name;

  /// 含前缀的完整封面 ID，如 `album_<32hex>`。
  final String? coverId;

  /// 发行日期。实测为**字符串**，可能只有年份（`"2002"`）或完整日期。
  final String? releaseDate;

  /// 条码（前端用于匹配元数据源），非必填。
  final String? barcode;

  /// Unix 秒。
  final DateTime? createdAt;

  /// Unix 秒。
  final DateTime? updatedAt;

  /// 专辑关联的歌手（实测 `album/list` 会返回，`track.album` 内嵌对象不返回）。
  final List<ArtistRef> artists;

  final int trackCount;

  const Album({
    required this.guid,
    required this.name,
    this.coverId,
    this.releaseDate,
    this.barcode,
    this.createdAt,
    this.updatedAt,
    this.artists = const <ArtistRef>[],
    this.trackCount = 0,
  });

  /// 年份（从 [releaseDate] 前 4 位提取，取不到返回 null）。
  int? get releaseYear {
    final d = releaseDate;
    if (d == null || d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }

  /// 从飞牛音乐 `album/list` / `album/detail` 响应的 data 项解析。
  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      guid: jsonString(json['guid']),
      name: jsonString(json['name']),
      coverId: jsonStringOrNull(json['coverId']),
      releaseDate: jsonStringOrNull(json['releaseDate']),
      barcode: jsonStringOrNull(json['barcode']),
      createdAt: jsonUnixSeconds(json['createdAt']),
      updatedAt: jsonUnixSeconds(json['updatedAt']),
      artists: ArtistRef.listFromJson(json['artists']),
      trackCount: jsonInt(json['trackCount']),
    );
  }
}

/// 曲目内嵌的专辑引用（轻量，无 trackCount / artists）。
class AlbumRef {
  final String guid;
  final String name;
  final String? coverId;
  final String? releaseDate;
  final String? barcode;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const AlbumRef({
    required this.guid,
    required this.name,
    this.coverId,
    this.releaseDate,
    this.barcode,
    this.createdAt,
    this.updatedAt,
  });

  /// 空引用（曲目未内嵌专辑时使用，避免调用方到处判空）。
  static const AlbumRef empty = AlbumRef(guid: '', name: '');

  bool get isEmpty => guid.isEmpty && name.isEmpty;

  factory AlbumRef.fromJson(Map<String, dynamic> json) {
    return AlbumRef(
      guid: jsonString(json['guid']),
      name: jsonString(json['name']),
      coverId: jsonStringOrNull(json['coverId']),
      releaseDate: jsonStringOrNull(json['releaseDate']),
      barcode: jsonStringOrNull(json['barcode']),
      createdAt: jsonUnixSeconds(json['createdAt']),
      updatedAt: jsonUnixSeconds(json['updatedAt']),
    );
  }

  /// 序列化回服务端形态（供本地曲库索引落盘）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'guid': guid,
        'name': name,
        if (coverId != null) 'coverId': coverId,
        if (releaseDate != null) 'releaseDate': releaseDate,
        if (barcode != null) 'barcode': barcode,
        if (createdAt != null) 'createdAt': unixSecondsOf(createdAt),
        if (updatedAt != null) 'updatedAt': unixSecondsOf(updatedAt),
      };
}
