import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';

import '../core/diagnostics.dart';

/// 电视显示档位。
///
/// ## 为什么不能写死「960×540 @ DPR 4」
///
/// 同是一块 3840×2160 的面板，Android 上报的 `densityDpi` 可能是
/// 160 / 240 / 320 / 640，对应逻辑视口 3840×2160 / 2560×1440 /
/// 1920×1080 / 960×540 —— **四种完全不同的布局空间**。
/// 只看「物理分辨率是 4K」就按 4K 设计，会在 dpr=4 的机器上把界面放大 4 倍。
///
/// 因此档位由**逻辑视口 + 物理短边**共同决定，并且必须在真机上记录一次
/// 实际值（见 [note]），再据此校准字号。
enum TvDisplayProfile {
  /// 小视口（853×480、960×540）：一切让位给「不溢出」。
  compactTV,

  /// 标准视口（1280×720、1920×1080）：设计基准。
  standardTV,

  /// 大屏 4K（物理 ≥ 2000 短边且逻辑 ≥ 1600 宽）：字号略放大。
  large4KTV,
}

/// 显示档位解析与真机记录。
class TvDisplay {
  const TvDisplay._();

  /// 按当前视口解析档位。
  ///
  /// 判据顺序（先排除小视口，避免 4K 面板 + dpr4 被误判成大屏）：
  /// 1. 物理短边 ≥ 2000 且逻辑宽 ≥ 1600 → [TvDisplayProfile.large4KTV]；
  /// 2. 逻辑宽 ≥ 2400（4K 原生）→ [TvDisplayProfile.large4KTV]；
  /// 3. 逻辑宽 < 1100 或高 < 620 → [TvDisplayProfile.compactTV]；
  /// 4. 其余 → [TvDisplayProfile.standardTV]。
  static TvDisplayProfile resolve({
    required Size logical,
    required Size physical,
  }) {
    if (physical.shortestSide >= 2000 && logical.width >= 1600) {
      return TvDisplayProfile.large4KTV;
    }
    if (logical.width >= 2400) return TvDisplayProfile.large4KTV;
    if (logical.width < 1100 || logical.height < 620) {
      return TvDisplayProfile.compactTV;
    }
    return TvDisplayProfile.standardTV;
  }

  /// 从 context 解析（走 [View] 拿物理尺寸，避免依赖测试绑定行为）。
  static TvDisplayProfile of(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final FlutterView view = View.of(context);
    return resolve(logical: mq.size, physical: view.physicalSize);
  }

  /// 歌词字号倍率。
  ///
  /// DEV1 只做**温和放大**：85 英寸的真机值要等实机照片校准，
  /// 现在写死会把「先验假设」固化成难改的常量。
  static double lyricScale(TvDisplayProfile p) => switch (p) {
        TvDisplayProfile.compactTV => 1.0,
        TvDisplayProfile.standardTV => 1.0,
        TvDisplayProfile.large4KTV => 1.08,
      };

  /// 曲目信息（歌名/歌手）字号倍率。
  static double titleScale(TvDisplayProfile p) => switch (p) {
        TvDisplayProfile.compactTV => 1.0,
        TvDisplayProfile.standardTV => 1.0,
        TvDisplayProfile.large4KTV => 1.06,
      };

  /// 档位的短标签（诊断页/日志用）。
  static String label(TvDisplayProfile p) => switch (p) {
        TvDisplayProfile.compactTV => 'compactTV',
        TvDisplayProfile.standardTV => 'standardTV',
        TvDisplayProfile.large4KTV => 'large4KTV',
      };

  /// 把真实视口与档位写进 [Diagnostics]（只写一次由调用方保证）。
  ///
  /// 记录内容刻意包含 `platformView` 与 `textScale`：
  /// 前者能区分「Flutter 视口被系统栏压缩」，后者解释「为什么字忽然变大」。
  static void note(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final FlutterView view = View.of(context);
    final TvDisplayProfile p =
        resolve(logical: mq.size, physical: view.physicalSize);
    Diagnostics.note(
      '显示档位',
      '${label(p)} · 物理 '
          '${view.physicalSize.width.toInt()}×${view.physicalSize.height.toInt()}'
          ' · dpr ${view.devicePixelRatio.toStringAsFixed(2)}'
          ' · 逻辑 ${mq.size.width.toInt()}×${mq.size.height.toInt()}'
          ' · textScale ${mq.textScaler.scale(1.0).toStringAsFixed(2)}'
          ' · 安全区 t${mq.padding.top.toInt()}/b${mq.padding.bottom.toInt()}'
          ' · platformView '
          '${(mq.size * view.devicePixelRatio).width.toInt()}×'
          '${(mq.size * view.devicePixelRatio).height.toInt()}',
    );
  }
}
