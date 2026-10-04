import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/branding.dart';
import '../../core/log.dart';
import 'tv_confirm_dialog.dart';
import 'tv_focus.dart';
import 'tv_glass.dart';

/// 左侧导航项定义。
class NavRailItem {
  final IconData icon;
  final String label;

  const NavRailItem({required this.icon, required this.label});
}

/// 左侧主导航。
///
/// ## 布局：导航项可滚动，退出登录**固定在底部**
///
/// 旧实现把「logo + 7 个导航项 + 退出登录」塞进一个 `Column`，
/// 中间用 `Spacer()` 撑开。一旦内容总高超过可视高度（电视上很常见：
/// 大字号 + 系统栏 + 电视本身的 overscan 会吃掉四周 ~5%），
/// `Column` 直接溢出，**底部的退出登录被裁在屏幕外**，
/// 用户根本点不到 —— 这就是「退出登录显示不完整」的根因。
///
/// 现在拆成三段：
/// `logo` / `Expanded(可滚动导航列表)` / `底部固定区(分割线 + 退出登录 + 留白)`。
/// 导航项再多也只是内部滚动，退出登录永远完整可见；
/// 底部额外留 14px，专门给电视 overscan。
///
/// ## 焦点链
/// 导航项之间**竖直方向显式串联**（首页 → … → 退出登录，反之亦然）；
/// 左右方向交回框架 —— 向右自然进入内容区，这是电视用户最容易理解的路径。
///
/// ## 模糊
/// 侧栏**不做背景模糊**：它占了约 1/5 屏幕面积，而背后是纯色/渐变背景，
/// 模糊几乎看不出差别却要付出全屏 1/5 面积的高斯模糊开销。
/// 这里用同一套半透明玻璃色（观感一致），把模糊预算留给
/// 顶栏、迷你播放器、弹窗这些**面积小、层次感收益大**的地方。
class NavRail extends StatelessWidget {
  const NavRail({
    super.key,
    required this.items,
    required this.selected,
    required this.nodes,
    required this.logoutNode,
    required this.diagnosticsNode,
    required this.remoteNode,
    required this.exitNode,
    required this.onSelected,
    required this.onLogout,
    required this.onDiagnostics,
    required this.onRemote,
    required this.onExit,
    this.width = 206,
  });

  final List<NavRailItem> items;
  final int selected;

  /// 每个导航项对应的焦点节点（由 Shell 创建并释放，便于跨区串联）。
  final List<FocusNode> nodes;

  final FocusNode logoutNode;

  /// 「诊断与帮助」入口的焦点节点（V5）。
  final FocusNode diagnosticsNode;

  /// 「手机遥控」入口的焦点节点（V5 §七）。
  final FocusNode remoteNode;

  /// 「返回桌面」入口的焦点节点（V5 补充任务）。
  final FocusNode exitNode;

  final ValueChanged<int> onSelected;
  final VoidCallback onLogout;

  /// 打开诊断与帮助页（技术细节的唯一入口）。
  final VoidCallback onDiagnostics;

  /// 打开手机遥控页。
  final VoidCallback onRemote;

