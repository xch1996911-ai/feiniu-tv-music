import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'tv_focus.dart';
import 'tv_glass.dart';

/// 用户在「离开应用」弹窗里的选择。
enum AppExitChoice {
  /// 把应用退到后台，音频继续播放。
  background,

  /// 停止播放、关掉服务，然后结束应用。
  exitAndStop,

  /// 留在应用（什么都不做）。
  cancel,
}

/// 电视端「离开应用」三选弹窗（V5 补充任务）。
///
/// ## 三个选项与各自的确切语义
///
/// - **后台继续播放**：界面退到后台，当前歌曲 / 队列 / 进度全部保持，
///   音频继续；不做任何清理（见 `AppExit.moveToBackground`）。
/// - **退出并停止播放**：停音源 → 结束 MediaSession 前台会话 →
///   停手机遥控服务（撤销手机会话）→ 结束 Activity。
///   清理顺序在 `app_shell._exitAndStop()` 里，本弹窗只负责把选择交回去。
/// - **取消 / 留在应用**：关闭弹窗，页面与播放状态原样保留。
///
/// ## 焦点（遥控器是唯一输入设备）
///
/// - 默认焦点落在**「取消 / 留在应用」**：与 `TvConfirmDialog` 同一条
///   安全原则 —— 破坏性动作（这里是「退出」）不该一按 OK 就执行；
/// - 三项**纵向**排列、上下串联（横向三按钮在电视上焦点路径含糊，
///   纵向列表是 Android TV 的标准形态）；
/// - 返回键由 `showDialog` 的 Navigator 路由处理：关闭弹窗 = 取消，
///   **不会**穿透到底下的 Shell PopScope 再触发一次弹窗
///   （「按两次返回重复弹窗」的防护在 Shell 的 `_exitDialogOpen` 上还有一层）。
class TvExitDialog extends StatelessWidget {
  const TvExitDialog({super.key});

  /// 弹出弹窗；返回用户的选择，`null` = 用返回键 / 点外部关闭（= 取消）。
  static Future<AppExitChoice?> show(BuildContext context) {
    return showDialog<AppExitChoice>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => const TvExitDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      // 与 TvConfirmDialog 一致：显式内边距，电视上不贴边、
      // 焦点框不被屏幕边缘 / overscan 吃掉。
      insetPadding: const EdgeInsets.symmetric(horizontal: 120, vertical: 80),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        // ⚠️ 整棵子树全部可 const ⇒ 直接从 TvGlass 这层开始 const。
        //    外层 const 之后，内层的 `const` 会变成冗余（unnecessary_const
        //    也是 info、也判失败），所以里层一律不再写 const。
        child: const TvGlass(
          radius: 20,
          tint: TvColors.glassHi,
          padding: EdgeInsets.fromLTRB(30, 26, 30, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.exit_to_app, size: 26, color: TvColors.accent),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '要离开 XX音乐 吗？',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: TvColors.text,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Text(
                '当前歌曲与队列会按你选择的方式处理',
                style: TextStyle(fontSize: 16, color: TvColors.textDim),
              ),
              SizedBox(height: 20),
              _ExitOptions(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExitOptions extends StatefulWidget {
  const _ExitOptions();

  @override
  State<_ExitOptions> createState() => _ExitOptionsState();
}

class _ExitOptionsState extends State<_ExitOptions> {
  // ⚠️ 焦点节点必须在 State 里一次性创建并跨帧保持（项目铁律，
  //    写在 build() 里会导致「有环没动作 / 有动作没环」）。
  final FocusNode _background = FocusNode(debugLabel: 'exit.background');
  final FocusNode _exit = FocusNode(debugLabel: 'exit.exit');
  final FocusNode _cancel = FocusNode(debugLabel: 'exit.cancel');

  @override
  void dispose() {
    _background.dispose();
    _exit.dispose();
    _cancel.dispose();
    super.dispose();
  }

  void _pick(AppExitChoice c) => Navigator.of(context).pop(c);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Option(
          node: _background,
          debugLabel: 'exit.background',
          icon: Icons.picture_in_picture_alt,
          title: '后台继续播放',
          subtitle: '回到电视桌面，歌曲继续播，可从最近任务回来',
          onPressed: () => _pick(AppExitChoice.background),
          nextUp: _cancel,
          nextDown: _exit,
          // ⚠️ 默认焦点在「取消」：纵向列表里取消在最下面，
          //    从取消出发按 ↓ 回绕到第一项（后台继续）。
          //    不让默认焦点落在「退出」上 —— 破坏性动作不能一按 OK 就执行。
        ),
        const SizedBox(height: 10),
        _Option(
          node: _exit,
          debugLabel: 'exit.exit',
          icon: Icons.power_settings_new,
          title: '退出并停止播放',
          subtitle: '停止音频并关闭应用',
          danger: true,
          onPressed: () => _pick(AppExitChoice.exitAndStop),
          nextUp: _background,
          nextDown: _cancel,
        ),
        const SizedBox(height: 10),
        _Option(
          node: _cancel,
          debugLabel: 'exit.cancel',
          icon: Icons.keyboard_return,
          title: '取消 / 留在应用',
          subtitle: '关闭本弹窗，继续使用',
          autofocus: true,
          onPressed: () => _pick(AppExitChoice.cancel),
          nextUp: _exit,
          nextDown: _background,
        ),
      ],
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.node,
    required this.debugLabel,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
    this.nextUp,
    this.nextDown,
    this.autofocus = false,
    this.danger = false,
  });

  final FocusNode node;
  final String debugLabel;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;
  final FocusNode? nextUp;
  final FocusNode? nextDown;
  final bool autofocus;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: node,
      debugLabel: debugLabel,
      autofocus: autofocus,
      onPressed: onPressed,
      nextUp: nextUp,
      nextDown: nextDown,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        baseColor: danger ? const Color(0xFFB3261E) : const Color(0x26FFFFFF),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 22,
              color: danger ? TvColors.warn : TvColors.textDim,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // ⚠️ 固定高度列表项里的文字必须显式 height（M3 默认 1.43
                    //    会让实际占高远超字号），且字号 × height 必须取整口径。
                    style: TextStyle(
                      fontSize: 19,
                      height: 1.2, // 19 × 1.2 = 22.8 → 23
                      fontWeight: FontWeight.w600,
                      color: danger ? TvColors.warn : TvColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.2, // 18
                      color: TvColors.textFaint,
                    ),
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
