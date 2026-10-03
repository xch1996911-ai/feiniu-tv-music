/// 极简 QR 编码器（**固定版本 4、纠错等级 L、字节模式**）。
///
/// ## 为什么自己写而不是加依赖
///
/// 需求 §七.2 要求「手机扫码打开适配手机的网页，**首次加载不依赖第三方 CDN**」。
/// 同理，电视端也不该为了画一个二维码去引入 `qr_flutter`（它又会带进
/// `qr` 包与一条新的原生/渲染链路）。本机没有 adb，多一个依赖就多一次
/// 「下载 APK → 拷 U 盘 → 装电视」的排错成本。
///
/// ## 为什么是「固定版本 4-L」而不是通用实现
///
/// 通用 QR 编码器需要版本 1–40 × 4 个纠错等级的**分块表**（几千个常量），
/// 而本场景只需要编码一个局域网 URL：
///
/// ```
/// http://192.168.1.20:5666/r#A1B2C3      ← 约 35 字节
/// ```
///
/// 版本 4 + 纠错 L 的字节模式容量是 **78 字节**，余量充足；而且版本 4-L 是
/// **单块**（80 个数据码字 + 20 个纠错码字），因此**不需要分块与交织**——
/// 这是本实现能做到「百余行且可读」的关键。矩阵尺寸 33×33 在电视上也够大。
///
/// ## 可读性优先
///
/// 掩码固定用 0 号（`(row + col) % 2 == 0`）。规范允许 8 种掩码任选其一，
/// 扫描器读格式信息即可自动识别，**不要求选「最优」掩码**——
/// 选最优要额外实现 4 条惩罚规则，收益只有观感。格式信息用标准 BCH(15,5)
/// **现算**（生成多项式 0x537 + 掩码 0x5412），因此不需要常量表。
///
/// ## 校验边界（如实声明）
/// 本机没有扫码设备，**无法验证「手机相机能扫出来」**。
/// 因此调用方必须同时展示可手输的 URL 作为兜底（见遥控页面）。
/// 本文件只保证结构正确，并用 `test/qr_code_test.dart` 锁定：
/// 尺寸、三个定位图案、时序图案、暗模块、格式信息位、纠错码字的
/// 多项式求值为零（RS 正确性的必要条件）。
library;

/// 生成的二维码矩阵。
class QrCode {
  /// 边长（模块数）。版本 4 = 33。
  final int size;

  /// `modules[row][col]`：true = 深色。
  final List<List<bool>> modules;

  const QrCode(this.size, this.modules);

  /// 版本（固定 4）。
  static const int version = 4;

  /// 纠错等级 L 在版本 4 下的数据码字数。
  static const int dataCodewords = 80;

  /// 版本 4-L 的纠错码字数。
  static const int ecCodewords = 20;

  /// 字节模式容量（字节）。78 = 80 - 2（模式 4bit + 长度 8bit 共 1.5 字节取整）。
  static const int byteCapacity = 78;

  /// 编码 [text]（UTF-8 字节模式）。超出容量返回 null（调用方走兜底展示）。
  static QrCode? encode(String text) {
    final List<int> bytes = _utf8(text);
    if (bytes.length > byteCapacity) return null;

    final List<int> data = _buildData(bytes);
    final List<int> ec = _reedSolomon(data, ecCodewords);
    final List<int> all = <int>[...data, ...ec];

    final List<List<bool?>> m = List<List<bool?>>.generate(
      matrixSize,
      (_) => List<bool?>.filled(matrixSize, null),
    );
    _drawFunctionPatterns(m);
    _drawData(m, all);
    _drawFormatInfo(m, mask: 0);
    return QrCode(
      matrixSize,
      List<List<bool>>.generate(
        matrixSize,
        (int r) =>
            List<bool>.generate(matrixSize, (int c) => m[r][c] ?? false),
      ),
    );
  }

  // ── 比特流 ────────────────────────────────────────────────

  static List<int> _buildData(List<int> bytes) {
    final List<int> bits = <int>[];
    void put(int value, int length) {
      for (int i = length - 1; i >= 0; i--) {
        bits.add((value >> i) & 1);
      }
    }

    put(0x4, 4); // 字节模式
    put(bytes.length, 8); // 版本 1–9 的长度字段是 8 位
    for (final int b in bytes) {
      put(b, 8);
    }

    final int capacityBits = dataCodewords * 8;
    // 结束符最多 4 个 0，且不能越过容量
    final int terminator = (capacityBits - bits.length).clamp(0, 4);
    put(0, terminator);
    // 补齐到字节边界
    while (bits.length % 8 != 0) {
      bits.add(0);
    }

    final List<int> out = <int>[];
    for (int i = 0; i < bits.length; i += 8) {
      int b = 0;
      for (int j = 0; j < 8; j++) {
        b = (b << 1) | bits[i + j];
      }
      out.add(b);
    }
    // 交替填充码字 0xEC / 0x11（规范指定值）
    const List<int> pad = <int>[0xEC, 0x11];
    int k = 0;
    while (out.length < dataCodewords) {
      out.add(pad[k++ % 2]);
    }
    return out;
  }

