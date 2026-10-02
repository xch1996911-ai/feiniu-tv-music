import 'package:feiniu_tv_music/core/ids.dart';
import 'package:flutter_test/flutter_test.dart';

/// deviceId 契约测试。
///
/// 真实契约 §1.2：`deviceId` 必须是 **32 位小写 hex**，
/// 且「生成一次后持久化复用，不允许每次启动重新生成」。
void main() {
  group('deviceId 生成', () {
    test('是 32 位小写 hex', () {
      for (var i = 0; i < 100; i++) {
        final id = Ids.generateDeviceId();
        expect(id.length, 32);
        expect(RegExp(r'^[a-f0-9]{32}$').hasMatch(id), isTrue,
            reason: '不符合 32 位小写 hex 契约，实际值：$id');
      }
    });

    test('每次生成都不同（碰撞概率可忽略）', () {
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        seen.add(Ids.generateDeviceId());
      }
      expect(seen.length, 200);
    });

    test('输出恒为小写（不出现 A-F）', () {
      for (var i = 0; i < 50; i++) {
        expect(Ids.generateDeviceId(), isNot(matches(RegExp(r'[A-F]'))));
      }
    });
  });

  group('deviceId 校验', () {
    test('接受合法值（含大写，兼容官方 /i 校验）', () {
      expect(Ids.isValidDeviceId('0123456789abcdef0123456789abcdef'), isTrue);
      expect(Ids.isValidDeviceId('0123456789ABCDEF0123456789ABCDEF'), isTrue);
    });

    test('拒绝长度错误 / 非 hex / 空 / null', () {
      expect(Ids.isValidDeviceId(null), isFalse);
      expect(Ids.isValidDeviceId(''), isFalse);
      expect(Ids.isValidDeviceId('0123456789abcdef0123456789abcde'), isFalse); // 31
      expect(Ids.isValidDeviceId('0123456789abcdef0123456789abcdef0'), isFalse); // 33
      expect(Ids.isValidDeviceId('0123456789abcdef0123456789abcdeg'), isFalse);
      expect(Ids.isValidDeviceId('zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'), isFalse);
    });
  });

  group('toHex', () {
    test('逐字节补零', () {
      expect(Ids.toHex(<int>[0, 1, 15, 16, 255]), '00010f10ff');
      expect(Ids.toHex(<int>[]), '');
    });
  });
}
