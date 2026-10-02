import '../core/result.dart';
import '../domain/album.dart';
import '../domain/artist.dart';
import '../domain/lyric.dart';
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
  /// 封面默认尺寸。
  ///
  /// 官方前端枚举值为 `200 / 120 / 60 / 100`（真实契约 §6），
  /// 取**最大已确认值**作默认，避免请求服务端未验证的尺寸。
  static const int defaultCoverSize = 200;

  /// 实现标识，如 'fnos'。
  String get providerId;

  /// 展示名，如 '飞牛音乐'。
  String get label;

  /// 设置会话 token（登录成功后调用；登出/失效时传 null）。
  void setToken(String? token);

  /// 流 / 封面请求所需的认证头（供播放引擎携带，避免 token 进入 URL）。
  ///
  /// 实测结论：V1 为 **Cookie `music-token`** 方案（硬门槛）；
  /// `authx` 签名头只是与官方客户端对齐的兼容层，由实现内部处理，不在此暴露。
  Map<String, String> get authHeaders;

  /// 连接探测：GET /initialization/state。返回服务端原始状态数据（data 部分）。
  ///
  /// 该接口**免鉴权**（真实契约 §1.1），因此可用于登录前的连通性检查。
  Future<Result<Map<String, dynamic>>> checkConnection();

  /// 密码登录。
  ///
  /// [passwordSha256] 为 sha256(明文) 的十六进制小写串。
  /// [deviceId] 为 32 位小写 hex；由调用方从安全存储读取后传入，
  /// 实现层不得每次启动自行重新生成（否则服务端会视作新设备）。
  Future<Result<AuthResult>> login(
    String username,
    String passwordSha256, {
    String? deviceId,
  });

  /// 当前用户信息（需已登录）。
  Future<Result<User>> getMe();

  /// 曲目分页列表。分页参数为 `page` + `size`（服务端默认 size=50）。
  Future<Result<PagedResult<Track>>> getTracks(int page, int size);

  /// 专辑分页列表。分页参数为 `page` + `size`。
  Future<Result<PagedResult<Album>>> getAlbums(int page, int size);

  /// 歌手分页列表。分页参数为 `page` + `size`。
  Future<Result<PagedResult<Artist>>> getArtists(int page, int size);

  /// 歌词。参数名必须是 `trackGUID`（大小写敏感）。
  Future<Result<LyricDoc>> getLyrics(String trackGuid);

  /// 构造音频流 URL。认证通过请求头携带，不在 URL 暴露 token。
  ///
  /// 服务端支持 HTTP 206 Range，因此播放器可直接 Seek，无需自建分块下载。
  String buildStreamUrl(String trackGuid);

  /// 构造封面 URL。
  ///
  /// [coverId] 必须传**含前缀的完整值**（`album_` / `artist_` / `track_`），
  /// 不得拆分。调用方应优先使用 `Track.effectiveCoverId`（track → album 回退）。
  String buildCoverUrl(String coverId, {int size = defaultCoverSize});
}
