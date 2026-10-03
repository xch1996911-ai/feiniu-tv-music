import 'dart:async';

import 'package:feiniu_tv_music/core/exceptions.dart';
import 'package:feiniu_tv_music/core/result.dart';
import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/paged_result.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/auth_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';

/// 曲目构造糖：测试里只关心 guid / 可播性 / 标题。
Track makeTrack(
  String guid, {
  String? title,
  int accessStatus = 0,
  int durationMs = 180000,
}) {
  return Track(
    guid: guid,
    title: title ?? '曲目 $guid',
    durationMs: durationMs,
    accessStatus: accessStatus,
    album: AlbumRef(guid: 'album_$guid', name: '专辑 $guid'),
    artists: const <ArtistRef>[],
    audioSpec: const AudioSpec(format: 'flac', sampleRate: 44100, bitDepth: 16),
  );
}

/// 失效曲目（`accessStatus == 3`，音频文件已失效 / 无权限）。
Track makeInvalidTrack(String guid) =>
    makeTrack(guid, accessStatus: 3, title: '失效 $guid');

/// 假音乐仓储：覆写播放与曲库测试真正用到的成员。
///
/// 真实 `MusicRepository` 的每个方法都会走 `_auth.provider`，
/// 未登录时抛 `StateError`；而构造 `AuthRepository` 本身不做任何 IO，
/// 因此这里可以安全地建一个未登录实例再覆写取值方法。
class FakeMusicRepository extends MusicRepository {
  FakeMusicRepository({Map<String, String>? headers})
      : _headers = headers ?? <String, String>{'Cookie': 'music-token=fake'},
        super(AuthRepository());

  final Map<String, String> _headers;

  /// 记录被请求过的曲目 guid，便于断言 URL 构造用对了曲目。
  final List<String> requestedGuids = <String>[];

  @override
  Map<String, String> get authHeaders => _headers;

  @override
  String buildStreamUrl(String trackGuid) {
    requestedGuids.add(trackGuid);
    return 'http://nas.example.invalid:5666/music/api/v1/track/stream?guid=$trackGuid';
  }

  /// 封面 URL 也必须覆写：真实实现要经 `_auth.provider`，
  /// 未登录时会抛 `StateError` —— 而只要测试里出现过 `CoverImage`，
  /// 这条路径就会被走到。
  @override
  String buildCoverUrl(
    String coverId, {
    int size = MusicServerProvider.defaultCoverSize,
  }) =>
      'http://nas.example.invalid:5666/music/api/v1/static/cover'
      '?coverId=$coverId&size=$size';

  // ── 分页（曲库测试用）─────────────────────────────────────

  /// 全量曲目池。`servePages` 会按 page/size 切片返回。
  List<Track> catalogue = <Track>[];

  /// 记录每次 `getTracks` 的 (page, size)，用于断言「同一页不会被请求两次」。
  final List<String> trackPageRequests = <String>[];

  /// 让下一次 getTracks 返回错误（测 error / retry 分支）。
  AppError? failNextTrackRequest;

  /// 每次 getTracks 的处理耗时开关（用于制造并发窗口）。
  Completer<void>? trackGate;

  @override
  Future<Result<PagedResult<Track>>> getTracks(int page, int size) async {
    trackPageRequests.add('$page/$size');
    final gate = trackGate;
    if (gate != null) await gate.future;

    final fail = failNextTrackRequest;
    if (fail != null) {
      failNextTrackRequest = null;
      return Result<PagedResult<Track>>.err(fail);
    }

    final start = (page - 1) * size;
    if (start >= catalogue.length) {
      return Result<PagedResult<Track>>.ok(PagedResult<Track>(
        items: const <Track>[],
        total: catalogue.length,
        page: page,
        size: size,
      ));
    }
    final end = (start + size) > catalogue.length ? catalogue.length : start + size;
    return Result<PagedResult<Track>>.ok(PagedResult<Track>(
      items: catalogue.sublist(start, end),
      total: catalogue.length,
      page: page,
      size: size,
    ));
  }
}
