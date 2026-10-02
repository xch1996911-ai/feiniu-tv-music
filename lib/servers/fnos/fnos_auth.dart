import 'dart:convert';
import 'package:crypto/crypto.dart';

/// 飞牛音乐登录认证辅助。
///
/// 协议事实（`fnOS_API_真实契约.md` §1.2，真实 NAS 实测）：
/// `POST /user/password-login` 需要三个字段：
/// - `username`（trim 后）
/// - `password` = **sha256(明文密码) 小写 hex**
/// - `deviceId` = 32 位小写 hex（见 `core/ids.dart`，须持久化复用）
///
/// 明文密码永不离开本机，也不进入日志。
class FnosAuth {
  FnosAuth._();

  /// 计算密码的 sha256 hex（小写）。
  static String hashPassword(String plain) {
    final digest = sha256.convert(utf8.encode(plain));
    final buffer = StringBuffer();
    for (final b in digest.bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
