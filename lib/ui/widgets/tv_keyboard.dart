import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'tv_focus.dart';
import 'tv_glass.dart';

/// 屏幕键盘上的一颗按键。
class TvKeySpec {
  /// 键面显示的文字（动作键用图标/文字符号）。
  final String label;

  /// 按 OK 时插入的字符；null 表示这是一颗动作键。
  final String? insert;

  /// 动作类型（[insert] 为 null 时生效）。
  final TvKeyAction action;

  /// 诊断/测试用的稳定标识（如 `tvkbd.a`、`tvkbd.bsp`）。
  final String id;

  /// 在行内的宽度权重（普通键 = 1，宽键更大）。
  final int flex;

  const TvKeySpec.char(this.id, this.label, {this.flex = 1})
      : insert = label,
        action = TvKeyAction.none;

  const TvKeySpec.action(this.id, this.label, this.action, {this.flex = 1})
      : insert = null;
}

/// 动作键的语义。
enum TvKeyAction { none, backspace, space, clear, shift, obscure, done }

/// **应用内遥控器屏幕键盘**（备用输入通道）。
///
/// ## 为什么必须有它（真实故障，小米电视 S Pro 2025）
///
/// 用户实测：登录页能选中输入框，但按 OK **系统软键盘不弹出**，
/// 于是 NAS 地址 / 用户名 / 密码一个都输不进去 —— 完全无法登录。
///
/// 系统输入法是否弹出**不由 App 决定**（取决于电视 ROM 的 IME 是否存在、
/// 是否被禁用、是否愿意为不可触屏设备显示）。因此这里提供一条
/// **完全自持的实现**：D-pad 移动、OK 输入、Back 关闭，
/// 不依赖任何系统输入法。
///
/// ## 焦点
/// 全部按键用 [TvFocus]，焦点链**显式**指定（左右同行、上下相邻行同列），
/// 行首/行尾/首行/末行原地不动 —— 与项目其它页面同一套规则。
/// 打开键盘时页面其它部分应被 `ExcludeFocus` 排除，避免方向键跑到表单上。
class TvKeyboard extends StatefulWidget {
  const TvKeyboard({
    super.key,
    required this.controller,
    required this.fieldLabel,
    required this.onClose,
    this.onAdvance,
    this.onRetreat,
    this.obscure = false,
    this.onObscureChanged,
    this.returnFocus,
  });

  /// 当前正在编辑的字段控制器（键盘直接写它，不持有副本）。
  final TextEditingController controller;

  /// 当前编辑的字段名（显示在键盘顶部，避免用户不知道在改哪一栏）。
  final String fieldLabel;

  /// 「完成 / 关闭」：调用方负责关掉键盘并把焦点还给字段。
  final VoidCallback onClose;

  /// **完成并前进**：末行按 ↓ 或按「完成」键时触发。
  ///
  /// 这是「输入完密码出不去」那条实机 Bug 的正面解法：
  /// 键盘是**模态**的（打开时表单被 `ExcludeFocus` 排除），用户在键盘上按 ↓
  /// 只会在键盘内部移动，走到末行就原地不动 —— 从用户视角就是「下不去」。
  /// 因此末行 ↓ 必须**等于「我输完了，继续往下」**，而不是「到底了」。
  ///
  /// 为 null 时退化为 [onClose]（保持旧行为，也让只测键盘的用例不必关心它）。
  final VoidCallback? onAdvance;

  /// **向上退出**：首行按 ↑ 时触发（回到上一个字段）。
  ///
  /// 与 [onAdvance] 对称：首行 ↑ 本来也是「原地不动」的死区。
  final VoidCallback? onRetreat;

  /// 是否密码字段（初始是否掩码）。
  final bool obscure;

  /// 掩码开关变化（调用方同步给自己的 TextField）。
  final ValueChanged<bool>? onObscureChanged;

  /// 关闭后要还焦点的节点（由键盘在关闭前显式 `requestFocus`）。
  final FocusNode? returnFocus;

  @override
  State<TvKeyboard> createState() => TvKeyboardState();
}

