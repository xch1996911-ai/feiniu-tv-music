import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 持久化的会话记录。
///
/// 安全约定（需求 §五）：
/// - `token` 永远保存（用于后续请求认证）。
/// - `passwordHash` **仅当**用户主动开启「记住密码」时保存，且保存的是 **sha256 哈希**而非明文密码。
///   飞牛登录接口接受 sha256 哈希本身，因此重登录时直接重发该哈希即可，无需明文。
class SessionRecord {
  final String host; // 含 scheme 与端口，如 http://192.168.1.10:5666
  final String username;
  final String token; // music-token
  final String? passwordHash; // sha256(明文)，可能为 null

  const SessionRecord({
    required this.host,
    required this.username,
    required this.token,
    this.passwordHash,
  });

  bool get canAutoRelogin => passwordHash != null && passwordHash!.isNotEmpty;
}

/// 凭据安全存储封装。底层为 flutter_secure_storage（Android 使用 EncryptedSharedPreferences / Keystore）。
class SecureStore {
  // Android 上使用 EncryptedSharedPreferences，比默认实现在国产盒子上更可靠（风险清单 #10）。
  static const AndroidOptions _androidOpts = AndroidOptions(
    encryptedSharedPreferences: true,
  );
  static const _storage = FlutterSecureStorage(aOptions: _androidOpts);

  static const String _kHost = 'feiniu.host';
  static const String _kUser = 'feiniu.user';
  static const String _kToken = 'feiniu.token';
  static const String _kPwHash = 'feiniu.pwhash';

  Future<void> saveSession(SessionRecord record) async {
    await _storage.write(key: _kHost, value: record.host);
    await _storage.write(key: _kUser, value: record.username);
    await _storage.write(key: _kToken, value: record.token);
    if (record.passwordHash != null && record.passwordHash!.isNotEmpty) {
      await _storage.write(key: _kPwHash, value: record.passwordHash!);
    } else {
      await _storage.delete(key: _kPwHash);
    }
  }

  /// 读取会话；若缺少 host 或 token 视为未登录，返回 null。
  Future<SessionRecord?> readSession() async {
    final host = await _storage.read(key: _kHost);
    final token = await _storage.read(key: _kToken);
    if (host == null || token == null) return null;
    final username = await _storage.read(key: _kUser) ?? '';
    final passwordHash = await _storage.read(key: _kPwHash);
    return SessionRecord(
      host: host,
      username: username,
      token: token,
      passwordHash: passwordHash,
    );
  }

  /// 清除全部会话（登出 / token 失效且无重登能力时）。
  Future<void> clearSession() async {
    await _storage.delete(key: _kHost);
    await _storage.delete(key: _kUser);
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kPwHash);
  }
}