  /// 弹出「后台继续 / 退出并停止 / 取消」三选弹窗。
  final VoidCallback onExit;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TvGlass(
        radius: 0,
        blur: false,
        showBorder: false,
        shadow: false,
        tint: TvColors.sidebar.withValues(alpha: 0.82),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _RailLogo(),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                // ⚠️ V5：底部留 10px。焦点环是 `TvFocusRing` 画的
                //    **3px 描边 + 14px 外发光**，它们绘制在控件自身 bounds
                //    之外；视图口贴着最后一项时，外发光会被裁掉一半，
                //    实机（图6）看起来就是「最近这一项的焦点框被下面切了」。
                //    留出边距后，滚到最底时整个焦点环都在可视区内。
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                itemCount: items.length,
                itemBuilder: (BuildContext context, int i) => _NavTile(
                  item: items[i],
                  selected: i == selected,
                  node: nodes[i],
                  // 显式上下串联：任何一项都能一路走到最底 / 最顶，中间不会卡住。
                  nextUp: i > 0 ? nodes[i - 1] : null,
                  nextDown: i < items.length - 1 ? nodes[i + 1] : logoutNode,
                  onPressed: () => onSelected(i),
                ),
              ),
            ),
            const Divider(height: 1, color: TvColors.glassLine),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _LogoutTile(
                    node: logoutNode,
                    onLogout: onLogout,
                    // 焦点链：底部固定区自上而下为
                    // 退出登录 → 手机遥控 → 诊断与帮助（首尾相接）。
                    nextDown: remoteNode,
                    nextUp: items.isNotEmpty ? nodes[items.length - 1] : null,
                  ),
                  const SizedBox(height: 2),
                  _RemoteTile(
                    node: remoteNode,
                    onOpen: onRemote,
                    nextUp: logoutNode,
                    nextDown: diagnosticsNode,
                  ),
                  const SizedBox(height: 2),
                  _DiagnosticsTile(
                    node: diagnosticsNode,
                    onOpen: onDiagnostics,
                    nextUp: remoteNode,
                    nextDown: exitNode,
                  ),
                  const SizedBox(height: 2),
                  _ExitTile(
                    node: exitNode,
                    onExit: onExit,
                    nextUp: diagnosticsNode,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailLogo extends StatelessWidget {
  const _RailLogo();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Row(
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              color: TvColors.brand,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.music_note, size: 18, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const Text(
            kAppName,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: TvColors.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个导航项。
class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.item,
    required this.selected,
    required this.node,
    required this.nextUp,
    required this.nextDown,
    required this.onPressed,
  });

  final NavRailItem item;
  final bool selected;
  final FocusNode node;
  final FocusNode? nextUp;
  final FocusNode? nextDown;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: TvFocus(
        focusNode: node,
        debugLabel: 'nav.${item.label}',
        onPressed: onPressed,
        nextUp: nextUp,
        nextDown: nextDown,
        builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
          status: s,
          radius: 10,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          // 选中项用底色区分（与参考图一致），焦点另有描边，两者互不干扰。
          baseColor: selected ? TvColors.panelHi : Colors.transparent,
          child: Row(
            children: <Widget>[
              Icon(
                item.icon,
                size: 20,
                // 选中项图标用强调色，一眼看出「现在在哪一页」
                color: selected ? TvColors.accent : TvColors.textDim,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? TvColors.text : TvColors.textDim,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 退出登录。
///
/// ## 两段式确认
/// 第一次 OK **不**直接登出，而是弹出一个居中的确认弹窗
/// （默认焦点在「取消」上）。破坏性操作绝不一步执行 ——
/// 电视遥控器很容易误触，误登出意味着要重输服务器地址与账号密码。
///
/// 取消后焦点**回到本按钮**，用户不会「找不到自己在哪」。
///
/// ⚠️ 弹窗用 `showDialog` 承载，所以 BACK 由 Navigator 优先关闭弹窗，
/// 不会穿透到底下 Shell 的 `PopScope` 去执行「回首页」。
class _LogoutTile extends StatelessWidget {
  const _LogoutTile({
    required this.node,
    required this.onLogout,
    this.nextUp,
    this.nextDown,
  });

  final FocusNode node;
  final VoidCallback onLogout;
  final FocusNode? nextUp;
  final FocusNode? nextDown;

  Future<void> _confirm(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => const TvConfirmDialog(
        title: '退出登录',
        message: '退出后需要重新输入服务器地址与账号密码。\n\n'
            '本机的「最近播放」「收藏」「风格确认」与播放偏好**不会**被清除。',
        confirmLabel: '退出登录',
        cancelLabel: '取消',
      ),
    );
    if (!context.mounted) return;
    if (ok == true) {
      Log.i('UI 退出登录（已确认）');
      onLogout();
    } else {
      // 取消 → 焦点回原位。
      node.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: node,
      debugLabel: 'nav.logout',
      onPressed: () => _confirm(context),
      nextUp: nextUp,
      nextDown: nextDown,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: const Row(
          children: <Widget>[
            Icon(Icons.logout, size: 20, color: TvColors.textFaint),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '退出登录',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, color: TvColors.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「手机遥控」入口（V5 §七）。
///
/// 放在侧栏底部（与退出登录、诊断并列）而不是主导航里：
/// 它不是「一个内容页」，而是「让另一台设备接管控制」的设备级操作，
/// 与「退出登录」同类。
class _RemoteTile extends StatelessWidget {
  const _RemoteTile({
    required this.node,
    required this.onOpen,
    this.nextUp,
    this.nextDown,
  });

  final FocusNode node;
  final VoidCallback onOpen;
  final FocusNode? nextUp;
  final FocusNode? nextDown;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: node,
      debugLabel: 'nav.remote',
      onPressed: onOpen,
      nextUp: nextUp,
      nextDown: nextDown,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: const Row(
          children: <Widget>[
            Icon(Icons.smartphone, size: 19, color: TvColors.textFaint),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '手机遥控',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: TvColors.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「返回桌面」入口（V5 补充任务）。
///
/// 打开「后台继续 / 退出并停止 / 取消」三选弹窗 ——
/// 与「退出登录」并列放底部：它是设备级操作，不是内容页。
/// 系统 Home 键由电视 Launcher 处理、应用收不到，这是 App 内
/// 唯一明确的「离开」入口（另一个是首页按返回键）。
class _ExitTile extends StatelessWidget {
  const _ExitTile({
    required this.node,
    required this.onExit,
    this.nextUp,
  });

  final FocusNode node;
  final VoidCallback onExit;
  final FocusNode? nextUp;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: node,
      debugLabel: 'nav.exit',
      onPressed: onExit,
      nextUp: nextUp,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: const Row(
          children: <Widget>[
            Icon(Icons.exit_to_app, size: 19, color: TvColors.textFaint),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '返回桌面',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: TvColors.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「诊断与帮助」入口（V5）。
///
/// 需求 §一.4 / §二.3 要求「原始异常、堆栈、版本、请求地址、初始化阶段等
/// 写入日志或**专门诊断入口**，正常用户流程只显示简短且可操作的提示」。
/// 这就是那个「专门入口」：侧栏最底部、与「退出登录」并列，
/// 正常使用时完全不起眼，需要取证时一按就到。
class _DiagnosticsTile extends StatelessWidget {
  const _DiagnosticsTile({
    required this.node,
    required this.onOpen,
    this.nextUp,
    this.nextDown,
  });

  final FocusNode node;
  final VoidCallback onOpen;
  final FocusNode? nextUp;
  final FocusNode? nextDown;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: node,
      debugLabel: 'nav.diagnostics',
      onPressed: onOpen,
      nextUp: nextUp,
      nextDown: nextDown,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: const Row(
          children: <Widget>[
            Icon(Icons.help_outline, size: 19, color: TvColors.textFaint),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '诊断与帮助',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: TvColors.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