  // ── GF(256) 与 Reed–Solomon ───────────────────────────────

  static final List<int> _exp = _buildExp();
  static final List<int> _log = _buildLog();

  static List<int> _buildExp() {
    final List<int> e = List<int>.filled(512, 0);
    int x = 1;
    for (int i = 0; i < 255; i++) {
      e[i] = x;
      x <<= 1;
      if (x & 0x100 != 0) x ^= 0x11D; // 本原多项式
    }
    for (int i = 255; i < 512; i++) {
      e[i] = e[i - 255];
    }
    return e;
  }

  static List<int> _buildLog() {
    final List<int> l = List<int>.filled(256, 0);
    for (int i = 0; i < 255; i++) {
      l[_exp[i]] = i;
    }
    return l;
  }

  static int _mul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    return _exp[_log[a] + _log[b]];
  }

  /// 计算 [ecCount] 个纠错码字（多项式长除法取余）。
  static List<int> _reedSolomon(List<int> data, int ecCount) {
    final List<int> gen = _generatorPoly(ecCount);
    final List<int> rem = List<int>.filled(ecCount, 0);
    for (final int d in data) {
      final int factor = d ^ rem[0];
      for (int i = 0; i < ecCount - 1; i++) {
        rem[i] = rem[i + 1] ^ _mul(gen[i + 1], factor);
      }
      rem[ecCount - 1] = _mul(gen[ecCount], factor);
    }
    return rem;
  }

  /// 生成多项式 ∏(x − α^i)，返回长度 [ecCount]+1 的系数（首项为 1）。
  static List<int> _generatorPoly(int ecCount) {
    List<int> g = <int>[1];
    for (int i = 0; i < ecCount; i++) {
      final List<int> next = List<int>.filled(g.length + 1, 0);
      for (int j = 0; j < g.length; j++) {
        next[j] ^= g[j];
        next[j + 1] ^= _mul(g[j], _exp[i]);
      }
      g = next;
    }
    return g;
  }

  // ── 矩阵 ─────────────────────────────────────────────────

  /// 版本 4 的定位图案中心坐标（标准表：版本 4 → {6, 26}）。
  static const List<int> _alignCenters = <int>[6, 26];

  /// 矩阵边长（33）。
  /// ⚠️ 不能叫 `size`：本类已有同名的实例字段，Dart 会直接报重名。
  static const int matrixSize = version * 4 + 17;

  static void _drawFunctionPatterns(List<List<bool?>> m) {
    // 三个定位图案 + 分隔符
    _finder(m, 0, 0);
    _finder(m, 0, matrixSize - 7);
    _finder(m, matrixSize - 7, 0);

    // 时序图案（第 6 行 / 第 6 列，交替深浅）
    for (int i = 8; i < matrixSize - 8; i++) {
      m[6][i] = i % 2 == 0;
      m[i][6] = i % 2 == 0;
    }

    // 校正图案：所有中心组合中，去掉与三个定位图案重叠的三个
    for (final int r in _alignCenters) {
      for (final int c in _alignCenters) {
        final bool overlapsFinder = (r == 6 && c == 6) ||
            (r == 6 && c == _alignCenters.last) ||
            (r == _alignCenters.last && c == 6);
        if (overlapsFinder) continue;
        _alignment(m, r, c);
      }
    }

    // 固定深色模块（暗模块）
    m[matrixSize - 8][8] = true;
  }

  static void _finder(List<List<bool?>> m, int row, int col) {
    for (int r = -1; r <= 7; r++) {
      for (int c = -1; c <= 7; c++) {
        final int rr = row + r;
        final int cc = col + c;
        if (rr < 0 || rr >= matrixSize || cc < 0 || cc >= matrixSize) {
          continue;
        }
        final bool inRing = (r >= 0 && r <= 6 && (c == 0 || c == 6)) ||
            (c >= 0 && c <= 6 && (r == 0 || r == 6));
        final bool inCore = r >= 2 && r <= 4 && c >= 2 && c <= 4;
        m[rr][cc] = inRing || inCore;
      }
    }
  }

  static void _alignment(List<List<bool?>> m, int row, int col) {
    for (int r = -2; r <= 2; r++) {
      for (int c = -2; c <= 2; c++) {
        final bool ring = r.abs() == 2 || c.abs() == 2;
        final bool core = r == 0 && c == 0;
        m[row + r][col + c] = ring || core;
      }
    }
  }

  static void _drawData(List<List<bool?>> m, List<int> codewords) {
    final List<int> bits = <int>[];
    for (final int cw in codewords) {
      for (int i = 7; i >= 0; i--) {
        bits.add((cw >> i) & 1);
      }
    }

    int idx = 0;
    bool upward = true;
    // ⚠️ 这里的 `col` 必须能被**本体**改写（`col = 5`）而不是副本：
    //    第 6 列是时序图案，两模块宽的一对列跨过它时要整体左移一格，
    //    之后继续 `col -= 2` 才不会与已经填过的列重叠。
    //    写成 `int c = col; if (c == 6) c = 5;` 会让下一轮的 col=4 与
    //    本轮的 (5,4) 重复填同一列 —— 矩阵画得出来，但扫不出来。
    for (int col = matrixSize - 1; col > 0; col -= 2) {
      if (col == 6) col = 5;
      for (int i = 0; i < matrixSize; i++) {
        final int row = upward ? matrixSize - 1 - i : i;
        for (int k = 0; k < 2; k++) {
          final int cc = col - k;
          if (m[row][cc] != null) continue; // 功能图案
          final int bit = idx < bits.length ? bits[idx] : 0;
          idx++;
          m[row][cc] = _masked(row, cc, bit == 1);
        }
      }
      upward = !upward;
    }
  }

  /// 掩码 0：`(row + col) % 2 == 0` 时反转。
  static bool _masked(int row, int col, bool bit) =>
      (row + col) % 2 == 0 ? !bit : bit;

  static void _drawFormatInfo(List<List<bool?>> m, {required int mask}) {
    // 纠错等级 L 的指示位是 01
    const int eccBits = 0x01;
    final int data = (eccBits << 3) | mask;
    final int fmt = _bch15_5(data);

    int bit(int i) => (fmt >> i) & 1;

    // 第一个副本（左上角，围绕定位图案）
    for (int i = 0; i <= 5; i++) {
      m[8][i] = bit(i) == 1;
    }
    m[8][7] = bit(6) == 1;
    m[8][8] = bit(7) == 1;
    m[7][8] = bit(8) == 1;
    for (int i = 9; i <= 14; i++) {
      m[14 - i][8] = bit(i) == 1;
    }

    // 第二个副本（左下竖条 7 位 + 右上横条 8 位）
    for (int i = 0; i <= 6; i++) {
      m[matrixSize - 1 - i][8] = bit(i) == 1;
    }
    for (int i = 7; i <= 14; i++) {
      m[8][matrixSize - 8 + (i - 7)] = bit(i) == 1;
    }
  }

  /// 格式信息：BCH(15,5) + 固定掩码 0x5412（规范值，目的是避免全 0）。
  static int _bch15_5(int data) {
    const int gen = 0x537;
    int v = data << 10;
    for (int i = 4; i >= 0; i--) {
      if ((v >> (i + 10)) & 1 == 1) {
        v ^= gen << i;
      }
    }
    return ((data << 10) | v) ^ 0x5412;
  }

  /// 最小 UTF-8 编码（避免为了一个 `encode` 去引 `dart:convert` 之外的东西——
  /// 这里其实用 `dart:convert` 更稳妥，但保持文件零依赖更利于单测）。
  static List<int> _utf8(String s) {
    final List<int> out = <int>[];
    for (final int rune in s.runes) {
      if (rune < 0x80) {
        out.add(rune);
      } else if (rune < 0x800) {
        out.add(0xC0 | (rune >> 6));
        out.add(0x80 | (rune & 0x3F));
      } else if (rune < 0x10000) {
        out.add(0xE0 | (rune >> 12));
        out.add(0x80 | ((rune >> 6) & 0x3F));
        out.add(0x80 | (rune & 0x3F));
      } else {
        out.add(0xF0 | (rune >> 18));
        out.add(0x80 | ((rune >> 12) & 0x3F));
        out.add(0x80 | ((rune >> 6) & 0x3F));
        out.add(0x80 | (rune & 0x3F));
      }
    }
    return out;
  }

  /// 仅供测试：把「数据 + 纠错」整体当成多项式，在生成多项式各根上求值应为 0。
  ///
  /// 这是 Reed–Solomon 正确性的**充分必要条件**（码字是生成多项式的倍数），
  /// 因此即使本机没有扫码器，也能确定纠错段算对了。
  static List<int> debugFullCodewords(String text) {
    final List<int> data = _buildData(_utf8(text));
    final List<int> ec = _reedSolomon(data, ecCodewords);
    return <int>[...data, ...ec];
  }

  /// 仅供测试：生成多项式系数。
  static List<int> debugGenerator(int ecCount) => _generatorPoly(ecCount);

  /// 仅供测试：GF(256) 乘法。
  static int debugMul(int a, int b) => _mul(a, b);
}
