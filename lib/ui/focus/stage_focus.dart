import 'package:flutter/widgets.dart';

/// 焦点层级 —— 全 App 只认这四层。
///
/// ```
///  A 内容层   track.row / list.row.N / home.tile / player.* / diag.*
///  B 主控层   mini.cover / mini.prev / mini.play / mini.next / mini.queue
///  C 次级层   extra.queue / extra.fav / extra.mode（只在明确打开时存在）
///  N 导航层   nav.0 … nav.6 / nav.logout / shell.search
/// ```
///
/// ## 为什么要有「层」这个概念
/// 实机反馈：Mini Player 上按 ↑ 会**弹出**「收藏 / 模式」工具条。
/// 那是把「空间导航」和「展开菜单」塞进了同一个键 —— 用户永远无法预测
/// 按下 ↑ 会移动焦点还是打开一个面板。
///
/// 现在的硬规则：
/// - 方向键**只**在可见层之间移动焦点，不兼任任何命令；
/// - C 层（收藏 / 模式 / 队列）未打开时**根本不在焦点树上**；
/// - 打开 C 层只允许通过 OK（在「队列/更多」按钮上）或 BACK 关闭。
enum TvFocusLayer { content, nav, mini, overlay }

/// 舞台焦点记忆 + 页面默认焦点登记。
///
/// ## 两个职责
/// 1. **Mini ↑ 回正文**：记住「进入 Mini Player 之前正文里最后获得焦点的节点」。
///    方向键进 Mini Player 不会覆盖它，所以 ↑ 一定回得去原来那一项
///    （首页最近播放第 3 格 → ↓ Mini → ↑ 还是第 3 格，不是第一格）。
/// 2. **切页默认焦点**：页面在 build 里登记「本页第一焦点」，
///    切页后 Shell 直接聚焦它 —— 不再一律跳左侧导航第一项。
///
/// ## 为什么按节点对象记，而不是按标签
/// 同一份「最近播放」里每个格子的 `debugLabel` 都是 `home.tile`，
/// 按标签记只能回到第一格。节点对象是唯一的，能精确回到刚才那一格。
class StageFocus extends ChangeNotifier {
  FocusNode? _lastContent;
  FocusNode? _stageDefault;
  final Map<String, FocusNode> _byLabel = <String, FocusNode>{};

  /// 焦点分层判定。**只按 debugLabel 前缀**，不引入额外状态 ——
  /// 这样任何新控件只要按命名约定起标签就自动落进正确的层。
  static TvFocusLayer layerOf(FocusNode? n) {
    final String label = n?.debugLabel ?? '';
    if (label.startsWith('mini.') || label.startsWith('extra.')) {
      return TvFocusLayer.mini;
    }
    if (label.startsWith('nav.') || label == 'shell.search') {
      return TvFocusLayer.nav;
    }
    if (label.startsWith('player.') || label.startsWith('queue.')) {
      return TvFocusLayer.overlay;
    }
    return TvFocusLayer.content;
  }

  /// 节点是否**仍然挂在树上**且可获焦。
  ///
  /// `context == null` 说明它所在的 Widget 已经卸载（例如换页后旧列表被销毁）。
  /// 已卸载的节点直接 `requestFocus()` 会抛「used after being disposed」，
  /// 所以每次恢复焦点前都必须过这一关。
  static bool alive(FocusNode? n) =>
      n != null && n.context != null && n.canRequestFocus;

  /// 安全聚焦：拿不到就返回 false，绝不抛异常、绝不留下「按键没反应」的死区。
  static bool focus(FocusNode? n) {
    if (!alive(n)) return false;
    try {
      n!.requestFocus();
      return true;
    } catch (_) {
      // 极少数情况下节点在这一瞬时被销毁（快速连按切页）。吞掉即可，
      // 调用方会继续尝试下一级兜底。
      return false;
    }
  }

  /// 页面在 `build` 里调用：本页的第一焦点。
  void registerDefault(FocusNode node) {
    register(node);
    _stageDefault = node;
  }

  /// 登记到标签表（供按标签回查，例如「回到首页的最近添加卡」）。
  void register(FocusNode node) {
    final String label = node.debugLabel ?? '';
    if (label.isEmpty) return;
    _byLabel[label] = node;
  }

  FocusNode? byLabel(String label) => _byLabel[label];

  /// 全局焦点变化时由 Shell 调用。
  ///
  /// 只记**内容层**：导航层 / Mini 层 / 覆盖层的焦点不应该成为
  /// 「Mini ↑ 回正文」的目标。
  void note(FocusNode? n) {
    if (n == null) return;
    if (layerOf(n) != TvFocusLayer.content) return;
    _lastContent = n;
  }

  /// 切页时清空：上一页的节点马上就会被销毁，留着只会指向死节点。
  void clearStage() {
    _lastContent = null;
    _stageDefault = null;
  }

  bool focusLastContent() => focus(_lastContent);

  bool focusStageDefault() => focus(_stageDefault);

  /// 按标签恢复焦点。
  ///
  /// 用途：从 B 页 BACK 回 A 页时，A 页的 State 已经重建、节点换了新对象，
  /// 但**标签不变**。按标签回查就能落到「原来那一张卡」而不是页面第一项。
  bool focusLabel(String label) => focus(_byLabel[label]);

  FocusNode? get debugLastContent => _lastContent;

  FocusNode? get debugStageDefault => _stageDefault;

  @override
  void dispose() {
    _byLabel.clear();
    _lastContent = null;
    _stageDefault = null;
    super.dispose();
  }
}

/// 把 [StageFocus] 与 Mini Player 的主链节点交给页面。
///
/// 页面需要它做两件事：
/// - 登记本页默认首焦点（`stage.registerDefault`）；
/// - 列表最后一行按 ↓ 落到 Mini Player（`miniCoverIfAlive`）。
class StageFocusScope extends InheritedWidget {
  const StageFocusScope({
    super.key,
    required this.stage,
    required this.miniCover,
    required this.miniPlay,
    required super.child,
  });

  final StageFocus stage;

  /// Mini Player 封面节点（焦点链第一段，也是「列表到底 ↓」的落点）。
  final FocusNode miniCover;

  /// Mini Player 播放键（列表到底 ↓ 的备选落点）。
  final FocusNode miniPlay;

  /// Mini Player 还没渲染（没有当前曲目）时返回 null ——
  /// 交给框架兜底，而不是指向一个不存在的节点。
  FocusNode? get miniCoverIfAlive =>
      StageFocus.alive(miniCover) ? miniCover : null;

  static StageFocusScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StageFocusScope>();

  @override
  bool updateShouldNotify(StageFocusScope oldWidget) =>
      !identical(stage, oldWidget.stage) ||
      !identical(miniCover, oldWidget.miniCover) ||
      !identical(miniPlay, oldWidget.miniPlay);
}
