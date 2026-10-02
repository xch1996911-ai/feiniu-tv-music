/// 应用级错误分类。API 层与 Repository 层统一抛/返回 [AppError]，UI 据此区分提示。
enum ErrorKind {
  /// 网络不可达 / 超时 / DNS
  network,

  /// 认证失败（用户名/密码错误、安全码错误）
  auth,

  /// token 失效（飞牛返回 code == 120001）
  tokenExpired,

  /// 服务端返回业务错误（code != 0 且非 120001）
  server,

  /// JSON 解析 / 字段缺失
  parse,

  /// 资源不存在（404 / 空）
  notFound,

  /// 其他未知
  unknown,
}

class AppError {
  final String message;
  final ErrorKind kind;
  final Object? cause;
  final StackTrace? stack;

  const AppError(
    this.message, {
    this.kind = ErrorKind.unknown,
    this.cause,
    this.stack,
  });

  @override
  String toString() => 'AppError(${kind.name}): $message';

  AppError copyWith({String? message, ErrorKind? kind}) => AppError(
        message ?? this.message,
        kind: kind ?? this.kind,
        cause: cause,
        stack: stack,
      );
}