class TvKeyboardState extends State<TvKeyboard> {
  /// 键盘布局：行 × 键。数字行放在最上，方便输入 IP / 端口。
  static const List<List<TvKeySpec>> _rows = <List<TvKeySpec>>[
    <TvKeySpec>[
      TvKeySpec.char('1', '1'),
      TvKeySpec.char('2', '2'),
      TvKeySpec.char('3', '3'),
      TvKeySpec.char('4', '4'),
      TvKeySpec.char('5', '5'),
      TvKeySpec.char('6', '6'),
      TvKeySpec.char('7', '7'),
      TvKeySpec.char('8', '8'),
      TvKeySpec.char('9', '9'),
      TvKeySpec.char('0', '0'),
    ],
    <TvKeySpec>[
      TvKeySpec.char('q', 'q'),
      TvKeySpec.char('w', 'w'),
      TvKeySpec.char('e', 'e'),
      TvKeySpec.char('r', 'r'),
      TvKeySpec.char('t', 't'),
      TvKeySpec.char('y', 'y'),
      TvKeySpec.char('u', 'u'),
      TvKeySpec.char('i', 'i'),
      TvKeySpec.char('o', 'o'),
      TvKeySpec.char('p', 'p'),
    ],
    <TvKeySpec>[
      TvKeySpec.char('a', 'a'),
      TvKeySpec.char('s', 's'),
      TvKeySpec.char('d', 'd'),
      TvKeySpec.char('f', 'f'),
      TvKeySpec.char('g', 'g'),
      TvKeySpec.char('h', 'h'),
      TvKeySpec.char('j', 'j'),
      TvKeySpec.char('k', 'k'),
      TvKeySpec.char('l', 'l'),
    ],
    <TvKeySpec>[
      TvKeySpec.action('shift', 'Aa', TvKeyAction.shift),
      TvKeySpec.char('z', 'z'),
      TvKeySpec.char('x', 'x'),
      TvKeySpec.char('c', 'c'),
      TvKeySpec.char('v', 'v'),
      TvKeySpec.char('b', 'b'),
      TvKeySpec.char('n', 'n'),
      TvKeySpec.char('m', 'm'),
      TvKeySpec.action('bsp', '⌫', TvKeyAction.backspace),
    ],
    <TvKeySpec>[
      TvKeySpec.char('dot', '.'),
      TvKeySpec.char('colon', ':'),
      TvKeySpec.char('dash', '-'),
      TvKeySpec.char('under', '_'),
      TvKeySpec.char('slash', '/'),
      TvKeySpec.char('at', '@'),
      TvKeySpec.char('star', '*'),
      TvKeySpec.char('dollar', r'$'),
    ],
    <TvKeySpec>[
      TvKeySpec.action('space', '空格', TvKeyAction.space, flex: 3),
      TvKeySpec.action('clear', '清空', TvKeyAction.clear, flex: 2),
      TvKeySpec.action('obscure', '显示', TvKeyAction.obscure, flex: 2),
      TvKeySpec.action('done', '完成', TvKeyAction.done, flex: 2),
    ],
  ];

  /// 每颗键的焦点节点（与 [_rows] 同形）。
  late List<List<FocusNode>> _nodes;

  /// 大写锁定（影响字母键插入的字符）。
  bool _shift = false;

  /// 当前是否掩码显示（回显行用）。
  bool _obscure = false;

  @override
  void initState() {
    super.initState();
    _obscure = widget.obscure;
    _nodes = <List<FocusNode>>[
      for (int r = 0; r < _rows.length; r++)
        <FocusNode>[
          for (final TvKeySpec k in _rows[r])
            FocusNode(debugLabel: 'tvkbd.${k.id}'),
        ],
    ];
    // 键盘控制器变化时刷新回显（删除/清空都要反映出来）。
    widget.controller.addListener(_onTextChanged);
    // ⚠️ 显式 requestFocus（本项目 `autofocus` 在电视 ROM 上不可靠）：
    //    第一行第一个键（数字 1）。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _nodes[0][0].requestFocus();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    for (final List<FocusNode> row in _nodes) {
      for (final FocusNode n in row) {
        n.dispose();
      }
    }
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  // ── 输入 ─────────────────────────────────────────────────

