import 'fnos_error_codes.dart';

/// 飞牛音乐 API 端点路径常量。
///
/// 网关：`http(s)://<NAS>:<port>/music/api/v1`
/// 端口：HTTP 5666 / HTTPS 5667（自签证书）。
///
/// ## 路径可信度
/// 本文件所有路径均已在**真实 NAS** 上实测（`fnOS_API_真实契约.md` §9）或
/// 从官方 Web 客户端 3.4 MB bundle 逆向确认，**不再是 Phase 0 的推测值**。
/// Phase 1 实际使用的 9 个接口逐项核对结论见 [phase1PathsVerified]。
///
/// 未逐一实测的路径（如 playlist / favorite / play-history）标注为「逆向确认」，
/// 属于 Phase 2 范围，此处仅作常量预留，不得在 Phase 1 调用。
class FnosEndpoints {
  /// API 基址（前端 `EO = `${TO}/api/v1``，实测生效）。
  static const String apiBase = '/music/api/v1';

  // ---------------------------------------------------------------- 免鉴权

  /// 连接探测 / 初始化状态。**免鉴权**，实测可匿名访问。
  static const String initializationState = '$apiBase/initialization/state';

  /// 系统配置。**免鉴权**。
  static const String sysConfig = '$apiBase/sys/config';

  // ------------------------------------------------------------------ 认证

  /// 密码登录。必填 `username` / `password`(sha256) / `deviceId`(32hex)。
  static const String passwordLogin = '$apiBase/user/password-login';
  static const String authLogin = '$apiBase/user/auth-login';
  static const String userMe = '$apiBase/user/me';
  static const String userLogout = '$apiBase/user/logout';

  // ------------------------------------------------------------------ 曲库

  /// 曲目分页列表。参数 **`page` + `size`**（默认 size=50）。
  static const String trackList = '$apiBase/track/list';

  /// 音频流。参数 `guid`，**服务端支持 HTTP 206 Range**（已实测）。
  static const String trackStream = '$apiBase/track/stream';

  /// 单曲元数据。参数 `guid`。
  static const String trackMetadata = '$apiBase/track/metadata';

  /// 专辑分页列表。参数 **`page` + `size`**。
  static const String albumList = '$apiBase/album/list';

  /// 专辑详情。参数 `guid`。
  static const String albumDetail = '$apiBase/album/detail';

  /// 歌手分页列表。参数 **`page` + `size`**。
  static const String artistList = '$apiBase/artist/list';

  /// 歌手全量列表（下拉选择用，字段比 `artist/list` 少）。逆向确认。
  static const String artistListAll = '$apiBase/artist/list-all';

  // ------------------------------------------------------------ 歌词 / 资源

  /// 歌词列表。⚠️ 参数名是 **`trackGUID`**（大写 GUID），
  /// 写成 `guid` 会返回 `100002 InvalidArgs`（已实测）。
  static const String lyricList = '$apiBase/lyric/list';

  /// 封面。⚠️ 参数名是 **`coverId`**，且必须传**含前缀的完整值**
  /// （如 `album_<32hex>` / `artist_<32hex>` / `track_<32hex>`），不允许拆掉前缀。
  static const String staticCover = '$apiBase/static/cover';

  // -------------------------------------------------- 逆向确认（Phase 2 预留）

  static const String genreList = '$apiBase/genre/list';
  static const String genreDetail = '$apiBase/genre/detail';
  static const String playlistList = '$apiBase/playlist/list';
  static const String playlistDetail = '$apiBase/playlist/detail';
  static const String favoriteTrackList = '$apiBase/favorite-track/list';
  static const String playHistoryList = '$apiBase/play-history/list';

  // -------------------------------------------------------------- 参数 / 分页

  /// 分页页码参数名（实测生效）。
  static const String paramPage = 'page';

  /// 分页条数参数名（实测生效；`pageSize` / `limit` **均被服务端忽略**）。
  static const String paramSize = 'size';

  /// 服务端默认每页条数（不传时的实际返回条数）。
  static const int defaultPageSize = 50;

  /// 歌词接口的曲目参数名（大小写敏感，必须是大写 GUID）。
  static const String paramTrackGuid = 'trackGUID';

  /// 封面接口的封面参数名。
  static const String paramCoverId = 'coverId';

  /// 业务成功码。
  static const int codeOk = FnosErrorCodes.ok;

  /// token Cookie 缺失 / 失效（HTTP 401）。
  static const int codeInvalidToken = FnosErrorCodes.invalidToken;

  /// 登录 / 授权失败。
  static const int codeUnauthorized = FnosErrorCodes.unauthorized;

  // 注意：这里**故意不再提供** `codeTokenExpired` 常量。
  // Phase 1 早期把 `120001` 当作 token 失效，是错的：
  // 实测 `120001` = 凭据错误（`unauthorized, please login again`，需重新输入凭据），
  // 而 token Cookie 失效是 `99999` + HTTP 401（可用已存密码哈希静默重登）。
  // 统一到 [FnosErrorCodes] 以避免再次混淆。

  /// Phase 1 实际使用的 9 个接口 → 核对结论（全部 VERIFIED，见真实契约 §9）。
  static const Map<String, bool> phase1PathsVerified = <String, bool>{
    'initialization/state': true,
    'user/password-login': true,
    'user/me': true,
    'track/list': true,
    'album/list': true,
    'artist/list': true,
    'lyric/list': true,
    'track/stream': true,
    'static/cover': true,
  };
}
