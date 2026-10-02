import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/ids.dart';
import '../core/log.dart';

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

/// 凭据安全存储封装。底层为 flutter_secure_storage
/// （Android 优先 EncryptedSharedPreferences，失败降级为普通 SharedPreferences）。
///
/// ## 为什么要做降级
///
/// `EncryptedSharedPreferences` 依赖 Android Keystore。部分 Android TV /
/// 电视盒子的 ROM 上 Keystore 不可用，读写会**直接抛异常**。而读会话
/// （[readSession] / [getOrCreateDeviceId]）正好发生在 App 启动路径上
/// （`AuthRepository.restore()`），一旦抛出且无人接管，就会表现为
/// 「点开 App 纯黑屏」。
///
/// 因此这里统一走 [_run]：加密模式抛异常时自动降级为普通模式并重试一次。
/// 降级是**有损**的（加密模式下写入的旧值读不出来，用户需重新登录一次），
/// 但远好于整个应用起不来。
class SecureStore {
  // Android 上优先使用 EncryptedSharedPreferences（比默认实现更可靠，风险清单 #10）。
  static const AndroidOptions _androidSecureOpts = AndroidOptions(
    encryptedSharedPreferences: true,
  );
  static const AndroidOptions _androidPlainOpts = AndroidOptions(
    encryptedSharedPreferences: false,
  );

  FlutterSecureStorage _storage =
      const FlutterSecureStorage(aOptions: _androidSecureOpts);

  /// 是否已因加密模式不可用而降级为普通存储（供排障展示）。
  bool _degraded = false;

  bool get isDegraded => _degraded;

  static const String _kHost = 'feiniu.host';
  static const String _kUser = 'feiniu.user';
  static const String _kToken = 'feiniu.token';
  static const String _kPwHash = 'feiniu.pwhash';

  /// 设备标识。**跨会话、跨登录保留**：官方前端把它放在 localStorage，
  /// 登出不会清除（清除会被服务端视作换了新设备）。
  static const String _kDeviceId = 'feiniu.deviceid';

  /// 统一执行一次存储操作：加密模式失败 → 降级为普通模式并重试一次。
  Future<T> _run<T>(
    Future<T> Function(FlutterSecureStorage storage) action,
  ) async {
    try {
      return await action(_storage);
    } catch (e, st) {
      if (_degraded) {
        Log.e('安全存储操作失败（已处于降级模式仍失败）', e, st);
        rethrow;
      }
      Log.w('加密安全存储不可用，降级为普通模式：$e');
      _degraded = true;
      _storage = const FlutterSecureStorage(aOptions: _androidPlainOpts);
      return action(_storage);
    }
  }

  Future<void> _write(String key, String value) =>
      _run((storage) => storage.write(key: key, value: value));

  Future<void> _delete(String key) =>
      _run((storage) => storage.delete(key: key));

  Future<String?> _read(String key) =>
      _run((storage) => storage.read(key: key));

  Future<void> saveSession(SessionRecord record) async {
    await _write(_kHost, record.host);
    await _write(_kUser, record.username);
    await _write(_kToken, record.token);
    final hash = record.passwordHash;
    if (hash != null && hash.isNotEmpty) {
      await _write(_kPwHash, hash);
    } else {
      await _delete(_kPwHash);
    }
  }

  /// 读取会话；若缺少 host 或 token 视为未登录，返回 null。
  Future<SessionRecord?> readSession() async {
    final host = await _read(_kHost);
    final token = await _read(_kToken);
    if (host == null || token == null) {
      return null;
    }
    final username = await _read(_kUser) ?? '';
    final passwordHash = await _read(_kPwHash);
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
    await _delete(_kHost);
    await _delete(_kUser);
    await _delete(_kToken);
    await _delete(_kPwHash);
  }

  /// 读取 deviceId；不存在或形态非法（非 32 位 hex）时**生成并持久化**一个新的。
  ///
  /// 契约依据（`fnOS_API_真实契约.md` §1.2）：官方前端
  /// `localStorage` 缓存 + `/^[a-f0-9]{32}$/i` 校验，命中即复用；
  /// 且「不允许每次启动重新生成」。
  Future<String> getOrCreateDeviceId() async {
    final cached = await readDeviceId();
    if (cached != null) {
      return cached;
    }
    final generated = Ids.generateDeviceId();
    await _write(_kDeviceId, generated);
    return generated;
  }

  /// 读取已持久化的 deviceId；缺失或非法返回 null（不写入）。
  Future<String?> readDeviceId() async {
    final v = await _read(_kDeviceId);
    return Ids.isValidDeviceId(v) ? v : null;
  }

  /// 强制覆盖 deviceId（仅用于排障 / 测试）。
  Future<void> writeDeviceId(String deviceId) async {
    if (!Ids.isValidDeviceId(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', '必须是 32 位 hex');
    }
    await _write(_kDeviceId, deviceId);
  }
}