  /// 在当前光标处插入文本（光标落后；越界自动收敛，绝不抛异常）。
  void _insert(String s) {
    final TextEditingController c = widget.controller;
    final String text = c.text;
    int at = c.selection.isValid ? c.selection.end : text.length;
    at = at.clamp(0, text.length);
    final String next = text.substring(0, at) + s + text.substring(at);
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at + s.length),
    );
    setState(() {});
  }

  void _backspace() {
    final TextEditingController c = widget.controller;
    final String text = c.text;
    int at = c.selection.isValid ? c.selection.end : text.length;
    at = at.clamp(0, text.length);
    if (at == 0) return;
    final String next = text.substring(0, at - 1) + text.substring(at);
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at - 1),
    );
    setState(() {});
  }

  void _clear() {
    widget.controller.value = const TextEditingValue(
      text: '',
      selection: TextSelection.collapsed(offset: 0),
    );
    setState(() {});
  }

  /// 执行一颗按键。
  ///
  /// ⚠️ 每个分支显式 `return`：不依赖「非空 case 隐式 break」这类语言版本敏感的写法。
  void _activate(TvKeySpec key) {
    switch (key.action) {
      case TvKeyAction.backspace:
        _backspace();
        return;
      case TvKeyAction.space:
        _insert(' ');
        return;
      case TvKeyAction.clear:
        _clear();
        return;
      case TvKeyAction.shift:
        setState(() => _shift = !_shift);
        return;
      case TvKeyAction.obscure:
        setState(() => _obscure = !_obscure);
        widget.onObscureChanged?.call(_obscure);
        return;
      case TvKeyAction.done:
        _advance();
        return;
      case TvKeyAction.none:
        final String? ins = key.insert;
        if (ins != null) _insert(_shift ? ins.toUpperCase() : ins);
        return;
    }
  }

  /// 「完成」：收起键盘并**前进到下一个控件**（不是回到刚编辑的字段）。
  ///
  /// 语义差别就是本轮 Bug 的核心 —— 用户输完密码按「完成」，期望的是
  /// 「键盘没了、我接着去按记住密码」，而不是「键盘没了、焦点还赖在密码框上」。
  ///
  /// 顺序很重要：先把焦点还给调用方指定的节点再回调，因为本组件随后就会被
  /// 卸载（`_keyboardOpen = false`），卸载后再请求焦点会掉到 FocusScope 上
  /// （表现是「方向键全失灵」）。
  ///
  /// ⚠️ [widget.onAdvance] 为 null 时退化为 [widget.onClose]：单测里只关心
  ///   「完成会关掉键盘」的场景不必额外传参。
  void _advance() {
    widget.returnFocus?.requestFocus();
    final VoidCallback? advance = widget.onAdvance;
    if (advance == null) {
      widget.onClose();
      return;
    }
    advance();
  }

  // ── 渲染 ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // ⚠️ 键高必须**由可用高度反推**，不能写死：
    //    小逻辑视口（例如 1080p 面板 dpr=2.0 ⇒ 540 逻辑高）下键盘只分到 ~335px，
    //    6 行写死 44px 会直接 RenderFlex 溢出（release 下静默裁切 = 末行「完成」看不见）。
    //
    // ⚠️ 顶栏高度也要**写死**（而不是靠内容自然撑开）：只要有一项是自然高度，
    //    「可用高度 - 非行内容」的估算就会随字体缩放漂移，估算偏小即溢出。
    //    这里顶栏 = 单行文字高度（随 textScaler）+ 6px 余量，其余按精确值扣减。
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double headerHeight = scaler.scale(18) + 6;

    return TvGlass(
      radius: 14,
      tint: const Color(0xF2101115),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          // 非行内容（相对 LayoutBuilder 的可用高度）：
          //   我的 Padding 上下 22
          //   + 顶栏下间距 8
          //   + 5 个行间距 30
          //   + **6 行 × 描边 3px × 2 = 36**
          //   + 6px 富余（行盒向上取整）
          //
          // ⚠️ 那 36px 是必须算的：`TvFocusRing` 用 `AnimatedContainer` 画
          //    `Border.all(width: 3)`，而 `BoxDecoration.padding`（= 描边宽度）
          //    会被 Container **加**到显式 padding 上 ⇒ 每颗键实际高度 =
          //    键高 + 6。漏算它的后果就是 CI 里连续两轮 RenderFlex 溢出
          //    （第一轮缺 22px、第二轮缺 28px），且只在布局断言里看得见。
          const double fixed = 22 + 8 + 30 + 36 + 6;
          final double available = c.hasBoundedHeight ? c.maxHeight : 400;
          final double keyHeight = ((available - headerHeight - fixed) /
                  _rows.length)
              .clamp(26.0, 46.0);
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(height: headerHeight, child: _buildHeader()),
                const SizedBox(height: 8),
                for (int r = 0; r < _rows.length; r++) ...<Widget>[
                  _buildRow(r, keyHeight),
                  if (r != _rows.length - 1) const SizedBox(height: 6),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// 顶部：当前编辑字段 + 回显（掩码时用 `•`）。
  ///
  /// 电视上没有 adb，用户需要能**在屏幕上**确认「我在改哪一栏、已经输进去了什么」。
  Widget _buildHeader() {
    final String text = widget.controller.text;
    final String shown =
        _obscure ? ('•' * text.runes.length) : (text.isEmpty ? '（空）' : text);
    return Row(
      children: <Widget>[
        Text(
          '正在编辑：${widget.fieldLabel}',
          style: const TextStyle(
            fontSize: 15,
            height: 1.2,
            fontWeight: FontWeight.w700,
            color: TvColors.text,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            shown,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              height: 1.2,
              color: Color(0xB3FFFFFF),
            ),
          ),
        ),
        // 「↓ 继续」：末行 ↓ 能退出键盘这件事**必须写在脸上**。
        //
        // 用户在键盘上按到末行发现 ↓ 没反应，会直接断定「按键坏了」；
        // 而这条出口本身是隐藏交互（键盘是模态的，没有别的地方能看到它）。
        if (widget.onAdvance != null)
          const Padding(
            padding: EdgeInsets.only(left: 10),
            child: Text(
              '↓ 继续',
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: TvColors.focusRing,
              ),
            ),
          ),
        Text(
          _shift ? '大写' : '小写',
          style: const TextStyle(
            fontSize: 13,
            height: 1.2,
            color: TvColors.textFaint,
          ),
        ),
      ],
    );
  }

  Widget _buildRow(int r, double keyHeight) {
    return Row(
      children: <Widget>[
        for (int c = 0; c < _rows[r].length; c++) ...<Widget>[
          if (c != 0) const SizedBox(width: 6),
          Expanded(
            flex: _rows[r][c].flex,
            child: _buildKey(r, c, keyHeight),
          ),
        ],
      ],
    );
  }

  Widget _buildKey(int r, int c, double keyHeight) {
    final TvKeySpec key = _rows[r][c];
    final FocusNode node = _nodes[r][c];
    final bool isPlainChar = key.action == TvKeyAction.none;
    final String cap = isPlainChar && _shift && key.insert != null
        ? key.insert!.toUpperCase()
        : key.label;
    final bool highlight = key.action == TvKeyAction.shift && _shift;

    // 首行 ↑ / 末行 ↓ = 退出键盘。
    //
    // ⚠️ 这是**死区转出口**：原来这两个方向都被显式指回自身（「原地不动」），
    //    用户在末行按 ↓ 什么都不会发生 —— 而这正是「输入完密码下不去」的
    //    实机表现。键盘是模态的，不给出路就等于把焦点锁死在键盘里。
    final bool isFirstRow = r == 0;
    final bool isLastRow = r == _rows.length - 1;

    return TvFocus(
      focusNode: node,
      debugLabel: 'tvkbd.${key.id}',
      onPressed: () => _activate(key),
      onArrowUp: isFirstRow ? widget.onRetreat : null,
      onArrowDown: isLastRow ? widget.onAdvance : null,
      nextLeft: c > 0 ? _nodes[r][c - 1] : node,
      nextRight: c < _rows[r].length - 1 ? _nodes[r][c + 1] : node,
      nextUp: r > 0 ? _nodes[r - 1][c.clamp(0, _rows[r - 1].length - 1)] : node,
      nextDown:
          r < _rows.length - 1 ? _nodes[r + 1][c.clamp(0, _rows[r + 1].length - 1)] : node,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 9,
        padding: EdgeInsets.zero,
        child: Container(
          height: keyHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: highlight ? const Color(0x66FFFFFF) : const Color(0x1FFFFFFF),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            cap,
            maxLines: 1,
            style: const TextStyle(
              fontSize: 17,
              height: 1.2,
              color: TvColors.text,
            ),
          ),
        ),
      ),
    );
  }
}
