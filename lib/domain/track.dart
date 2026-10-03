import 'album.dart';
import 'artist.dart';
import 'json_util.dart';

/// 音频规格。用于正在播放页展示 `FLAC · 24bit / 96kHz` 之类的规格条。
///
/// ⚠️ 真实契约 §5.1：声道数字段名是 **`channel`（单数）**，
/// 不是 `channels`。Phase 1 早期按 `channels` 解析会永远拿不到值。
class AudioSpec {
  /// 展示用格式名，如 `flac`（前端原样返回小写）。
  final String? format;

  final String? codec;
  final String? container;

  /// Hz，例：44100
  final int? sampleRate;

  /// 位深，例：16
  final int? bitDepth;

  /// 比特率（bps，实测样本 962854）
  final int? bitrate;

  /// 声道数（字段名 `channel`，实测值 2）。
  final int? channel;

  /// 音频文件字节数。
  final int? size;

  /// 与顶层 `duration` 一致，单位 **毫秒**。
  final int? durationMs;

  const AudioSpec({
    this.format,
    this.sampleRate,
    this.bitDepth,
    this.bitrate,
    this.channel,
    this.codec,
    this.container,
    this.size,
    this.durationMs,
  });

  /// 人类可读的规格串，如 `FLAC · 16bit / 44kHz`。
  String get display {
    final tail = <String>[];
    if (bitDepth != null && bitDepth! > 0) tail.add('${bitDepth}bit');
    if (sampleRate != null && sampleRate! > 0) {
      tail.add('${(sampleRate! / 1000).toStringAsFixed(0)}kHz');
    }
    final head = format != null && format!.isNotEmpty
        ? format!.toUpperCase()
        : (codec != null && codec!.isNotEmpty ? codec!.toUpperCase() : '');
    if (head.isEmpty) return tail.join(' / ');
    final joined = tail.join(' / ');
    return joined.isEmpty ? head : '$head · $joined';
  }

  factory AudioSpec.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AudioSpec();
    return AudioSpec(
      format: jsonStringOrNull(json['format']),
      codec: jsonStringOrNull(json['codec']),
      container: jsonStringOrNull(json['container']),
      sampleRate: jsonIntOrNull(json['sampleRate']),
      bitDepth: jsonIntOrNull(json['bitDepth']),
      bitrate: jsonIntOrNull(json['bitrate']),
      channel: jsonIntOrNull(json['channel']),
      size: jsonIntOrNull(json['size']),
      durationMs: jsonIntOrNull(json['duration']),
    );
  }

  /// 序列化回**服务端形态**，使 [AudioSpec.fromJson] 能原样读回（往返一致）。
  ///
  /// 用途：本地曲库索引落盘（`lib/services/catalogue_store.dart`）。
  /// 刻意保持字段名与契约一致（`duration` 而不是 `durationMs`），
  /// 这样「落盘的 JSON」与「服务端返回的 JSON」是同一套解析路径 ——
  /// 少一套解析代码，就少一处将来会漂移的地方。
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (format != null) 'format': format,
        if (codec != null) 'codec': codec,
        if (container != null) 'container': container,
        if (sampleRate != null) 'sampleRate': sampleRate,
        if (bitDepth != null) 'bitDepth': bitDepth,
        if (bitrate != null) 'bitrate': bitrate,
        if (channel != null) 'channel': channel,
        if (size != null) 'size': size,
        if (durationMs != null) 'duration': durationMs,
      };
}

/// 曲目。
///
/// 字段集与单位全部来自真实 NAS 实测（`fnOS_API_真实契约.md` §4 / §5.1）：
/// - `duration`（顶层与 `audioSpec.duration`）单位是 **毫秒**；
/// - `createdAt` / `updatedAt` 单位是 **Unix 秒**；
/// - `id` 不存在，主键是 **`guid`**；
/// - 歌手是 **`artists: []`** 数组，不是 `artistNames` 字符串。
class Track {
  final String guid;
  final String title;

  /// 含前缀的完整封面 ID，如 `album_<32hex>` / `track_<32hex>`。
  final String? coverId;

  /// 顶层年份字段；实测为 `null`（真实年份在 `album.releaseDate`）。
  final int? year;

  final int? discNo;
  final int? trackNo;

  /// 国际标准录音代码。
  final String? isrc;

  /// 时长，**毫秒**。
  final int durationMs;

  /// 是否 CUE 分轨曲目。
  final bool isCue;

  /// 是否已收藏。
  final bool isFavorite;

  /// 曲目风格标签（实测样本为空数组）。
  final List<String> genres;

