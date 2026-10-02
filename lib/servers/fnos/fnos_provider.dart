import 'package:dio/dio.dart';

import '../../core/exceptions.dart';
import '../../core/ids.dart';
import '../../core/log.dart';
import '../../core/result.dart';
import '../../domain/album.dart';
import '../../domain/artist.dart';
import '../../domain/json_util.dart';
import '../../domain/lyric.dart';
import '../../domain/paged_result.dart';
import '../../domain/track.dart';
import '../../domain/user.dart';
import '../music_server_provider.dart';
import 'fnos_client.dart';
import 'fnos_endpoints.dart';

/// 飞牛音乐 [MusicServerProvider] 实现。
///
/// 持有 [FnosClient]，负责把原始 JSON 映射为领域模型。
/// 字段与单位以 `fnOS_API_真实契约.md`（真实 NAS 实测）为唯一基准。
class FnosProvider implements MusicServerProvider {
  @override
  final String providerId = 'fnos';

  @override
  final String label = '飞牛音乐';

  final FnosClient _client;

  FnosProvider({
    required String baseUrl,
    List<String> trustedHosts = const [],
    String? deviceId,
    String apiKey = '',
    HttpClientAdapter? adapter,
  }) : _client = FnosClient(
          baseUrl: baseUrl,
          trustedHosts: trustedHosts,
          deviceId: deviceId,
          apiKey: apiKey,
          // 仅用于单元测试注入离线适配器；生产路径为 null，走真实 HttpClient。
          adapter: adapter,
        );

  @override
  void setToken(String? token) => _client.setToken(token);

  /// 更新 deviceId（例如登录前从安全存储读出后注入）。
  void setDeviceId(String? deviceId) => _client.setDeviceId(deviceId);

  @override
  Map<String, String> get authHeaders => _client.authHeaders;

  @override
  Future<Result<Map<String, dynamic>>> checkConnection() =>
      _client.getRaw(FnosEndpoints.initializationState);

  @override
  Future<Result<AuthResult>> login(
    String username,
    String passwordSha256, {
    String? deviceId,
  }) async {
    // deviceId 必须存在且为 32 位 hex。持久化由调用方负责；
    // 这里只做「最后一道兜底」——宁可生成临时值也不要发出必然失败的请求，
    // 但会在日志里明确告警，避免掩盖持久化缺失。
    var id = deviceId ?? _client.deviceId;
    if (!Ids.isValidDeviceId(id)) {
      id = Ids.generateDeviceId();
      Log.w('登录时缺少合法 deviceId，已生成临时值（本次会话有效）；'
          '请检查 SecureStore 持久化路径');
    }
    _client.setDeviceId(id);

    final res = await _client.postRaw(FnosEndpoints.passwordLogin, {
      'username': username.trim(),
      'password': passwordSha256,
      'deviceId': id,
    });
    if (res.isErr) return Result.err(res.error);

    final token = extractToken(res.value);
    if (token == null || token.isEmpty) {
      return const Result.err(
          AppError('登录响应缺少 token 字段', kind: ErrorKind.parse));
    }

    final userJson = res.value['user'] is Map
        ? Map<String, dynamic>.from(res.value['user'] as Map)
        : <String, dynamic>{};
    return Result.ok(AuthResult(token: token, user: User.fromJson(userJson)));
  }

  /// 提取登录 token。
  ///
  /// 真实 NAS 直连返回 **`data.userToken`**（实测，`fnOS_API_真实契约.md` §1.2）；
  /// 官方桌面端桥接层会把它归一化成 `result.token`。
  /// 两者都兼容，但 **`data.userToken` 优先**。
  static String? extractToken(Map<String, dynamic> data) {
    final primary = data['userToken'];
    if (primary is String && primary.isNotEmpty) return primary;

    final flat = data['token'];
    if (flat is String && flat.isNotEmpty) return flat;

    final nested = data['result'];
    if (nested is Map) {
      final t = nested['token'];
      if (t is String && t.isNotEmpty) return t;
    }
    return null;
  }

  @override
  Future<Result<User>> getMe() async {
    final res = await _client.getRaw(FnosEndpoints.userMe);
    if (res.isErr) return Result.err(res.error);
    // 部分版本会把用户对象包在 `user` 里，这里做一层兼容。
    final json = res.value['user'] is Map
        ? Map<String, dynamic>.from(res.value['user'] as Map)
        : res.value;
    return Result.ok(User.fromJson(json));
  }

  @override
  Future<Result<PagedResult<Track>>> getTracks(int page, int size) async {
    final res = await _client.getRaw(FnosEndpoints.trackList,
        query: {FnosEndpoints.paramPage: page, FnosEndpoints.paramSize: size});
    if (res.isErr) return Result.err(res.error);
    return Result.ok(_toPaged(res.value, page, size, Track.fromJson));
  }

  @override
  Future<Result<PagedResult<Album>>> getAlbums(int page, int size) async {
    final res = await _client.getRaw(FnosEndpoints.albumList,
        query: {FnosEndpoints.paramPage: page, FnosEndpoints.paramSize: size});
    if (res.isErr) return Result.err(res.error);
    return Result.ok(_toPaged(res.value, page, size, Album.fromJson));
  }

  @override
  Future<Result<PagedResult<Artist>>> getArtists(int page, int size) async {
    final res = await _client.getRaw(FnosEndpoints.artistList,
        query: {FnosEndpoints.paramPage: page, FnosEndpoints.paramSize: size});
    if (res.isErr) return Result.err(res.error);
    return Result.ok(_toPaged(res.value, page, size, Artist.fromJson));
  }

  @override
  Future<Result<LyricDoc>> getLyrics(String trackGuid) async {
    // ⚠️ 参数名必须是 trackGUID（大写 GUID）；用 `guid` 会返回 100002 InvalidArgs。
    final res = await _client.getRaw(FnosEndpoints.lyricList, query: {
      FnosEndpoints.paramTrackGuid: trackGuid,
    });
    if (res.isErr) return Result.err(res.error);
    return Result.ok(LyricDoc.fromJson(res.value));
  }

  @override
  String buildStreamUrl(String trackGuid) => _client.buildStreamUrl(trackGuid);

  @override
  String buildCoverUrl(
    String coverId, {
    int size = MusicServerProvider.defaultCoverSize,
  }) =>
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
            .whereType<Map>()
            .map((e) => fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <T>[];
    // total 缺失时退回本页条数（不谎报总数）。
    final total = jsonIntOrNull(data['total']) ?? items.length;
    return PagedResult(items: items, total: total, page: page, size: size);
  }
}
