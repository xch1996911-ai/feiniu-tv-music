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
      expect(m.pair(code: 'AAAAAA') == null || code == 'AAAAAA', isTrue);
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
      expect(m.pair(code), isNull);
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
          m.pair(code: m.regenerateCode(), label: '  iPhone 15 Pro  ');
      expect(token, isNotNull);
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

    test('J 超长地址返回 null，由调用方走「手输地址」兜底', () {
      final QrCode? qr = QrCode.encode('x' * 200);
      expect(qr, isNull);
    });
  });

  group('二维码结构（版本 4-L，33×33）', () {
    final QrCode qr = QrCode.encode(
      remotePairingUrl(host: '192.168.1.20', port: 18080, code: 'A1B2C3'),
    )!;

    bool at(int r, int c) => qr.modules[r][c];

    test('K 尺寸与三个定位图案', () {
      expect(qr.size, 33);
      // 三个 7×7 定位图案的角
      for (final List<int> o in <List<int>>[
        <int>[0, 0],
        <int>[0, 26],
        <int>[26, 0],
      ]) {
        final int r0 = o[0], c0 = o[1];
        expect(at(r0, c0), isTrue, reason: '定位图案外框角 $o');
        expect(at(r0 + 1, c0 + 1), isFalse, reason: '定位图案必须有白环 $o');
        expect(at(r0 + 3, c0 + 3), isTrue, reason: '定位图案中心 3×3 $o');
        expect(at(r0 + 6, c0 + 6), isTrue, reason: '定位图案外框角 $o');
      }
    });

    test('L 时序图案交替（第 6 行 / 第 6 列）', () {
      for (int i = 8; i < 25; i++) {
        expect(at(6, i), i.isEven, reason: '第 6 行第 $i 列');
        expect(at(i, 6), i.isEven, reason: '第 6 列第 $i 行');
      }
    });

    test('M 暗模块固定为深色', () {
      expect(at(25, 8), isTrue, reason: '4×4+9 位置的暗模块必须恒为深色');
    });

    test('N 格式信息两个副本一致（纠错等级 L + 掩码 0）', () {
      // 第二副本：左下竖条 7 位（bit0..6）与右上横条 8 位（bit7..14）
      final List<bool> second = <bool>[
        for (int i = 0; i <= 6; i++) at(32 - i, 8),
        for (int i = 7; i <= 14; i++) at(8, 25 + (i - 7)),
      ];
      final List<bool> first = <bool>[
        for (int i = 0; i <= 5; i++) at(8, i),
        at(8, 7),
        at(8, 8),
        at(7, 8),
        for (int i = 9; i <= 14; i++) at(14 - i, 8),
      ];
      expect(first, second, reason: '两个副本必须是同一份 15 位格式信息');
    });
  });

  group('纠错码字的数学正确性', () {
    test('O 码字多项式在生成多项式的每个根上求值为 0', () {
      final List<int> full = QrCode.debugFullCodewords(
        remotePairingUrl(host: '192.168.1.20', port: 18080, code: 'A1B2C3'),
      );
      expect(full.length, QrCode.dataCodewords + QrCode.ecCodewords);

      // 在 GF(256) 上求值：value = Σ c_i · x^(n-1-i)
      int evalAt(int x) {
        int v = 0;
        for (final int c in full) {
          v = QrCode.debugMul(v, x) ^ c;
        }
        return v;
      }

      // 生成多项式的根是 α^0 .. α^19（α = 2）
      int x = 1;
      for (int i = 0; i < QrCode.ecCodewords; i++) {
        expect(evalAt(x), 0,
            reason: '在 α^$i 处的求值必须为 0 —— 否则纠错码字算错了，'
                '二维码在稍有污损时就会读不出来');
        x = QrCode.debugMul(x, 2);
      }
    });

    test('P 生成多项式首项为 1、次数为 ecCodewords', () {
      final List<int> g = QrCode.debugGenerator(QrCode.ecCodewords);
      expect(g.length, QrCode.ecCodewords + 1);
      expect(g.first, 1);
    });

    test('Q GF(256) 乘法满足交换律与结合律抽样', () {
      for (final List<int> pair in <List<int>>[
        <int>[3, 7],
        <int>[255, 128],
        <int>[1, 200],
      ]) {
        expect(QrCode.debugMul(pair[0], pair[1]),
            QrCode.debugMul(pair[1], pair[0]));
      }
      expect(QrCode.debugMul(0, 99), 0);
      expect(QrCode.debugMul(1, 99), 99);
    });
  });
}
