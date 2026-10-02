import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/ids.dart';

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

  /// 设备标识。**跨会话、跨登录保留**：官方前端把它放在 localStorage，
  /// 登出不会清除（清除会被服务端视作换了新设备）。
  static const String _kDeviceId = 'feiniu.deviceid';

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
  ///
  /// ⚠️ **不清除 deviceId** —— 契约要求 deviceId「生成一次后持久化复用」，
  /// 登出后重新登录必须复用同一个值。
  Future<void> clearSession() async {
    await _storage.delete(key: _kHost);
    await _storage.delete(key: _kUser);
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kPwHash);
  }

  /// 读取 deviceId；不存在或形态非法（非 32 位 hex）时**生成并持久化**一个新的。
  ///
  /// 契约依据（`fnOS_API_真实契约.md` §1.2）：官方前端
  /// `localStorage` 缓存 + `/^[a-f0-9]{32}$/i` 校验，命中即复用；
  /// 且「不允许每次启动重新生成」。
  Future<String> getOrCreateDeviceId() async {
    final cached = await readDeviceId();
    if (cached != null) return cached;
    final generated = Ids.generateDeviceId();
    await _storage.write(key: _kDeviceId, value: generated);
    return generated;
  }

  /// 读取已持久化的 deviceId；缺失或非法返回 null（不写入）。
  Future<String?> readDeviceId() async {
    final v = await _storage.read(key: _kDeviceId);
    return Ids.isValidDeviceId(v) ? v : null;
  }

  /// 强制覆盖 deviceId（仅用于排障 / 测试）。
  Future<void> writeDeviceId(String deviceId) async {
    if (!Ids.isValidDeviceId(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', '必须是 32 位 hex');
    }
    await _storage.write(key: _kDeviceId, value: deviceId);
  }
}
