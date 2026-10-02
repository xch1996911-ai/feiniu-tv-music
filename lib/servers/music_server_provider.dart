import '../core/result.dart';
import '../domain/album.dart';
import '../domain/artist.dart';
import '../domain/paged_result.dart';
import '../domain/track.dart';
import '../domain/user.dart';

/// 音乐服务端抽象层。
///
/// 设计原则（technical_research.md §9.1）：
/// - 即使 V1 只支持飞牛，也保留此接口，未来 Subsonic / Jellyfin 仅新增实现，不改动调用方。
/// - V1 只定义 Phase 1 实际用到的最小方法集，不为未来预定义几十个接口。
/// - 返回类型均为与具体服务端解耦的领域模型。
abstract class MusicServerProvider {
  /// 实现标识，如 'fnos'。
  String get providerId;

  /// 展示名，如 '飞牛音乐'。
  String get label;

  /// 设置会话 token（登录成功后调用；登出/失效时传 null）。
  void setToken(String? token);

  /// 流 / 封面请求所需的认证头（供播放引擎携带，避免 token 进入 URL）。
  /// V1 为 Cookie 方案；Web 端 authx 签名头是否必需待 probe 验证。
  Map<String, String> get authHeaders;

  /// 连接探测：GET /initialization/state。返回服务端原始状态数据（data 部分）。
  Future<Result<Map<String, dynamic>>> checkConnection();

  /// 密码登录。`passwordSha256` 为 sha256(明文) 的十六进制小写串。
  Future<Result<AuthResult>> login(String username, String passwordSha256);

  /// 当前用户信息（需已登录）。
  Future<Result<User>> getMe();

  /// 曲目分页列表。
  Future<Result<PagedResult<Track>>> getTracks(int page, int size);

  /// 专辑分页列表。
  Future<Result<PagedResult<Album>>> getAlbums(int page, int size);

  /// 歌手分页列表。
  Future<Result<PagedResult<Artist>>> getArtists(int page, int size);

  /// 构造音频流 URL。认证通过请求头携带，不在 URL 暴露 token。
  String buildStreamUrl(String trackGuid);

  /// 构造封面 URL（统一 size 以便共享缓存）。
  String buildCoverUrl(String coverId, {int size = 800});
}
