import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

/// [TvFocus] 的焦点状态。
class TvFocusStatus {
  /// 当前是否持有焦点（决定是否画焦点环）。
  final bool focused;

  /// 是否正处于「按下」态（OK/Enter 已按下、尚未抬起）。
  ///
  /// 刻意与 [focused] 分开：电视端必须能区分
  /// 「焦点停在这里」「焦点停在这里并且我按下去了」两种状态，
  /// 否则用户按了 OK 却没有任何瞬时反馈，会以为遥控器失灵。
  final bool pressed;

  const TvFocusStatus({required this.focused, required this.pressed});

  static const TvFocusStatus idle =
      TvFocusStatus(focused: false, pressed: false);
}

typedef TvFocusBuilder = Widget Function(BuildContext context, TvFocusStatus s);

/// 电视端可聚焦单元 —— **本项目所有可获焦控件的唯一基元**。
///
/// ## 为什么不能用 `ElevatedButton` / `ListTile` / `InkWell`
///
/// 真实故障：播放页的「上一首 / 播放暂停 / 下一首」在遥控器上**既选不中、
/// 又没有焦点反馈**。根因是这类 Material 控件内部各自持有一个 `FocusNode`，
/// 而旧代码在它外面又套了一层 `Focus(focusNode: 自己的节点)`：
///
/// - 焦点若落在**外层**节点上 → 视觉高亮出现了，但按 OK 什么都不会发生
///   （外层节点上没有 `onPressed`）；
/// - 焦点若落在**按钮内部**节点上 → 按 OK 能生效，但外层拿不到
///   `hasFocus`，于是**没有任何视觉反馈**。
///
/// 两个节点谁被选中取决于遍历顺序，表现就是「时好时坏、随机失灵」。
///
/// [TvFocus] 因此只创建**一个** `FocusNode`，把「焦点移动、OK 激活、按下态」
/// 全都在同一个节点上处理，从结构上消灭这类冲突。
///
/// ## 显式焦点链
/// 四个方向都可以指定**明确的目标节点**（[nextUp] / [nextDown] /
/// [nextLeft] / [nextRight]），命中即直接 `requestFocus`，完全不依赖
/// Flutter 的「就近寻找」启发式。
///
/// 某个方向**不指定**时返回 `KeyEventResult.ignored`，交回框架的
/// `DirectionalFocusIntent` 做默认遍历 —— 列表这类「数量不定、位置滑动」
/// 的场景交给框架反而更稳，而关键路径（播放页三层）一律显式指定。
///
/// ## 方向键的两种语义
/// - 传 [nextXxx]：该方向键 = **移动焦点**；
/// - 传 [onArrowXxx]：该方向键 = **执行动作**（用于进度区的左右键 = 快退/快进）。
///
/// 两者都不传则交回框架。绝不会出现「按了没反应」。
class TvFocus extends StatefulWidget {
  const TvFocus({
    super.key,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = true,
    this.onPressed,
    this.onFocusChange,
    this.nextUp,
    this.nextDown,
    this.nextLeft,
    this.nextRight,
    this.onArrowUp,
    this.onArrowDown,
    this.onArrowLeft,
    this.onArrowRight,
    this.debugLabel,
    required this.builder,
  });

  /// 外部节点。传了就用它（便于把多个控件的焦点链串起来），
  /// 此时本组件**不负责 dispose**。
  final FocusNode? focusNode;

  final bool autofocus;
  final bool canRequestFocus;

  /// OK / Enter / DPAD_CENTER / 空格 触发。
  final VoidCallback? onPressed;

  final ValueChanged<bool>? onFocusChange;

  final FocusNode? nextUp;
  final FocusNode? nextDown;
  final FocusNode? nextLeft;
  final FocusNode? nextRight;

  /// 方向键的「执行动作」语义（优先级高于 [nextXxx]）。
  final VoidCallback? onArrowUp;
  final VoidCallback? onArrowDown;
  final VoidCallback? onArrowLeft;
  final VoidCallback? onArrowRight;

  final String? debugLabel;

  final TvFocusBuilder builder;

  @override
  State<TvFocus> createState() => _TvFocusState();
}

class _TvFocusState extends State<TvFocus> {
  /// 自建节点（`widget.focusNode == null` 时才存在，且由本 State 释放）。
  FocusNode? _ownNode;

  late FocusNode _node;

  bool _focused = false;
  bool _pressed = false;

  /// 按下态的自动复位。物理按键的 KeyUp 在某些电视 ROM 上会丢，
  /// 只靠 KeyUp 复位会让按钮永久停在「按下」的样子。
  Timer? _pressTimer;

  static const Duration _pressVisualHold = Duration(milliseconds: 240);

