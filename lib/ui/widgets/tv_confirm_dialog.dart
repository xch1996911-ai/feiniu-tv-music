import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'tv_focus.dart';
import 'tv_glass.dart';

/// 电视端确认弹窗（退出登录等破坏性操作）。
///
/// ## 为什么不用 `AlertDialog`
/// Material 的 `AlertDialog` 按钮是 `TextButton`，内部各自持有 `FocusNode`，
/// 与本项目的焦点环体系冲突（「有环没动作 / 有动作没环」）。
/// 这里用 [TvFocus] 重做，保证焦点与视觉完全可控。
///
/// ## 焦点
/// - 弹窗打开时**默认焦点在「取消」**上：破坏性操作不该一按 OK 就执行，
///   这是遥控器场景下防误触的关键；
/// - `取消 ↔ 确认` 左右相连，两边都能随手走到；
/// - 弹窗居中且完整显示（不贴屏幕边缘），文字与按钮都不会被裁掉。
///
/// ## 返回
/// 用 `showDialog` 承载，因此 BACK 键由 Navigator 优先关闭弹窗
/// （不会穿透到底下 Shell 的 PopScope 去执行「回首页」）。
class TvConfirmDialog extends StatelessWidget {
  const TvConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmLabel = '确认',
    this.cancelLabel = '取消',
    this.danger = true,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;

  /// true 时确认按钮用警示色（破坏性操作）。
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return TvConfirmDialogBody(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      danger: danger,
      onCancel: () => Navigator.of(context).pop(false),
      onConfirm: () => Navigator.of(context).pop(true),
    );
  }
}

/// 弹窗主体（独立出来便于在需要时**不走 Navigator** 地内嵌使用）。
class TvConfirmDialogBody extends StatelessWidget {
  const TvConfirmDialogBody({
    super.key,
    required this.title,
    required this.message,
    required this.onCancel,
    required this.onConfirm,
    this.confirmLabel = '确认',
    this.cancelLabel = '取消',
    this.danger = true,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool danger;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      // 显式给一个内边距：保证弹窗在电视上**不贴边**，
      // 焦点框不会被屏幕边缘或 overscan 吃掉。
      insetPadding: const EdgeInsets.symmetric(horizontal: 120, vertical: 80),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: TvGlass(
          radius: 20,
          tint: TvColors.glassHi,
          padding: const EdgeInsets.fromLTRB(30, 26, 30, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    danger ? Icons.warning_amber : Icons.help_outline,
                    size: 26,
                    color: danger ? TvColors.warn : TvColors.accent,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: TvColors.text,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                message,
                style: const TextStyle(
                  fontSize: 17,
                  height: 1.5,
                  color: TvColors.textDim,
                ),
              ),
              const SizedBox(height: 24),
              _DialogButtons(
                cancelLabel: cancelLabel,
                confirmLabel: confirmLabel,
                danger: danger,
                onCancel: onCancel,
                onConfirm: onConfirm,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogButtons extends StatefulWidget {
  const _DialogButtons({
    required this.cancelLabel,
    required this.confirmLabel,
    required this.danger,
    required this.onCancel,
    required this.onConfirm,
  });

  final String cancelLabel;
  final String confirmLabel;
  final bool danger;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  State<_DialogButtons> createState() => _DialogButtonsState();
}

class _DialogButtonsState extends State<_DialogButtons> {
  final FocusNode _cancel = FocusNode(debugLabel: 'dialog.cancel');
  final FocusNode _confirm = FocusNode(debugLabel: 'dialog.confirm');

  @override
  void dispose() {
    _cancel.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        TvFocus(
          focusNode: _cancel,
          // 默认落在「取消」：破坏性操作必须多一步才能执行。
          autofocus: true,
          debugLabel: 'dialog.cancel',
          onPressed: widget.onCancel,
          nextRight: _confirm,
          builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
            status: s,
            radius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
            baseColor: const Color(0x26FFFFFF),
            child: Text(
              widget.cancelLabel,
              style: const TextStyle(fontSize: 18, color: TvColors.text),
            ),
          ),
        ),
        const SizedBox(width: 14),
        TvFocus(
          focusNode: _confirm,
          debugLabel: 'dialog.confirm',
          onPressed: widget.onConfirm,
          nextLeft: _cancel,
          builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
            status: s,
            radius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
            baseColor: widget.danger
                ? const Color(0xFFB3261E)
                : const Color(0xFF2F5FBF),
            child: Text(
              widget.confirmLabel,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
