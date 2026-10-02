import 'dart:math';

/// 设备标识生成与校验。
///
/// 契约来源：`fnOS_API_真实契约.md` §1.2
/// 飞牛 `POST /user/password-login` 要求 `deviceId` 为 **32 位小写 hex**，
/// 且**生成一次后必须持久化复用**（官方前端写入 localStorage，且带
/// `/^[a-f0-9]{32}$/i` 校验，命中缓存则直接复用）。
///
/// 官方前端实现（`Tk()`）：优先 `crypto.randomUUID().replace(/-/g, '')`，
/// 退化时取 16 字节随机数转 16 进制。两者都等价于「16 随机字节 → 32 hex」，
/// 本实现统一走后者，避免依赖 Web Crypto 可用性差异。
class Ids {
  Ids._();

  /// 设备 ID 的合法形态：恰好 32 位 hex（大小写不敏感，本实现统一输出小写）。
  static final RegExp deviceIdPattern = RegExp(r'^[a-f0-9]{32}$', caseSensitive: false);

  static final Random _random = Random.secure();

  /// 生成一个新的设备 ID：16 随机字节 → 32 位小写 hex。
  ///
  /// 注意：调用方**必须**负责持久化（见 `SecureStore.getOrCreateDeviceId`），
  /// 不允许每次启动重新生成，否则服务端会把它当成新设备。
  static String generateDeviceId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// 校验是否为合法的 deviceId（32 位 hex）。用于读取持久化值时判断是否需要重新生成。
  static bool isValidDeviceId(String? value) =>
      value != null && deviceIdPattern.hasMatch(value);

  /// 16 进制小写工具（供其它需要 hex 摘要的地方复用）。
  static String toHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
