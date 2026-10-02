import 'dart:convert';
import 'package:crypto/crypto.dart';

/// 飞牛音乐登录认证辅助。
///
/// 协议事实（technical_research.md §2.2）：`POST /user/password-login` 的密码字段
/// 需提交 `sha256(明文密码)` 的十六进制小写串，而非明文。
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
