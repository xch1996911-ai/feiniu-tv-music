import 'package:flutter/material.dart';

import '../../services/remote/qr_code.dart';

/// 二维码渲染（把 [QrCode] 的布尔矩阵画成方块）。
///
/// 刻意用 `CustomPaint` 而不是拼一堆 `Container`：
/// 33×33 = 1089 个方块，用 widget 树渲染在低端电视盒子上会明显掉帧。
class QrView extends StatelessWidget {
  const QrView({
    super.key,
    required this.code,
    this.size = 220,
    this.quietZoneModules = 2,
  });

  final QrCode code;
  final double size;

  /// 静区（quiet zone）。规范要求至少 4 个模块，但电视上要省版面，
  /// 用 2 个模块 + 外围白边（白色背景本身也是静区）即可被相机识别。
  final int quietZoneModules;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: CustomPaint(
        painter: _QrPainter(code, quietZoneModules),
        size: Size(size - 20, size - 20),
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
    for (int r = 0; r < code.size; r++) {
      for (int c = 0; c < code.size; c++) {
        if (!code.modules[r][c]) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (c + quietZone) * module,
            (r + quietZone) * module,
            module + 0.5, // 多 0.5 像素，避免相邻模块间露出缝隙
            module + 0.5,
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
