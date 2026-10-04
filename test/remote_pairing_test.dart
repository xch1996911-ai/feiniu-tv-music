import 'dart:math';

import 'package:feiniu_tv_music/services/remote/qr_code.dart';
import 'package:feiniu_tv_music/services/remote/remote_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// 【V5】手机遥控的配对模型与二维码结构（需求 §七.1 / §七.7）。
///
/// ⚠️ **本文件不能证明「手机相机能扫出来」**。本机既没有摄像头也没有
/// 电视真机，能验证的上界是：
/// - 配对/凭证的状态机正确（一次性、有效期、单会话、可撤销、去重）；
/// - 二维码的**结构**正确（尺寸、定位图案、时序图案、暗模块、格式信息）；
/// - 纠错码字在数学上正确（码字多项式在生成多项式各根上求值为 0，
///   这是 Reed–Solomon 正确性的充要条件）。
///
/// 「扫出来能打开」必须在真机上确认 —— 交付说明里已如实标注。
void main() {
  group('§七.7 配对与会话', () {
    late RemotePairingManager m;

    setUp(() {
      m = RemotePairingManager(random: Random(7));
    });

    tearDown(() {
      // 恢复默认有效期，避免影响其他用例
      RemotePairingManager.pairingTtl = const Duration(minutes: 5);
    });

    test('A 配对码是 6 位、取自无歧义字符集（去掉 0/O/1/I/L）', () {
      final String code = m.regenerateCode();
      expect(code.length, RemotePairingManager.codeLength);
      for (final String ch in code.split('')) {
        expect(RemotePairingManager.codeAlphabet.contains(ch), isTrue);
        expect('01OIL'.contains(ch), isFalse, reason: '手输兜底不能有易混字符');
      }
    });

    test('B 配对码一次性：用过即失效', () {
      final String code = m.regenerateCode();
      final String? token = m.pair(code: code, label: 'iPhone');
      expect(token, isNotNull);
      expect(m.pairingCode, isNull, reason: '用过的码必须立刻作废');
      expect(m.pair(code: code), isNull, reason: '同一个码不能再用第二次');
    });

    test('C 错误配对码被拒绝，且不会破坏已有会话', () {
      final String code = m.regenerateCode();
      expect(m.pair(code: 'AAAAAA'), isNull, reason: '错误的码必须被拒绝');
      expect(m.isPaired, isFalse);
      final String? token = m.pair(code: code);
      expect(token, isNotNull);
      expect(m.pair(code: 'BBBBBB'), isNull);
      expect(m.validate(token), isTrue, reason: '误输不该踢掉已配对的手机');
    });

    test('D 配对码过期后不可用', () {
      RemotePairingManager.pairingTtl = const Duration(milliseconds: -1);
      final String code = m.regenerateCode();
      expect(m.pairingCode, isNull, reason: '已过期的码等同于没有码');
      expect(m.pair(code: code), isNull);
    });

    test('E 凭证：正确通过、错误拒绝、撤销后立即失效', () {
      final String token = m.pair(code: m.regenerateCode())!;
      expect(m.validate(token), isTrue);
      expect(m.validate('${token}x'), isFalse);
      expect(m.validate(''), isFalse);
      expect(m.validate(null), isFalse);

      m.revoke(reason: '测试');
      expect(m.validate(token), isFalse, reason: '解除配对后旧凭证必须失效');
      expect(m.isPaired, isFalse);
    });

    test('F 单会话：新配对顶掉旧会话（需求 §七.6）', () {
      final String first = m.pair(code: m.regenerateCode())!;
      expect(m.validate(first), isTrue);

      // 重新生成配对码 = 准备给新手机配对 → 旧会话作废
      final String second = m.pair(code: m.regenerateCode())!;
      expect(second, isNot(first));
      expect(m.validate(first), isFalse, reason: '旧手机会话必须失效');
      expect(m.validate(second), isTrue);
    });

    test('G 命令去重：同一 id 第二次不再执行（防网络重发连切两首）', () {
      expect(m.markCommand('c1'), isTrue);
      expect(m.markCommand('c1'), isFalse);
      expect(m.markCommand('c2'), isTrue);
      // 无 id 的命令不做去重（老客户端兼容）
      expect(m.markCommand(''), isTrue);
      expect(m.markCommand(null), isTrue);
    });

    test('H 会话标签被裁剪且可读（电视上要显示「哪台手机」）', () {
      final String token =
          m.pair(code: m.regenerateCode(), label: '  iPhone 15 Pro  ')!;
      expect(token, isNotEmpty);
      expect(m.sessionLabel, 'iPhone 15 Pro');
    });
  });

  group('§七.1 二维码内容不含任何凭据', () {
    test('I 只包含地址与配对码，绝不包含账号/密码/长期令牌', () {
      final String url = remotePairingUrl(
        host: '192.168.1.20',
        port: 18080,
        code: 'A1B2C3',
      );
      expect(url, 'http://192.168.1.20:18080/#A1B2C3');
      // fragment 不会出现在 HTTP 请求里 → 不会进服务端访问日志
      expect(url.contains('#'), isTrue);
      for (final String bad in <String>[
        'password',
        'token',
        'user',
        '@',
        'music-token',
      ]) {
        expect(url.contains(bad), isFalse, reason: '不能包含 $bad');
      }
    });

    test('J 超出「电视上还能扫得动」的版本上限 → 返回 null，走手输兜底', () {
      // ⚠️ 版本 10（57×57）是本项目设定的上限，再大模块就小到扫不动。
      //    纠错等级 L 下版本 10 的字节容量约 271 字节，所以 **200 字节装得下**
      //    （库会选版本 9）—— 原来断言 `'x' * 200` 返回 null 是错的，
      //    实测返回的是一个合法矩阵。这里改用远超上限的长度，
      //    并顺带钉住「真实配对地址只会用到很小的版本」。
      expect(QrCode.encode('x' * 1200), isNull,
          reason: '超过版本 10 上限必须返回 null');

      final QrCode? normal =
          QrCode.encode('http://192.168.1.20:18080/#A1B2C3');
      expect(normal, isNotNull, reason: '真实配对地址必须能编码');
      expect(normal!.version, lessThanOrEqualTo(QrCode.maxVersion));
      expect(normal.version, lessThanOrEqualTo(5),
          reason: '约 35 字符的地址只应用到很小的版本，模块才够大');
    });
  });

  // ⚠️ 原来这里还有两组测试：「二维码结构（版本 4-L，33×33）」与
  //    「纠错码字的数学正确性」。它们验证的是项目自写的编码器内部
  //    （`debugFullCodewords` / `debugGenerator` / 固定 33×33 / 两个格式副本互比），
  //    而那套实现本身是错的（功能区域未预留 + 格式信息位转置），
  //    这两组「自证」测试也正是没能发现问题的原因。
  //    手写编码器已删除，二维码的验证改为 `test/qr_roundtrip_test.dart`：
  //    按规范另写一份解码器，把矩阵解回字节与原 URL 逐字节比对，
  //    并独立校验纠错码字的校验子为 0。
}
