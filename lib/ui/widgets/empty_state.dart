import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'tv_focus.dart';

/// 统一的空态 / 背景提示 —— **不再使用大边框卡片**。
///
/// ## 为什么重做（实机截图驱动）
///
/// V4 的空态是「一个描边圆角大框 + 居中的技术说明」：
///
/// - 最近页：框里写着「飞牛没有提供播放历史接口，这里的记录由电视本机保存，
///   从『音乐库』里挑一首开始播放，这里就会留下痕迹。」
/// - 风格页：框里写着「飞牛曲目的 `genres` 字段在当前曲库里是空的……」
///
/// 实机（电视）上问题有两层：
/// 1. **视觉**：一个几乎占满内容区的大框，把「这里现在是空的」变成了
///    「这里出错了」；框线在深色底上非常抢眼，比页面标题还突出。
/// 2. **信息**：解释的是**实现**而不是**用户下一步该做什么**。
///
/// V5 的形态因此是：**低调水印**。
/// - 一枚大号半透明图标当背景（alpha 很低，像纸上的水印）；
/// - 一句 24 号短文案（电视 3 米外能读），色用 [TvColors.textDim]；
/// - 可选的第二行**短**提示（≤ 12 字/行），只讲"怎么让它有内容"；
/// - 可选的操作按钮，走 [TvFocus]，**可正常聚焦**；
/// - 没有边框、没有卡片、没有技术名词。
///
/// ⚠️ 水印与文案都**不参与焦点**：它们不是控件，也不会被 D-pad 选中，
/// 焦点只会落在按钮上（或页面里本该聚焦的元素上）。
///
/// ## 技术解释去哪了
/// 一律走 `Diagnostics.note/event`，只在诊断页可见。本组件不接受
/// 「原因说明」这类长文本参数 —— 接了就会有人往里塞技术细节。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.icon = Icons.inbox_outlined,
    this.hint,
    this.actionLabel,
    this.onAction,
    this.actionFocusNode,
    this.actionDebugLabel,
    this.actionAutofocus = false,
  });

  /// 主文案，例如「暂无最近播放」。**必须短**。
  final String title;

  /// 水印图标。
  final IconData icon;

  /// 第二行短提示，例如「从音乐库挑一首开始播放」。可为空。
  final String? hint;

  /// 操作按钮文案（如「去音乐库」）。为空则不显示按钮。
  final String? actionLabel;

  final VoidCallback? onAction;

  /// 外部焦点节点（用于把焦点链串到页面里）。
  final FocusNode? actionFocusNode;

  final String? actionDebugLabel;
  final bool actionAutofocus;

  @override
  Widget build(BuildContext context) {
    final String? hintText = hint;
    final String? label = actionLabel;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 水印：刻意压到 0.07 —— 只作为「这一块是空的」的视觉暗示，
            // 不能和上面的页面标题抢注意力。
            ExcludeFocus(
              child: Icon(
                icon,
                size: 108,
                color: TvColors.text.withValues(alpha: 0.07),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24,
                height: 1.25,
                color: TvColors.textDim,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (hintText != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                hintText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  height: 1.35,
                  color: TvColors.textFaint,
                ),
              ),
            ],
            if (label != null && onAction != null) ...<Widget>[
              const SizedBox(height: 26),
              TvFocus(
                focusNode: actionFocusNode,
                debugLabel: actionDebugLabel ?? 'empty.action',
                autofocus: actionAutofocus,
                onPressed: onAction,
                builder: (BuildContext c, TvFocusStatus s) => TvFocusRing(
                  status: s,
                  radius: 999,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 12),
                  child: Text(label, style: const TextStyle(fontSize: 19)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
