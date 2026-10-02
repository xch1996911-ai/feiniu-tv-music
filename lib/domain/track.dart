import 'album.dart';
import 'artist.dart';

/// 音频规格。用于正在播放页展示 `FLAC · 24bit / 96kHz` 之类的规格条。
/// Phase 1 仅解析常用字段，未知字段忽略。
class AudioSpec {
  final String? format; // 例：FLAC / MP3 / AAC
  final int? sampleRate; // Hz，例：96000
  final int? bitDepth; // 例：24
  final int? bitrate; // kbps

  const AudioSpec({
    this.format,
    this.sampleRate,
    this.bitDepth,
    this.bitrate,
  });

  /// 人类可读的规格串，如 `FLAC · 24bit / 96kHz`。
  String get display {
    final tail = <String>[];
    if (bitDepth != null) tail.add('${bitDepth}bit');
    if (sampleRate != null) {
      tail.add('${(sampleRate! / 1000).toStringAsFixed(0)}kHz');
    }
    if (format != null && format!.isNotEmpty) {
      final joined = tail.join(' / ');
      return joined.isEmpty ? format!.toUpperCase() : '${format!.toUpperCase()} · $joined';
    }
    return tail.join(' / ');
  }

  factory AudioSpec.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AudioSpec();
    return AudioSpec(
      format: json['format'] as String?,
      sampleRate: json['sampleRate'] == null ? null : _asInt(json['sampleRate']),
      bitDepth: json['bitDepth'] == null ? null : _asInt(json['bitDepth']),
      bitrate: json['bitrate'] == null ? null : _asInt(json['bitrate']),
    );
  }
}

/// 曲目。Phase 1 仅使用已验证字段（见需求 §6）。
class Track {
  final String guid;
  final String title;
  final String? coverId;
  final int durationMs;
  final AlbumRef album;
  final List<ArtistRef> artists;
  final AudioSpec audioSpec;
  final bool hasLyric;

  /// 3 = 音频文件已失效（不可播，UI 需标记）。
  final int accessStatus;

  const Track({
    required this.guid,
    required this.title,
    this.coverId,
    required this.durationMs,
    required this.album,
    required this.artists,
    required this.audioSpec,
    required this.hasLyric,
    required this.accessStatus,
  });

  bool get isAccessible => accessStatus != 3;

  String get artistNames =>
      artists.map((a) => a.name).where((n) => n.isNotEmpty).join(' / ');

  factory Track.fromJson(Map<String, dynamic> json) {
    final albumJson = json['album'] as Map<String, dynamic>?;
    final artistsJson = json['artists'];
    final List<ArtistRef> artists = artistsJson is List
        ? artistsJson
            .whereType<Map<String, dynamic>>()
            .map((e) => ArtistRef.fromJson(e))
            .toList()
        : const [];

    return Track(
      guid: (json['guid'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      coverId: json['coverId'] as String?,
      durationMs: _asInt(json['duration']),
      album: albumJson == null
          ? const AlbumRef(guid: '', name: '')
          : AlbumRef.fromJson(albumJson),
      artists: artists,
      audioSpec: AudioSpec.fromJson(json['audioSpec'] as Map<String, dynamic>?),
      hasLyric: json['hasLyric'] as bool? ?? false,
      accessStatus: _asInt(json['accessStatus']),
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