  /// Unix 秒。
  final DateTime? createdAt;

  /// Unix 秒。
  final DateTime? updatedAt;

  final AlbumRef album;
  final List<ArtistRef> artists;
  final AudioSpec audioSpec;

  /// ⚠️ 未在实测样本中出现，属保留字段（缺省 false）。不要据此判断「无歌词」。
  final bool hasLyric;

  /// ⚠️ 未在实测样本中出现，属保留字段（缺省 0 = 可播）。
  /// 3 = 音频文件已失效（不可播）。
  final int accessStatus;

  const Track({
    required this.guid,
    required this.title,
    this.coverId,
    this.year,
    this.discNo,
    this.trackNo,
    this.isrc,
    required this.durationMs,
    this.isCue = false,
    this.isFavorite = false,
    this.genres = const <String>[],
    this.createdAt,
    this.updatedAt,
    required this.album,
    required this.artists,
    required this.audioSpec,
    this.hasLyric = false,
    this.accessStatus = 0,
  });

  bool get isAccessible => accessStatus != 3;

  /// 时长（[Duration] 视图）。
  Duration get duration => Duration(milliseconds: durationMs);

  /// 歌手名拼接，如 `孙燕姿 / 周杰伦`。
  String get artistNames =>
      artists.map((a) => a.name).where((n) => n.isNotEmpty).join(' / ');

  /// 封面 ID 优先级（前端 `Qi()`）：`track.coverId` → `track.album.coverId`。
  ///
  /// 返回的是**含前缀的完整 coverId**，直接交给
  /// `GET /static/cover?coverId=<值>` 使用，不得拆分前缀。
  String? get effectiveCoverId {
    final own = coverId;
    if (own != null && own.isNotEmpty) return own;
    final fromAlbum = album.coverId;
    if (fromAlbum != null && fromAlbum.isNotEmpty) return fromAlbum;
    return null;
  }

  /// 发行年份：优先 `album.releaseDate`，退回顶层 `year`。
  int? get releaseYear => album.releaseDate != null && album.releaseDate!.length >= 4
      ? int.tryParse(album.releaseDate!.substring(0, 4))
      : year;

  factory Track.fromJson(Map<String, dynamic> json) {
    final albumRaw = json['album'];
    return Track(
      guid: jsonString(json['guid']),
      title: jsonString(json['title']),
      coverId: jsonStringOrNull(json['coverId']),
      year: jsonIntOrNull(json['year']),
      discNo: jsonIntOrNull(json['discNo']),
      trackNo: jsonIntOrNull(json['trackNo']),
      isrc: jsonStringOrNull(json['isrc']),
      durationMs: jsonInt(json['duration']),
      isCue: jsonBool(json['isCue']),
      isFavorite: jsonBool(json['isFavorite']),
      genres: jsonStringList(json['genres']),
      createdAt: jsonUnixSeconds(json['createdAt']),
      updatedAt: jsonUnixSeconds(json['updatedAt']),
      album: albumRaw is Map
          ? AlbumRef.fromJson(Map<String, dynamic>.from(albumRaw))
          : AlbumRef.empty,
      artists: ArtistRef.listFromJson(json['artists']),
      audioSpec: AudioSpec.fromJson(
        json['audioSpec'] is Map
            ? Map<String, dynamic>.from(json['audioSpec'] as Map)
            : null,
      ),
      hasLyric: jsonBool(json['hasLyric']),
      accessStatus: jsonInt(json['accessStatus']),
    );
  }

  /// 序列化回**服务端形态**（字段名与 `Track.fromJson` 完全对应）。
  ///
  /// ⚠️ 只用于**本地缓存**，不是「要写回 NAS」的载荷 —— 飞牛没有曲目写接口。
  /// 往返一致性由 `test/catalogue_index_test.dart` 的往返用例锁定。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'guid': guid,
        'title': title,
        if (coverId != null) 'coverId': coverId,
        'year': year,
        'discNo': discNo,
        'trackNo': trackNo,
        if (isrc != null) 'isrc': isrc,
        'duration': durationMs,
        'isCue': isCue,
        'isFavorite': isFavorite,
        'genres': genres,
        if (createdAt != null) 'createdAt': unixSecondsOf(createdAt),
        if (updatedAt != null) 'updatedAt': unixSecondsOf(updatedAt),
        'album': album.toJson(),
        'artists': <Map<String, dynamic>>[
          for (final ArtistRef a in artists) a.toJson(),
        ],
        'audioSpec': audioSpec.toJson(),
        'hasLyric': hasLyric,
        'accessStatus': accessStatus,
      };
}
