import 'json_util.dart';

/// 登录态用户信息（与具体服务端解耦的领域模型）。
///
/// 字段来自真实 NAS 登录响应（`fnOS_API_真实契约.md` §1.2）：
/// `guid` / `name` / `role` / `lastAccessedAt` / `createdAt` / `updatedAt`。
/// 三个时间字段单位都是 **Unix 秒**。
class User {
  final String guid;
  final String name;
  final String? role;

  /// Unix 秒。
  final DateTime? lastAccessedAt;

  /// Unix 秒。
  final DateTime? createdAt;

  /// Unix 秒。
  final DateTime? updatedAt;

  const User({
    required this.guid,
    required this.name,
    this.role,
    this.lastAccessedAt,
    this.createdAt,
    this.updatedAt,
  });

  bool get isAdmin => role == 'admin';

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      guid: jsonString(json['guid']),
      name: jsonString(json['name']),
      role: jsonStringOrNull(json['role']),
      lastAccessedAt: jsonUnixSeconds(json['lastAccessedAt']),
      createdAt: jsonUnixSeconds(json['createdAt']),
      updatedAt: jsonUnixSeconds(json['updatedAt']),
    );
  }
}

/// 登录结果。包含服务端下发的 userToken 与用户信息。
class AuthResult {
  /// 即 `music-token` Cookie 的值（实测为 32 位十六进制串，**不是 JWT**）。
  final String token;

  final User user;

  const AuthResult({required this.token, required this.user});
}
