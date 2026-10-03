import 'package:flutter/material.dart';

import '../../app/theme.dart';
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
    required this.onSelected,
    required this.onLogout,
    this.width = 226,
  });

  final List<NavRailItem> items;
  final int selected;

  /// 每个导航项对应的焦点节点（由 Shell 创建并释放，便于跨区串联）。
  final List<FocusNode> nodes;

  final FocusNode logoutNode;

  final ValueChanged<int> onSelected;
  final VoidCallback onLogout;
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
            const SizedBox(height: 14),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
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
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
              child: _LogoutTile(node: logoutNode, onLogout: onLogout),
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
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              color: TvColors.brand,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.music_note, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 12),
          const Text(
            '飞牛音乐',
            style: TextStyle(
              fontSize: 21,
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
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: TvFocus(
        focusNode: node,
        debugLabel: 'nav.${item.label}',
        onPressed: onPressed,
        nextUp: nextUp,
        nextDown: nextDown,
        builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
          status: s,
          radius: 10,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          // 选中项用底色区分（与参考图一致），焦点另有描边，两者互不干扰。
          baseColor: selected ? TvColors.panelHi : Colors.transparent,
          child: Row(
            children: <Widget>[
              Icon(
                item.icon,
                size: 22,
                // 选中项图标用强调色，一眼看出「现在在哪一页」
                color: selected ? TvColors.accent : TvColors.textDim,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
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
  const _LogoutTile({required this.node, required this.onLogout});

  final FocusNode node;
  final VoidCallback onLogout;

  Future<void> _confirm(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => const TvConfirmDialog(
        title: '退出登录',
        message: '退出后需要重新输入服务器地址与账号密码。\n\n'
            '本机的「最近播放」与「收藏」记录**不会**被清除。',
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
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: const Row(
          children: <Widget>[
            Icon(Icons.logout, size: 22, color: TvColors.textFaint),
            SizedBox(width: 14),
            Expanded(
              child: Text(
                '退出登录',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, color: TvColors.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
