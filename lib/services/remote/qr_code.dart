import 'package:qr/qr.dart' as qrlib;

/// 二维码矩阵（**薄适配层**）。
///
/// ## 为什么不自己写编码器了（重要）
///
/// 本项目原来有一份手写的「固定版本 4-L、单块、掩码 0」编码器。它在
/// **两处独立的错误**，任何一处都足以让扫码失败：
///
/// 1. **功能区域没有预留**：调用顺序是
///    `_drawFunctionPatterns → _drawData → _drawFormatInfo`，
///    但前者没有把 30 个格式信息单元格标记为「已占用」，
///    而 `_drawData` 只按「该格是否非 null」判断可填。
///    于是 30 个格式位被当成数据位消耗掉了比特，随后又被格式信息覆盖
///    —— **数据流的落点整体偏移**。
///    实测口径：当前可填 837 格，正确应为 837 − 30 = 807 格，
///    而载荷是 800 比特 ⇒ 剩余位应当恰好是 **7**（这正是版本 4 的
///    remainder bits 数）。也就是说：**把 837 全当数据区是错的**。
/// 2. **格式信息位坐标写成了转置**：第一副本应为
///    `m[i][8]=bit(i)`（i≤5）、`m[7][8]=bit(6)`、`m[8][7]=bit(8)`、
///    `m[8][14-i]=bit(i)`（i≥9）；第二副本应为
///    `m[8][size-1-i]=bit(i)`（i≤7）、`m[size-15+i][8]=bit(i)`（i≥8）。
///    原来的实现把行列写反、且第二副本两段错位。
///
/// 更糟的是当时的「验证」方式是**自己生成的矩阵跟自己比**
/// （两个格式信息副本互比），因此错误布局被自己确认成了「通过」。
///
/// 结论：**不再维护手写协议编码器**，改用成熟离线库 `package:qr`
/// （kevmoo，纯 Dart、无原生依赖、无 CDN）。
/// 注意「离线可用」与「要不要引依赖」是两件事 —— 引一个纯 Dart 包
/// 不会让手机端多任何网络请求。
///
/// 验证方式也随之改成**独立解码**：见 `test/qr_roundtrip_test.dart`，
/// 那里按规范另写一份解码器把矩阵解回字节再和原 URL 比。
/// 绝不能只把静区从 2 调到 4 就宣称修好了。
class QrCode {
  QrCode._(this._modules, this.version);

  final List<List<bool>> _modules;

  /// 实际采用的版本（1–40）。由库自动选择**能装下的最小版本**。
  ///
  /// 刻意不固定版本：模块越少 = 每个模块的物理尺寸越大 = 电视上越好扫。
  final int version;

  /// 边长（模块数）= 版本 × 4 + 17。
  int get size => _modules.length;

  /// 供画家与测试使用的只读矩阵（`[row][col]`）。
  List<List<bool>> get modules => _modules;

  bool isDark(int row, int col) => _modules[row][col];

  /// 允许的最大版本。超过就返回 null，由页面退化为「手输地址 + 配对码」。
  ///
  /// 版本 10 已经是 57×57，在电视上模块会小到几乎扫不出来，
  /// 所以宁可不显示二维码。正常 URL（约 35 字符）只会用到版本 3。
  static const int maxVersion = 10;

  /// 编码 [text]（UTF-8 字节模式）。装不下或参数非法时返回 null。
  ///
  /// 纠错等级固定 L：二维码只贴在电视屏幕上、没有物理磨损，
  /// L 级最省码字 → 版本更小 → 模块更大 → 更好扫。
  /// （这与「印刷品要用 M/Q」的直觉相反，但对本场景是对的。）
  static QrCode? encode(String text) {
    if (text.isEmpty) return null;
    try {
      final qrlib.QrCode code = qrlib.QrCode(
        payload: qrlib.QrPayload.fromString(text),
        errorCorrectLevel: qrlib.QrErrorCorrectLevel.low,
      );
      final qrlib.QrImage image = qrlib.QrImage(code);
      final int count = image.moduleCount;
      // 反推版本：边长 = 4v + 17
      final int version = (count - 17) ~/ 4;
      if (version < 1 || version > maxVersion) return null;
      final List<List<bool>> m = List<List<bool>>.generate(
        count,
        (int r) => List<bool>.generate(count, (int c) => image.isDark(r, c)),
      );
      return QrCode._(m, version);
    } catch (_) {
      // 内容过长（库内会抛）或任何内部异常：一律按「装不下」处理。
      // 调用方有「手输地址」兜底路径，绝不能因此让页面崩掉。
      return null;
    }
  }
}
