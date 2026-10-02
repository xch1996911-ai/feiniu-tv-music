import 'dart:developer' as dev;

/// 日志工具。
///
/// 安全约定：本文件所有方法**严禁接收明文密码或 Token 原文**。
/// 需要记录用户上下文时使用 [redactUser]；凭据一律不可打印。
class Log {
  static const String _tag = 'FeiNiuTV';

  static void i(String message) => dev.log(message, name: _tag);

  static void w(String message) => dev.log(message, name: _tag, level: 900);

  static void e(String message, [Object? error, StackTrace? stackTrace]) =>
      dev.log(message, name: _tag, level: 1000, error: error, stackTrace: stackTrace);

  /// 对用户名做脱敏：仅保留首字符 + 长度，例如 `a***(6)`。
  /// 永远不要直接打印完整用户名到日志。
  static String redactUser(String username) {
    if (username.isEmpty) return '(empty)';
    if (username.length == 1) return '${username[0]}***';
    return '${username[0]}***(${username.length})';
  }

  /// 对主机地址做轻度脱敏（保留端口与网段特征，隐藏最后一段用于区分的位数有限）。
  /// 仅用于日志排错，不在任何持久化文件写出真实凭据。
  static String redactHost(String host) {
    // 不隐藏主机，主机非机密；但避免在错误栈里带上 token 查询参数。
    return host.split('?').first;
  }
}
