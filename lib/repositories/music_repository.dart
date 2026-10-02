import 'package:flutter/foundation.dart';

import '../core/result.dart';
import '../domain/album.dart';
import '../domain/artist.dart';
import '../domain/paged_result.dart';
import '../domain/track.dart';
import '../servers/music_server_provider.dart';
import 'auth_repository.dart';

/// 音乐库仓储：通过当前激活的 [MusicServerProvider] 转发读取请求。
/// 负责分页调用与（未来）缓存策略的接入点；V1 直接透传。
///
/// 继承 [ChangeNotifier] 以满足 app.dart 中 `ChangeNotifierProvider` 的类型约束，
/// 与 AuthRepository / PlaybackRepository 保持一致的响应式约定。
class MusicRepository extends ChangeNotifier {
  final AuthRepository _auth;

  MusicRepository(this._auth);

  MusicServerProvider get _provider {
    final p = _auth.provider;
    if (p == null) {
      throw StateError('尚未登录，无法访问音乐库');
    }
    return p;
  }

  /// 流 / 封面请求所需的认证头。
  Map<String, String> get authHeaders => _provider.authHeaders;

  Future<Result<Map<String, dynamic>>> checkConnection() =>
      _provider.checkConnection();

  Future<Result<PagedResult<Track>>> getTracks(int page, int size) =>
      _provider.getTracks(page, size);

  Future<Result<PagedResult<Album>>> getAlbums(int page, int size) =>
      _provider.getAlbums(page, size);

  Future<Result<PagedResult<Artist>>> getArtists(int page, int size) =>
      _provider.getArtists(page, size);

  String buildStreamUrl(String trackGuid) => _provider.buildStreamUrl(trackGuid);

  String buildCoverUrl(String coverId, {int size = 800}) =>
      _provider.buildCoverUrl(coverId, size: size);
}
