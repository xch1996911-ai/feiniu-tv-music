/// 登录态用户信息（与具体服务端解耦的领域模型）。
class User {
  final String guid;
  final String name;
  final String? role;

  const User({required this.guid, required this.name, this.role});

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      guid: (json['guid'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      role: json['role'] as String?,
    );
  }
}

/// 登录结果。包含服务端下发的 userToken 与用户信息。
class AuthResult {
  final String token; // 即 music-token
  final User user;

  const AuthResult({required this.token, required this.user});
}
