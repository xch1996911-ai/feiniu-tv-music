import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 统一的毛玻璃面板 —— 本轮全局视觉体系的基础件。
///
/// ## 为什么收敛成一个组件
/// 需求要求「首页、侧边导航、搜索框、概览卡片、歌曲行、收藏页、最近页、
/// 底部迷你播放器、退出确认框、播放队列面板和播放页统一到协调的毛玻璃视觉」。
/// 若每个页面各写一份 `BackdropFilter`，模糊半径、透明度、边线粗细必然
/// 各不相同 —— 看起来就是「一堆控件拼在一起」。这里收敛成**一个**组件。
///
/// ## 性能（电视端是硬约束）
/// `BackdropFilter` 每次重绘都要读回背景纹理做高斯模糊，是 Flutter 里
/// **最贵**的效果之一；低端 Android TV 盒子上大面积使用会明显掉帧甚至闪烁。
/// 因此：
/// 1. [blurEnabled] 是**全局开关**：设备不适合时置 false，视觉上仍是同一套
///    半透明深色底，只是不做模糊 —— 观感一致，开销归零。
///    （需求原话：「设备不适合高成本模糊时，使用视觉一致的半透明底色作为降级方案」）
/// 2. 模糊只用在**少量大块区域**（侧栏、顶栏、迷你播放器、底部操作栏、
///    弹窗、队列面板）；
/// 3. 列表行这类「可能同时出现几十个」的元素用 [TvGlass.blur] = false ——
///    只上色不模糊（见 [TrackRow] 的用法）。
///
/// ## 焦点不会被削弱
/// 玻璃面是半透明的，真正的焦点视觉由 `TvFocusRing` 负责，惯用法是
/// **把焦点环套在玻璃外面**：
/// ```dart
/// TvFocus(builder: (ctx, s) => TvFocusRing(status: s, child: TvGlass(child: ...)))
/// ```
/// 描边绘制在玻璃层的**上方**，因此不会被模糊、透明度或裁切削弱。
class TvGlass extends StatelessWidget {
  const TvGlass({
    super.key,
    required this.child,
    this.radius = 16,
    this.padding = EdgeInsets.zero,
    this.tint,
    this.borderColor,
    this.blur = true,
    this.blurSigma = 18,
    this.showBorder = true,
    this.shadow = true,
    this.width,
    this.height,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// 玻璃面色。默认 [TvColors.glass]。
  final Color? tint;

  final Color? borderColor;

  /// 是否启用背景模糊（且 [TvGlass.blurEnabled] 为 true 时才真正生效）。
  final bool blur;

  /// 模糊强度。电视上不要超过 24，否则边缘会出现明显的「涂抹感」。
  final double blurSigma;

  final bool showBorder;
  final bool shadow;

  final double? width;
  final double? height;

  /// **全局模糊开关**。
  ///
  /// 设备性能不足（或用户主动关闭）时置 false：
  /// 所有玻璃面自动退化为半透明底色，布局与配色完全不变。
  /// 做成静态可变字段而不是常量，是为了能在运行时按设备能力切换。
  static bool blurEnabled = true;

  @override
  Widget build(BuildContext context) {
    final Color fill = tint ?? TvColors.glass;

    final Widget inner = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: showBorder
            ? Border.all(color: borderColor ?? TvColors.glassLine)
            : null,
      ),
      child: child,
    );

    final bool useBlur = blur && blurEnabled;

    final Widget clipped = ClipRRect(
      // ⚠️ 必须裁剪：不裁的话 BackdropFilter 的模糊会溢出到圆角之外，
      //    在上层留下一圈脏边。
      borderRadius: BorderRadius.circular(radius),
      child: useBlur
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: blurSigma,
                sigmaY: blurSigma,
              ),
              child: inner,
            )
          : inner,
    );

    if (!shadow) return clipped;

    // 阴影画在**裁剪层外面**：否则会被 ClipRRect 一起裁掉。
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: TvColors.glassShadow,
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: clipped,
    );
  }
}

/// 弹窗 / 队列面板背后的遮罩。
///
/// 刻意**不做模糊**：模糊背景会让「当前焦点在弹窗里」这件事变得不明确
/// （底层内容依然清晰可见），反而削弱焦点感。
class TvScrim extends StatelessWidget {
  const TvScrim({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const Widget box = ColoredBox(color: TvColors.scrim);
    if (onTap == null) return box;
    return GestureDetector(onTap: onTap, child: box);
  }
}
