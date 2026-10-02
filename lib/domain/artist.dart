/// 歌手。Phase 1 仅使用已验证字段。
class Artist {
  final String guid;
  final String name;
  final String? coverId;
  final int trackCount;
  final int albumCount;

  const Artist({
    required this.guid,
    required this.name,
    this.coverId,
    required this.trackCount,
    required this.albumCount,
  });

  factory Artist.fromJson(Map<String, dynamic> json) {
    return Artist(
      guid: json['guid'] as String,
      name: (json['name'] as String?) ?? '',
      coverId: json['coverId'] as String?,
      trackCount: _asInt(json['trackCount']),
      albumCount: _asInt(json['albumCount']),
    );
  }
}

/// 曲目内嵌的歌手引用（轻量）。
class ArtistRef {
  final String guid;
  final String name;
  final String? coverId;

  const ArtistRef({required this.guid, required this.name, this.coverId});

  factory ArtistRef.fromJson(Map<String, dynamic> json) {
    return ArtistRef(
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
