/// 专辑。Phase 1 仅使用已验证字段（见 technical_research.md §6）。
class Album {
  final String guid;
  final String name;
  final String? coverId;
  final int trackCount;

  const Album({
    required this.guid,
    required this.name,
    this.coverId,
    required this.trackCount,
  });

  /// 从飞牛音乐 `album/list` / `album/detail` 响应的 data 项解析。
  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      guid: json['guid'] as String,
      name: (json['name'] as String?) ?? '',
      coverId: json['coverId'] as String?,
      trackCount: _asInt(json['trackCount']),
    );
  }
}

/// 曲目内嵌的专辑引用（轻量，无 trackCount）。
class AlbumRef {
  final String guid;
  final String name;
  final String? coverId;

  const AlbumRef({required this.guid, required this.name, this.coverId});

  factory AlbumRef.fromJson(Map<String, dynamic> json) {
    return AlbumRef(
      guid: json['guid'] as String,
      name: (json['name'] as String?) ?? '',
      coverId: json['coverId'] as String?,
    );
  }
}

int _asInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
