import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'tv_focus.dart';

/// 左侧导航项定义。
class NavRailItem {
  final IconData icon;
  final String label;

  const NavRailItem({required this.icon, required this.label});
}

/// 左侧主导航（参考图二）。
///
/// ## 焦点链
/// 竖直方向**显式串联**（首页 → … → 退出登录，反之亦然），
/// 左右方向交回框架 —— 向右自然进入内容区，这是电视用户最容易理解的路径。
///
/// ## 为什么没有「歌单 / 收起」
/// - 飞牛**没有歌单接口**（`fnOS_API_真实契约.md` §9 路径表里
///   `playlist-detail/list` 未实测、无法确认参数与权限），
///   画一个点了没反应的「歌单 +」比不画更糟；
/// - 「收起」是网页端的侧栏折叠，电视上屏幕宽度固定，折叠没有意义。
///
/// 底部改成**退出登录**：它本来就是既有能力（`AuthRepository.logout`），
/// 此前在 UI 上完全没有入口，电视用户换账号只能清数据。
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
    return Container(
      width: width,
      color: TvColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _RailLogo(),
          const SizedBox(height: 18),
          for (int i = 0; i < items.length; i++)
            _NavTile(
              item: items[i],
              selected: i == selected,
              node: nodes[i],
              // 显式上下串联：任何一项都能一路走到最底 / 最顶，中间不会卡住。
              nextUp: i > 0 ? nodes[i - 1] : null,
              nextDown: i < items.length - 1 ? nodes[i + 1] : logoutNode,
              onPressed: () => onSelected(i),
            ),
          const Spacer(),
          const Divider(height: 1, color: TvColors.line),
          _LogoutTile(node: logoutNode, onLogout: onLogout),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _RailLogo extends StatelessWidget {
  const _RailLogo();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: TvFocus(
        focusNode: node,
        debugLabel: 'nav.${item.label}',
        onPressed: onPressed,
        nextUp: nextUp,
        nextDown: nextDown,
        builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
          status: s,
          radius: 10,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          // 选中项用底色区分（与参考图二一致），焦点另有描边，两者互不干扰。
          baseColor: selected ? TvColors.panelHi : Colors.transparent,
          focusColor: TvColors.focusFill,
          child: Row(
            children: <Widget>[
              Icon(
                item.icon,
                size: 22,
                // 选中项图标用强调色，一眼看出「现在在哪一页」
                color: selected ? TvColors.accent : TvColors.textDim,
              ),
              const SizedBox(width: 14),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? TvColors.text : TvColors.textDim,
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
/// 电视端没有「弹窗 → 找按钮 → 确定」这种多步操作的余裕，
/// 因此用**两段式确认**：第一次 OK 变成「再按一次退出登录」，3 秒内再按才真的退出。
/// 既避免误触登出，又不需要弹窗与焦点切换。
class _LogoutTile extends StatefulWidget {
  const _LogoutTile({required this.node, required this.onLogout});

  final FocusNode node;
  final VoidCallback onLogout;

  @override
  State<_LogoutTile> createState() => _LogoutTileState();
}

class _LogoutTileState extends State<_LogoutTile> {
  bool _armed = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _handle() {
    if (_armed) {
      _timer?.cancel();
      if (mounted) setState(() => _armed = false);
      widget.onLogout();
      return;
    }
    setState(() => _armed = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _armed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TvFocus(
        focusNode: widget.node,
        debugLabel: 'nav.logout',
        onPressed: _handle,
        builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
          status: s,
          radius: 10,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: <Widget>[
              Icon(
                _armed ? Icons.warning_amber : Icons.logout,
                size: 22,
                color: _armed ? TvColors.warn : TvColors.textFaint,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  _armed ? '再按一次退出登录' : '退出登录',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    color: _armed ? TvColors.warn : TvColors.textFaint,
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
