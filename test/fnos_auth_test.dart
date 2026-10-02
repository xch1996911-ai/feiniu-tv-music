import 'package:feiniu_tv_music/servers/fnos/fnos_auth.dart';
import 'package:flutter_test/flutter_test.dart';

/// 登录密码哈希契约测试（真实契约 §1.2：`SHA256(明文密码)` 小写 hex）。
void main() {
  test('sha256("password") 与公开值一致', () {
    expect(
      FnosAuth.hashPassword('password'),
      '5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8',
    );
  });

  test('恒为 64 位小写 hex（服务端按此格式校验）', () {
    for (final pwd in <String>['a', 'password', '中文密码', '!@#\$%^&*()']) {
      final h = FnosAuth.hashPassword(pwd);
      expect(h.length, 64);
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(h), isTrue, reason: pwd);
    }
  });

  test('同样输入得到同样哈希（幂等，可用于 token 失效后静默重登）', () {
    expect(FnosAuth.hashPassword('same'), FnosAuth.hashPassword('same'));
  });

  test('不同密码产生不同哈希', () {
    expect(FnosAuth.hashPassword('a'), isNot(FnosAuth.hashPassword('b')));
  });

  test('空字符串可计算', () {
    expect(
      FnosAuth.hashPassword(''),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });
}
