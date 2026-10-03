import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/boot_log.dart';
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

  // ================================================================
  //  播放偏好（非机密）
  //
  //  刻意**不**引入 shared_preferences：pubspec 里没有该依赖，
  //  而本类已封装了「加密可用则加密、不可用自动降级」的容错逻辑
  //  （部分 Android TV ROM 的 EncryptedSharedPreferences 会在原生层崩溃）。
  //  复用它比新增一个依赖更稳，也避免为偏好数据再冒一次 native crash 的风险。
  //
  //  这里存的东西**丢了不影响登录**，因此与上面的凭据区严格分开：
  //  `clearSession()` 不碰这里，用户登出后播放模式应当保留。
  // ================================================================

  static const String _kPlayMode = 'feiniu.playmode';
  static const String _kLastTrackGuid = 'feiniu.last.guid';
  static const String _kLastPositionMs = 'feiniu.last.pos';

  /// 读取上次播放模式；从未设置或值非法时返回 null。
  ///
  /// 返回 null 而不是给默认值，是为了让调用方区分「用户主动选过」
  /// 与「默认顺序播放」—— 前者不该被后续默认值变更覆盖。
  Future<String?> readPlayModeKey() => _read(_kPlayMode);

  Future<void> writePlayModeKey(String value) => _write(_kPlayMode, value);

  /// 上次播放的曲目 guid（V2 状态恢复用）。
  Future<String?> readLastTrackGuid() => _read(_kLastTrackGuid);

  Future<void> writeLastTrackGuid(String guid) => _write(_kLastTrackGuid, guid);

  /// 上次播放进度（**毫秒**）。
  Future<int?> readLastPositionMs() async {
    final v = await _read(_kLastPositionMs);
    if (v == null) return null;
    return int.tryParse(v);
  }

  Future<void> writeLastPositionMs(int ms) =>
      _write(_kLastPositionMs, ms.toString());

  /// 清除播放恢复信息（曲目 / 进度），**保留播放模式**。
  Future<void> clearLastPlayback() async {
    await _delete(_kLastTrackGuid);
    await _delete(_kLastPositionMs);
  }


  /// 读取 deviceId；不存在或形态非法（非 32 位 hex）时**生成并持久化**一个新的。
  ///
  /// 契约依据（`fnOS_API_真实契约.md` §1.2）：官方前端
  /// `localStorage` 缓存 + `/^[a-f0-9]{32}$/i` 校验，命中即复用；
  /// 且「不允许每次启动重新生成」。
  Future<String> getOrCreateDeviceId() async {
    // 首选原生 SharedPreferences（`MainActivity.deviceId()`）：
    // 部分 Android TV ROM 上 EncryptedSharedPreferences 会在**原生层直接崩溃**
    // （Keystore 不可用），Dart 的 try/catch 拦不住 —— 表现为「黑屏后闪退」。
    // deviceId 只是随机标识、非机密，不值得为它冒 native crash 的风险。
    final fromNative = await BootLog.nativeDeviceId();
    if (Ids.isValidDeviceId(fromNative)) {
      return fromNative!;
    }

    // 原生通道不可用时（例如单元测试）退回安全存储。
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
