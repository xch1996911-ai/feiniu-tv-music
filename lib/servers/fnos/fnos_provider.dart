import '../../core/exceptions.dart';
import '../../core/result.dart';
import '../../domain/album.dart';
import '../../domain/artist.dart';
import '../../domain/paged_result.dart';
import '../../domain/track.dart';
import '../../domain/user.dart';
import '../music_server_provider.dart';
import 'fnos_client.dart';
import 'fnos_endpoints.dart';

/// 飞牛音乐 [MusicServerProvider] 实现。
///
/// 持有 [FnosClient]，负责把原始 JSON 映射为领域模型。不复制参考仓库源码，
/// 仅依据 technical_research.md 记录的协议事实自行实现。
class FnosProvider implements MusicServerProvider {
  @override
  final String providerId = 'fnos';

  @override
  final String label = '飞牛音乐';

  final FnosClient _client;

  FnosProvider({
    required String baseUrl,
    List<String> trustedHosts = const [],
  }) : _client = FnosClient(baseUrl: baseUrl, trustedHosts: trustedHosts);

  @override
  void setToken(String? token) => _client.setToken(token);

  @override
  Map<String, String> get authHeaders => _client.authHeaders;

  @override
  Future<Result<Map<String, dynamic>>> checkConnection() =>
      _client.getRaw(FnosEndpoints.initializationState);

  @override
  Future<Result<AuthResult>> login(String username, String passwordSha256) async {
    final res = await _client.postRaw(FnosEndpoints.passwordLogin, {
      'username': username,
      'password': passwordSha256,
    });
    if (res.isErr) return Result.err(res.error);

    final data = res.value;
    final token = (data['userToken'] as String?) ?? (data['token'] as String?);
    if (token == null || token.isEmpty) {
      return const Result.err(AppError('登录响应缺少 token 字段', kind: ErrorKind.parse));
    }
    final userJson =
        (data['user'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    return Result.ok(AuthResult(token: token, user: User.fromJson(userJson)));
  }

  @override
  Future<Result<User>> getMe() async {
    final res = await _client.getRaw(FnosEndpoints.userMe);
    if (res.isErr) return Result.err(res.error);
    return Result.ok(User.fromJson(res.value));
  }

  @override
  Future<Result<PagedResult<Track>>> getTracks(int page, int size) async {
    final res = await _client.getRaw(FnosEndpoints.trackList,
        query: {'page': page, 'size': size});
    if (res.isErr) return Result.err(res.error);
    return Result.ok(_toPaged(res.value, page, size, Track.fromJson));
  }

  @override
  Future<Result<PagedResult<Album>>> getAlbums(int page, int size) async {
    final res = await _client.getRaw(FnosEndpoints.albumList,
        query: {'page': page, 'size': size});
    if (res.isErr) return Result.err(res.error);
    return Result.ok(_toPaged(res.value, page, size, Album.fromJson));
  }

  @override
  Future<Result<PagedResult<Artist>>> getArtists(int page, int size) async {
    final res = await _client.getRaw(FnosEndpoints.artistList,
        query: {'page': page, 'size': size});
    if (res.isErr) return Result.err(res.error);
    return Result.ok(_toPaged(res.value, page, size, Artist.fromJson));
  }

  @override
  String buildStreamUrl(String trackGuid) => _client.buildStreamUrl(trackGuid);

  @override
  String buildCoverUrl(String coverId, {int size = 800}) =>
      _client.buildCoverUrl(coverId, size: size);

  PagedResult<T> _toPaged<T>(
    Map<String, dynamic> data,
    int page,
    int size,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final rawList = data['list'];
    final items = rawList is List
        ? rawList
            .whereType<Map<String, dynamic>>()
            .map(fromJson)
            .toList()
        : <T>[];
    final total = (data['total'] as int?) ?? items.length;
    return PagedResult(items: items, total: total, page: page, size: size);
  }
}
