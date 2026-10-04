import 'package:feiniu_tv_music/services/remote/qr_code.dart';
import 'package:feiniu_tv_music/services/remote/remote_server.dart';
import 'package:feiniu_tv_music/ui/widgets/qr_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// 【V5 修复】二维码的**独立解码**验证。
///
/// ## 为什么要重写这组测试
///
/// 原来的 `qr_code.dart` 是手写编码器，它有两处独立错误：
/// ① 功能区域（30 个格式信息位）没有在填数据前预留 →
///    数据比特落点整体偏移；② 格式信息位坐标写成转置。
/// 而当时的测试是**自己生成的矩阵跟自己比**（两个格式副本互比），
/// 于是错误布局被自证成了「通过」。
///
/// 这次换掉了手写实现（改用 `package:qr`），验证方式也换成
/// **按规范另写一份解码器**，把矩阵解回字节再和原 URL 逐字节比对。
/// 解码器与编码器来自两套独立实现，因此这个断言是有意义的。
///
/// 解码范围刻意限制在 **版本 1–5 + 纠错等级 L**：
/// 这几档都是**单块（single block）**结构，不需要处理分块交织；
/// 本项目真实 URL（约 35 字符）只会用到版本 3。
void main() {
  group('结构不变量（与编码器实现无关）', () {
    final QrCode? qr = QrCode.encode(
      remotePairingUrl(host: '192.168.1.20', port: 18080, code: 'A1B2C3'),
    );

    test('编码成功、版本在 1–5（单块结构，可被本文件的解码器处理）', () {
      expect(qr, isNotNull);
      expect(qr!.size, 4 * qr.version + 17);
      expect(qr.version, inInclusiveRange(1, 5),
          reason: '真实 URL 约 35 字符，L 级下应当落在版本 3');
    });

    test('三个定位图案 + 分隔符 + 时序图案 + 暗模块', () {
      final int n = qr!.size;
      for (final List<int> o in <List<int>>[
        <int>[0, 0],
        <int>[0, n - 7],
        <int>[n - 7, 0],
      ]) {
        final int r0 = o[0], c0 = o[1];
        expect(qr.isDark(r0, c0), isTrue, reason: '定位图案外框角 $o');
        expect(qr.isDark(r0 + 1, c0 + 1), isFalse, reason: '白环 $o');
        expect(qr.isDark(r0 + 3, c0 + 3), isTrue, reason: '中心 3×3 $o');
        expect(qr.isDark(r0 + 6, c0 + 6), isTrue);
      }
      for (int i = 8; i < n - 8; i++) {
        expect(qr.isDark(6, i), i.isEven, reason: '时序图案第 6 行 col=$i');
        expect(qr.isDark(i, 6), i.isEven, reason: '时序图案第 6 列 row=$i');
      }
      expect(qr.isDark(n - 8, 8), isTrue, reason: '固定暗模块必须恒为深色');
    });

    test('渲染默认静区 ≥ 4 个模块（规范值）', () {
      expect(QrView(code: qr!).quietZoneModules, greaterThanOrEqualTo(4));
    });

    test('内容过长时返回 null（由页面走「手输地址」兜底）', () {
      expect(QrCode.encode('x' * 400), isNull);
      expect(QrCode.encode(''), isNull);
    });
  });

  group('独立解码 round-trip：解出来的字节必须等于原 URL', () {
    final List<String> urls = <String>[
      'http://192.168.1.20:18080/#A1B2C3',
      'http://10.0.0.2:18080/#ZZ99YY',
      'http://172.16.31.7:18080/#2345ABCDEF',
      'http://192.168.100.200:65535/#A2B3C4',
      'http://tv.local:18080/#QQQQQQ',
    ];

    for (final String url in urls) {
      test('解码一致：$url', () {
        final QrCode? qr = QrCode.encode(url);
        expect(qr, isNotNull, reason: '这个长度的 URL 必须能编码');
        final String? decoded = _decode(qr!);
        expect(decoded, isNotNull, reason: '矩阵必须能被规范解码器解出来');
        expect(decoded, url, reason: '解出来的内容必须与原文逐字节一致');
      });
    }

    test('超长 URL（版本 > 5）不做解码断言，但必须是合法矩阵', () {
      final QrCode? qr = QrCode.encode(
        remotePairingUrl(
          host: '192.168.123.234',
          port: 18080,
          code: 'ABCDEFGH',
        ),
      );
      expect(qr, isNotNull);
      expect(qr!.size, 4 * qr.version + 17);
    });
  });
}

