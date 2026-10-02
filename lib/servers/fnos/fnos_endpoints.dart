/// 飞牛音乐 API 端点路径常量。
///
/// 网关：`http(s)://<NAS>:<port>/music/api/v1`
/// 端口：HTTP 5666 / HTTPS 5667（自签证书）。
///
/// 注意：以下路径来自 Phase 0 对第三方逆向资料与开源增强服务公开文档的事实整理，
/// **尚未在本沙箱用真实 NAS 跑通**，需经 `tools/fnos_api_probe` 真机验证后
/// 在 `docs/fnos_api_verified.md` 中标记 VERIFIED / FAILED。
class FnosEndpoints {
  static const String apiBase = '/music/api/v1';

  // 连接探测
  static const String initializationState = '$apiBase/initialization/state';

  // 认证
  static const String passwordLogin = '$apiBase/user/password-login';
  static const String userMe = '$apiBase/user/me';
  static const String userLogout = '$apiBase/user/logout';

  // 库数据
  static const String trackList = '$apiBase/track/list';
  static const String albumList = '$apiBase/album/list';
  static const String artistList = '$apiBase/artist/list';
  static const String lyricList = '$apiBase/lyric/list';

  // 流 / 资源
  static const String trackStream = '$apiBase/track/stream';
  static const String staticCover = '$apiBase/static/cover';

  /// 业务成功码
  static const int codeOk = 0;

  /// token 失效码（需触发重登录）
  static const int codeTokenExpired = 120001;
}
