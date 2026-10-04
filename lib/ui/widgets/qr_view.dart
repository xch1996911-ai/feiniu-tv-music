import 'package:flutter/material.dart';

import '../../services/remote/qr_code.dart';

/// 二维码渲染（把 [QrCode] 的布尔矩阵画成方块）。
///
/// 刻意用 `CustomPaint` 而不是拼一堆 `Container`：
/// 最大允许版本 10 时是 57×57 = 3249 个方块，用 widget 树渲染
/// 在低端电视盒子上会明显掉帧。
class QrView extends StatelessWidget {
  const QrView({
    super.key,
    required this.code,
    this.size = 300,
    this.quietZoneModules = 4,
  });

  final QrCode code;

  /// 控件边长（逻辑像素）。**由调用方按可用高度传入**，不要写死一个很大的值 ——
  /// 电视上常见逻辑视口只有 960×540，写死 300 以上会把页面顶出屏幕。
  final double size;

  /// 静区（quiet zone）模块数。
  ///
  /// ⚠️ 规范要求**至少 4**。这里默认就是 4，**不能再调小**：
  /// 曾经用 2，并打算靠「外层白底 10px」凑合 —— 那是不可靠的，
  /// 白边宽度随控件尺寸变化，而静区必须是**整整 4 个模块**。
  /// 静区不足是「扫不出来」最常见的原因之一。
  final int quietZoneModules;

  /// 外框白底的额外内边距（在静区之外，纯装饰，**不承担静区职责**）。
  static const double _framePadding = 10;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(_framePadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: CustomPaint(
        painter: _QrPainter(code, quietZoneModules),
        size: Size(size - _framePadding * 2, size - _framePadding * 2),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.code, this.quietZone);

  final QrCode code;
  final int quietZone;

  @override
  void paint(Canvas canvas, Size size) {
    final int n = code.size + 2 * quietZone;
    final double module = size.width / n;
    final Paint dark = Paint()..color = const Color(0xFF000000);

    // ⚠️ 只有当模块小于 2 逻辑像素时才多画 0.5px 补缝 ——
    //    否则相邻模块之间会露出抗锯齿缝隙（扫描器会把它读成浅色模块）。
    //    模块较大时**绝不能**扩张：那等于一个模块盖到邻居上，即篡改矩阵。
    final double grow = module < 2.0 ? 0.5 : 0.0;

    for (int r = 0; r < code.size; r++) {
      for (int c = 0; c < code.size; c++) {
        if (!code.isDark(r, c)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (c + quietZone) * module,
            (r + quietZone) * module,
            module + grow,
            module + grow,
          ),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) =>
      !identical(oldDelegate.code, code) ||
      oldDelegate.quietZone != quietZone;
}