  /// 触发「激活」的按键。
  ///
  /// Android TV 遥控器的 OK 键在 Flutter 里会映射成 `select`，
  /// 但也有 ROM 上报 `enter` / `gameButtonA`，因此全部收下。
  static const List<LogicalKeyboardKey> _selectKeys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.space,
  ];

  static bool _isSelectKey(LogicalKeyboardKey key) =>
      _selectKeys.contains(key);

  FocusNode get _resolved =>
      widget.focusNode ??
      (_ownNode ??= FocusNode(debugLabel: widget.debugLabel ?? 'TvFocus'));

  @override
  void initState() {
    super.initState();
    _node = _resolved;
    _node.addListener(_onFocusChanged);
    _focused = _node.hasFocus;
  }

  @override
  void didUpdateWidget(covariant TvFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      _node.removeListener(_onFocusChanged);
      // 外部节点接管后，自建的那个就没用了（不释放会泄漏）。
      if (oldWidget.focusNode == null) {
        _ownNode?.dispose();
        _ownNode = null;
      }
      _node = _resolved;
      _node.addListener(_onFocusChanged);
      _focused = _node.hasFocus;
    }
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    _node.removeListener(_onFocusChanged);
    // ⚠️ 只释放自己建的节点：外部传入的节点所有权在调用方
    //    （重复 dispose 会抛异常，是 V2 §29 明确列出的泄漏检查项）。
    _ownNode?.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    final now = _node.hasFocus;
    if (now == _focused) return;
    setState(() {
      _focused = now;
      if (!now) _pressed = false;
    });
    widget.onFocusChange?.call(now);
  }

  void _markPressed() {
    _pressTimer?.cancel();
    if (!_pressed && mounted) {
      setState(() => _pressed = true);
    }
    _pressTimer = Timer(_pressVisualHold, _clearPressed);
  }

  void _clearPressed() {
    _pressTimer?.cancel();
    _pressTimer = null;
    if (_pressed && mounted) {
      setState(() => _pressed = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      if (_isSelectKey(event.logicalKey)) {
        _clearPressed();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final LogicalKeyboardKey key = event.logicalKey;

    if (_isSelectKey(key)) {
      if (event is KeyDownEvent) _markPressed();
      // KeyRepeatEvent 也会进来：长按 OK 在快退/快进按钮上 = 连续 seek。
      widget.onPressed?.call();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      return _dispatch(widget.onArrowUp, widget.nextUp);
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      return _dispatch(widget.onArrowDown, widget.nextDown);
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      return _dispatch(widget.onArrowLeft, widget.nextLeft);
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      return _dispatch(widget.onArrowRight, widget.nextRight);
    }
    return KeyEventResult.ignored;
  }

  /// 执行方向键：优先「动作」，其次「移动焦点」，都没有则交回框架。
  KeyEventResult _dispatch(VoidCallback? action, FocusNode? target) {
    if (action != null) {
      action();
      return KeyEventResult.handled;
    }
    final t = target;
    if (t != null) {
      if (t.canRequestFocus) {
        t.requestFocus();
        return KeyEventResult.handled;
      }
      // 目标此刻不可获焦（例如被 ExcludeFocus 挡住）→ 交回框架兜底，
      // **绝不允许**「按键被吃掉但没有反应」这种死区。
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      canRequestFocus: widget.canRequestFocus,
      onKeyEvent: _onKey,
      child: Builder(
        builder: (BuildContext ctx) => widget.builder(
          ctx,
          TvFocusStatus(focused: _focused, pressed: _pressed),
        ),
      ),
    );
  }
}

/// 统一的焦点视觉：**描边 + 底色**，并且描边画在控件自身范围内。
///
/// ## 为什么要抽出来
/// 电视端「看不清焦点在哪」是最高频的投诉。四散在各页面手写描边，
/// 必然出现「这个页面 2px、那个页面 4px」「这里用 hover 色、那里用 pressed 色」
/// 的不一致。
///
/// ## 为什么不用 scale 放大
/// `Transform.scale` 会**溢出父容器**，被 `ListView` / `ClipRRect` 裁掉一半，
/// 或者把相邻控件挤变形（真实踩坑）。这里改用「描边 + 底色 + 轻微外发光」：
/// 描边由 `BoxDecoration.border` 绘制，**完全落在自身 bounds 内**，
/// 任何父级裁切都不会吃掉它。
///
/// 未聚焦时也保留同宽度的透明描边，避免聚焦/失焦时布局跳动。
class TvFocusRing extends StatelessWidget {
  const TvFocusRing({
    super.key,
    required this.status,
    required this.child,
    this.radius = 12,
    this.baseColor = Colors.transparent,
    this.width,
    this.height,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.focusColor = TvColors.focusFill,
    this.pressedColor = TvColors.pressedFill,
    this.ringColor = TvColors.focusRing,
    this.ringWidth = 3,
  });

  final TvFocusStatus status;
  final Widget child;
  final double radius;
  final Color baseColor;

  /// 显式宽度。**默认 null = 由父约束决定**。
  ///
  /// ⚠️ 千万不要默认 `double.infinity`：放在 `Row` 的非弹性子项位置时，
  /// 父约束的 maxWidth 是 infinity，再叠一个 infinite 宽度会直接抛
  /// 「BoxConstraints forces an infinite width」。
  /// 需要撑满的场景（`Expanded`、`CrossAxisAlignment.stretch`）本来就给了
  /// 紧约束，不写宽度也会自动撑满。
  final double? width;

  final double? height;
  final EdgeInsetsGeometry padding;
  final Color focusColor;
  final Color pressedColor;
  final Color ringColor;
  final double ringWidth;

  @override
  Widget build(BuildContext context) {
    final focused = status.focused;
    final pressed = status.pressed;

    final Color fill = pressed
        ? pressedColor
        : (focused ? focusColor : baseColor);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: focused ? ringColor : Colors.transparent,
          width: ringWidth,
        ),
        boxShadow: focused
            ? <BoxShadow>[
                BoxShadow(
                  color: ringColor.withValues(alpha: 0.30),
                  blurRadius: 14,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}