// ══════════════════════════════════════════════════════════════════
// 下面是一份**按 QR 规范独立写的解码器**（只支持版本 1–5 + 纠错等级 L）。
//
// 它刻意不复用 lib 里任何编码逻辑：格式信息位、掩码公式、功能区域地图、
// 码字读取顺序、纠错校验都是照着规范另写一遍。
// 只有两套独立实现都对得上，「二维码是对的」才算有证据。
// ══════════════════════════════════════════════════════════════════

/// 版本 → (总码字数, 每块纠错码字数, 块数, 对齐图案中心)
///
/// 纠错等级 L 在版本 1–5 下都是**单块**（block count = 1），
/// 所以不需要分块交织。
const Map<int, List<int>> _specL = <int, List<int>>{
  1: <int>[26, 7, 1],
  2: <int>[44, 10, 1],
  3: <int>[70, 15, 1],
  4: <int>[100, 20, 1],
  5: <int>[134, 26, 1],
};

List<int> _alignCenters(int version) => switch (version) {
      1 => const <int>[],
      2 => const <int>[6, 18],
      3 => const <int>[6, 22],
      4 => const <int>[6, 26],
      5 => const <int>[6, 30],
      _ => const <int>[],
    };

/// 把矩阵解回字符串；任何一步不符合规范就返回 null。
String? _decode(QrCode qr) {
  final int n = qr.size;
  final List<int>? spec = _specL[qr.version];
  if (spec == null) return null;
  final int totalCodewords = spec[0];
  final int ecPerBlock = spec[1];
  final int dataCodewords = totalCodewords - ecPerBlock * spec[2];

  // ── 1) 功能区域地图（规范：这些格子不参与数据流）──────────────
  final List<List<bool>> fn = List<List<bool>>.generate(
    n,
    (_) => List<bool>.filled(n, false),
  );
  void markBlock(int r0, int c0, int h, int w) {
    for (int r = r0; r < r0 + h && r < n; r++) {
      for (int c = c0; c < c0 + w && c < n; c++) {
        if (r >= 0 && c >= 0) fn[r][c] = true;
      }
    }
  }

  markBlock(0, 0, 8, 8); // 左上定位 + 分隔符
  markBlock(0, n - 8, 8, 8); // 右上定位 + 分隔符
  markBlock(n - 8, 0, 8, 8); // 左下定位 + 分隔符
  for (int i = 0; i < n; i++) {
    fn[6][i] = true;
    fn[i][6] = true;
  }
  final List<int> centers = _alignCenters(qr.version);
  for (final int r in centers) {
    for (final int c in centers) {
      // 与定位图案重叠的三个位置没有对齐图案
      if ((r == 6 && c == 6) ||
          (r == 6 && c == centers.last) ||
          (r == centers.last && c == 6)) {
        continue;
      }
      markBlock(r - 2, c - 2, 5, 5);
    }
  }
  // 格式信息（规范位置，`m[row][col]`）
  for (int i = 0; i <= 5; i++) {
    fn[i][8] = true;
  }
  fn[7][8] = true;
  fn[8][8] = true;
  fn[8][7] = true;
  for (int i = 9; i <= 14; i++) {
    fn[8][14 - i] = true;
  }
  for (int i = 0; i <= 7; i++) {
    fn[8][n - 1 - i] = true;
  }
  for (int i = 8; i <= 14; i++) {
    fn[n - 15 + i][8] = true;
  }
  fn[n - 8][8] = true; // 固定暗模块

  // ── 2) 读格式信息（第一副本）→ 纠错等级 + 掩码 ────────────────
  int fmt = 0;
  for (int i = 0; i <= 5; i++) {
    if (qr.isDark(i, 8)) fmt |= 1 << i;
  }
  if (qr.isDark(7, 8)) fmt |= 1 << 6;
  if (qr.isDark(8, 8)) fmt |= 1 << 7;
  if (qr.isDark(8, 7)) fmt |= 1 << 8;
  for (int i = 9; i <= 14; i++) {
    if (qr.isDark(8, 14 - i)) fmt |= 1 << i;
  }
  final int unmaskedFmt = fmt ^ 0x5412;
  final int eccBits = (unmaskedFmt >> 13) & 0x03; // 01 = L
  final int mask = (unmaskedFmt >> 10) & 0x07;
  if (eccBits != 0x01) return null; // 本解码器只支持 L

  // ── 3) 反掩码 + 按规范顺序读码字 ──────────────────────────────
  bool unmask(int r, int c, bool bit) {
    final bool cond = switch (mask) {
      0 => (r + c) % 2 == 0,
      1 => r % 2 == 0,
      2 => c % 3 == 0,
      3 => (r + c) % 3 == 0,
      4 => (r ~/ 2 + c ~/ 3) % 2 == 0,
      5 => (r * c) % 2 + (r * c) % 3 == 0,
      6 => ((r * c) % 2 + (r * c) % 3) % 2 == 0,
      _ => ((r + c) % 2 + (r * c) % 3) % 2 == 0,
    };
    return cond ? !bit : bit;
  }

  final List<int> bits = <int>[];
  bool upwards = true;
  for (int col = n - 1; col > 0; col -= 2) {
    if (col == 6) col = 5;
    for (int i = 0; i < n; i++) {
      final int row = upwards ? n - 1 - i : i;
      for (final int c in <int>[col, col - 1]) {
        if (fn[row][c]) continue;
        bits.add(unmask(row, c, qr.isDark(row, c)) ? 1 : 0);
      }
    }
    upwards = !upwards;
  }

  final List<int> codewords = <int>[];
  for (int i = 0; i + 7 < bits.length && codewords.length < totalCodewords; i += 8) {
    int b = 0;
    for (int k = 0; k < 8; k++) {
      b = (b << 1) | bits[i + k];
    }
    codewords.add(b);
  }
  if (codewords.length < totalCodewords) return null;

  // ── 4) 独立性检查：纠错码字必须让所有校验子为 0 ────────────────
  final List<int> exp = List<int>.filled(512, 0);
  final List<int> logv = List<int>.filled(256, 0);
  int x = 1;
  for (int i = 0; i < 255; i++) {
    exp[i] = x;
    logv[x] = i;
    x <<= 1;
    if (x >= 0x100) x ^= 0x11D;
  }
  for (int i = 255; i < 512; i++) {
    exp[i] = exp[i - 255];
  }
  int mul(int a, int b) => (a == 0 || b == 0) ? 0 : exp[logv[a] + logv[b]];

  for (int i = 0; i < ecPerBlock; i++) {
    int acc = 0;
    for (final int cw in codewords) {
      acc = mul(acc, exp[i]) ^ cw;
    }
    if (acc != 0) return null; // 纠错码字算错 → 矩阵不可信
  }

  // ── 5) 解析字节模式载荷 ───────────────────────────────────────
  final List<int> data = codewords.sublist(0, dataCodewords);
  int bitPos = 0;
  int take(int len) {
    int v = 0;
    for (int i = 0; i < len; i++) {
      final int byteIndex = bitPos >> 3;
      if (byteIndex >= data.length) return -1;
      final int bit = (data[byteIndex] >> (7 - (bitPos & 7))) & 1;
      v = (v << 1) | bit;
      bitPos++;
    }
    return v;
  }

  final int mode = take(4);
  if (mode != 0x4) return null; // 字节模式
  final int len = take(8);
  if (len < 0) return null;
  final List<int> out = <int>[];
  for (int i = 0; i < len; i++) {
    final int b = take(8);
    if (b < 0) return null;
    out.add(b);
  }
  return String.fromCharCodes(out);
}
