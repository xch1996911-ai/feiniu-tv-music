import 'package:feiniu_tv_music/servers/fnos/fnos_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sha256("password") 与公开值一致', () {
    expect(
      FnosAuth.hashPassword('password'),
      '5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8',
    );
  });

  test('不同密码产生不同哈希', () {
    expect(FnosAuth.hashPassword('a'), isNot(FnosAuth.hashPassword('b')));
  });

  test('空字符串可计算', () {
    expect(FnosAuth.hashPassword(''), isNotEmpty);
  });
}
