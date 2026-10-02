import '../../core/exceptions.dart';

/// 飞牛音乐业务错误码（来源：`fnOS_API_真实契约.md` §2，实机 + 前端逆向双向确认）。
///
/// 关键区分（需求 §九）：
/// - **`120001` = 登录 / 授权失败**（凭据错误、需要重新登录）→ [ErrorKind.auth]
/// - **`99999` + HTTP 401 = `music-token` Cookie 缺失或失效** → [ErrorKind.tokenExpired]
///
/// 两者**不合并**：前者要用户重新输入凭据，后者可用已存密码哈希静默重登，
/// 在 UI 上的提示与处置路径完全不同。
class FnosErrorCodes {
  FnosErrorCodes._();

  // ---- 成功 ----
  static const int ok = 0;

  // ---- 通用 ----
  static const int unknown = 100001; // 未知错误（含参数缺失，如缺 deviceId）
  static const int invalidArgs = 100002; // 参数无效（如 lyric/list 缺 trackGUID）
  static const int adminRequired = 100003; // 需要管理员权限
  static const int forbidden = 100004; // 禁止访问
  static const int notFound = 100005; // 资源不存在

  // ---- 初始化 ----
  static const int appAlreadyInitialized = 110001;
  static const int appNotInitialized = 110002;
  static const int initRequiresNasAdmin = 110003;
  static const int initSessionNotFound = 110004;

  // ---- 用户 / 认证 ----
  static const int unauthorized = 120001; // 登录 / 授权失败
  static const int userDisabled = 120002; // 用户被禁用
  static const int oauthUserAlreadyExists = 120003;
  static const int usernameExists = 120004;
  static const int invalidUsername = 120005;
  static const int passwordRequired = 120006;

  // ---- CUE / 搜索 / 共享库 / 播放列表 ----
  static const int cueMissingOffset = 130001;
  static const int searchIndexRebuildInProgress = 140001;
  static const int playlistNameExists = 160001;
  static const int playlistHitMaxCount = 160002;

  /// HTTP 401 + 缺少/无效 `music-token` Cookie。
  static const int invalidToken = 99999;

  /// 错误码 → 人类可读名称（用于日志与提示）。
  static String nameOf(int code) {
    switch (code) {
      case ok:
        return 'OK';
      case unknown:
        return 'Unknown';
      case invalidArgs:
        return 'InvalidArgs';
      case adminRequired:
        return 'AdminRequired';
      case forbidden:
        return 'Forbidden';
      case notFound:
        return 'NotFound';
      case appAlreadyInitialized:
        return 'AppAlreadyInitialized';
      case appNotInitialized:
        return 'AppNotInitialized';
      case initRequiresNasAdmin:
        return 'InitRequiresNASAdmin';
      case initSessionNotFound:
        return 'InitSessionNotFound';
      case unauthorized:
        return 'Unauthorized';
      case userDisabled:
        return 'UserDisabled';
      case oauthUserAlreadyExists:
        return 'OAuthUserAlreadyExists';
      case usernameExists:
        return 'UsernameExists';
      case invalidUsername:
        return 'InvalidUsername';
      case passwordRequired:
        return 'PasswordRequired';
      case cueMissingOffset:
        return 'CueMissingOffset';
      case searchIndexRebuildInProgress:
        return 'SearchIndexRebuildInProgress';
      case playlistNameExists:
        return 'PlaylistNameExists';
      case playlistHitMaxCount:
        return 'PlaylistHitMaxCount';
      case invalidToken:
        return 'INVALID TOKEN';
      default:
        return 'Code($code)';
    }
  }

  /// 错误码 → 中文提示（面向 TV 端用户，尽量短）。
  static String messageOf(int code) {
    switch (code) {
      case unknown:
        return '请求参数有误或服务端未知错误';
      case invalidArgs:
        return '参数无效';
      case adminRequired:
        return '需要管理员权限';
      case forbidden:
        return '禁止访问';
      case notFound:
        return '资源不存在';
      case appNotInitialized:
        return '音乐服务尚未初始化，请先在 NAS 上启用';
      case appAlreadyInitialized:
        return '音乐服务已初始化';
      case initRequiresNasAdmin:
        return '初始化需要 NAS 管理员权限';
      case unauthorized:
        return '登录失败或授权已失效，请重新登录';
      case userDisabled:
        return '该用户已被禁用';
      case usernameExists:
        return '用户名已存在';
      case invalidUsername:
        return '用户名无效';
      case passwordRequired:
        return '需要密码';
      case cueMissingOffset:
        return 'CUE 文件缺少 offset';
      case searchIndexRebuildInProgress:
        return '搜索索引正在重建';
      case playlistNameExists:
        return '播放列表名已存在';
      case playlistHitMaxCount:
        return '播放列表数量已达上限';
      case invalidToken:
        return '登录已失效，请重新登录';
      default:
        return '服务端错误($code)';
    }
  }

  /// 错误码 → [ErrorKind]。未知码归入 [ErrorKind.server]（不猜测语义）。
  static ErrorKind kindOf(int code) {
    switch (code) {
      case ok:
        return ErrorKind.unknown; // 成功码不该走错误分支
      case notFound:
        return ErrorKind.notFound;
      case unauthorized:
      case userDisabled:
        return ErrorKind.auth;
      case invalidToken:
        return ErrorKind.tokenExpired;
      default:
        return ErrorKind.server;
    }
  }

  /// HTTP 状态码兜底映射（仅在没有可用业务码时使用）。
  ///
  /// `401` 在飞牛音乐网关下几乎只由 `music-token` Cookie 缺失/失效引起，
  /// 因此映射为 [ErrorKind.tokenExpired]；若响应体里带业务码，业务码优先。
  static ErrorKind kindForHttpStatus(int status) {
    if (status == 401 || status == 403) return ErrorKind.tokenExpired;
    if (status == 404) return ErrorKind.notFound;
    return ErrorKind.server;
  }
}
