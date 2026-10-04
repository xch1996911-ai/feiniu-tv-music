import 'dart:async';
import 'dart:math';
import 'dart:ui' show FlutterView, ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/diagnostics.dart';
import '../../core/log.dart';
import '../../domain/player_layout.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/lyric_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/cover_image.dart';
import '../widgets/lyric_view.dart';
import '../widgets/queue_sheet.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_glass.dart';

/// 正在播放页（全屏覆盖层）—— **V6 融合版式**。
///
/// ## 版式（对齐用户参考图：封面与背景融合的左右分区）
/// ```
/// ┌──────────────────────────────────────────────────────────────┐
/// │ [⌄返回]                        （整屏：模糊封面 + 暗渐变） [♡ ⋮]│
/// │ ┌──────────────────────────┐ │                               │
/// │ │        大 封 面           │ │      右侧同步歌词区            │
/// │ │  （右/下边缘渐隐融进背景） │ │   （当前句亮白加粗、自动居中）  │
/// │ │ 歌名(加粗)                │ │                               │
/// │ │ 歌手                      │ │                               │
/// │ │ ──────细进度条──────      │ │                               │
/// │ │  0:07   FLAC·…    04:50  │ │                               │
/// │ │  ⃞   ⏮   ▶   ⏭   ☰      │ │                               │
/// │ └──────────────────────────┘ │                               │
/// └──────────────────────────────────────────────────────────────┘
/// ```
/// - **顶部行常驻**：返回/收起（左上）、收藏 + 更多（右上），两种布局一致。
/// - **背景**：整屏铺当前封面的低分辨率模糊图 + 暗色渐变压暗，保证白字可读；
///   切歌时 600ms 交叉淡化，不闪白。没有封面时回落到站内渐变。
/// - **主封面**：`BoxFit` 保持比例，右/下两条渐隐遮罩融进背景，无卡片无厚边框。
/// - **信息/进度/控制**全部在左区底部，右侧歌词区保持独立整高。
/// - 旧「大毛玻璃按钮盒」取消；底部五键为纯图标，聚焦时才出现细光环。
/// - 「大封面」旧布局保留为 [PlayerLayout.cover]，入口收进「更多」菜单。
///
/// ## 焦点（绝不能退化的部分）
/// 全部显式链，且与屏幕位置一致；**顶部三键在两种布局下都常驻**：
/// ```
///   顶部：back ↔ fav ↔ more        （左端/右端原地不动，不环回）
///   底部：mode ↔ prev ↔ play ↔ next ↔ queue（两端环回）
///   纵向：顶部三键 ↓→ seek；seek ↓→ mode；seek ↑→ fav（两种布局一致）
///        五个控制键 ↑→ seek、↓→ 自身
///   seek：←/→ = ∓5s 快退/快进，OK = 播放/暂停
/// ```
/// 因此「顶部 → 进度区 → 控制行 → 回到顶部」始终是闭环：
/// 任何样式切换后都不会出现「顶部按键够不到」或焦点死路。
/// 进入播放页焦点直接落在「播放/暂停」。
///
/// ## 为什么控制区不会因进度刷新而丢焦点
/// 本页 `build` 不订阅 position：进度只在 [_SeekRow] 内部自刷新；
/// 播放/暂停、模式、可否上一首的订阅收在 [_TransportControls] 内部，
/// 进度跳动时其余控件不重建，`FocusNode` 自然不会被换掉。
class PlayerPage extends StatefulWidget {
  /// 返回（回到进入播放页之前的位置）。音乐**继续播放**。
  final VoidCallback onBack;

  const PlayerPage({super.key, required this.onBack});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  // ── 焦点节点（全部在本 State 创建并释放）────────────────────
  final FocusNode _backNode = FocusNode(debugLabel: 'player.back');
  final FocusNode _favNode = FocusNode(debugLabel: 'player.fav');
  final FocusNode _moreNode = FocusNode(debugLabel: 'player.more');
  final FocusNode _modeNode = FocusNode(debugLabel: 'player.mode');
  final FocusNode _prevNode = FocusNode(debugLabel: 'player.prev');
  final FocusNode _playNode = FocusNode(debugLabel: 'player.play');
  final FocusNode _nextNode = FocusNode(debugLabel: 'player.next');
  final FocusNode _queueNode = FocusNode(debugLabel: 'player.queue');
  final FocusNode _seekNode = FocusNode(debugLabel: 'player.seek');

  /// 队列面板是否打开。
  bool _queueOpen = false;

  /// 「更多」菜单是否打开。
  bool _menuOpen = false;

  /// 已请求歌词的曲目 guid，用于检测换歌。
  String? _lyricForGuid;

  /// 播放仓储引用（构造时抓一次，避免 dispose 阶段再 `context.read`）。
  late final PlaybackRepository _playback;

  /// 视口诊断只记一次（每次进程生命周期），避免反复覆盖有意义的事件。
  static bool _viewportNoted = false;

  /// 上一帧渲染用的布局 —— 用于检测「切换样式」并做焦点兜底恢复。
  PlayerLayout? _laidOut;

  /// 两种布局下都必然存在的焦点节点（切换样式后合法保留焦点的白名单）。
  ///
  /// ⚠️ 顶部三个键（back / fav / more）**在任何布局下都常驻** —— 这正是
  ///    「切换样式后顶部按键按不到」的修复点：老实现把收藏/更多放在
  ///    「信息行」里，而大封面布局没有信息行，节点整棵被卸载，焦点只能掉到
  ///    FocusScope（表现为方向键全部失灵）。
  static const Set<String> _stableFocusLabels = <String>{
    'player.back',
    'player.fav',
    'player.more',
    'player.seek',
    'player.mode',
    'player.prev',
    'player.play',
    'player.next',
    'player.queue',
  };

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackRepository>();
    // 换歌（含自动下一首）要立刻换歌词：直接监听播放仓储，
    // 比轮询定时器更及时，也不会漏掉「用户按下一首」这种瞬间切歌。
    _playback.addListener(_syncLyric);
    // 进入播放页把焦点**直接落在播放/暂停**上（验收要求）。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _playNode.requestFocus();
      _syncLyric();
      _noteViewport(context);
    });
  }

  @override
  void dispose() {
    _playback.removeListener(_syncLyric);
    for (final FocusNode n in <FocusNode>[
      _backNode,
      _favNode,
      _moreNode,
      _modeNode,
      _prevNode,
      _playNode,
      _nextNode,
      _queueNode,
      _seekNode,
    ]) {
      n.dispose();
    }
    super.dispose();
  }

  /// 把实际视口信息写进诊断页（需求 §五：先记录 physicalSize / dpr /
  /// 逻辑视口 / textScale / 安全区；主界面不展示这些技术信息）。
  void _noteViewport(BuildContext context) {
    if (_viewportNoted) return;
    _viewportNoted = true;
    final MediaQueryData mq = MediaQuery.of(context);
    final FlutterView view = View.of(context);
    Diagnostics.note(
      '播放页视口',
      '物理 ${view.physicalSize.width.toInt()}×${view.physicalSize.height.toInt()}'
      ' · dpr ${view.devicePixelRatio}'
      ' · 逻辑 ${mq.size.width.toInt()}×${mq.size.height.toInt()}'
      ' · 字体缩放 ${mq.textScaler.scale(1.0)}'
      ' · 安全区 l${mq.padding.left}/t${mq.padding.top}'
          '/r${mq.padding.right}/b${mq.padding.bottom}',
    );
  }

  /// 换歌时加载新歌词（自动下一首后歌词要跟着换）。
  ///
  /// 本方法会被**高频调用**（出现在播放仓储的监听链上），
  /// 因此第一件事就是比对 guid 后短路，绝不做多余工作。
  void _syncLyric() {
    if (!mounted) return;
    final Track? song = _playback.current;
    final lyrics = context.read<LyricRepository>();
    if (song == null) {
      if (_lyricForGuid != null) {
        lyrics.clear();
        _lyricForGuid = null;
      }
      return;
    }
    if (_lyricForGuid == song.guid) return;
    _lyricForGuid = song.guid;
    Log.i('LYRIC_LOAD 播放页检测到切歌 → ${song.guid}');
    // 刻意不 await：歌词慢不能挡住页面
    unawaited(lyrics.load(song));
  }

  void _openQueue() {
    Log.i('UI 打开播放队列 (player)');
    setState(() => _queueOpen = true);
  }

  void _closeQueue() {
    if (!_queueOpen) return;
    setState(() => _queueOpen = false);
    // 关闭队列后焦点**回到队列按钮**（需求：返回后回到原焦点位置）。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _queueNode.requestFocus();
    });
  }

  void _openMenu() {
    Log.i('UI 打开播放页更多菜单');
    setState(() => _menuOpen = true);
  }

  void _closeMenu() {
    if (!_menuOpen) return;
    setState(() => _menuOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _moreNode.requestFocus();
    });
  }

  void _toggleLayout() {
    final LocalLibraryRepository local = context.read<LocalLibraryRepository>();
    final PlayerLayout nextLayout = local.playerLayout.next;
    Log.i('UI 播放页布局 ${local.playerLayout.storageKey} → ${nextLayout.storageKey}');
    unawaited(local.setPlayerLayout(nextLayout));
  }

  void _reloadLyrics() {
    final Track? song = _playback.current;
    if (song == null) return;
    Log.i('LYRIC_RETRY 播放页手动重载歌词');
    unawaited(context.read<LyricRepository>().load(song, force: true));
  }

  /// 布局切换后的焦点兜底：只有**焦点真的丢了**才抢回，绝不与显式还焦点打架。
  ///
  /// ⚠️ 为什么要「延后一帧 + 复核」：
  /// 关菜单（[_closeMenu]）与切布局是**同一次按键**里发生的：
  /// 前者在按键回调里注册「把焦点还给更多键」，后者在随后那一帧的 build 里
  /// 注册本兜底。若立即判定，`primaryFocus` 还是**旧值**（已被卸载的菜单项 →
  /// 框架上交的 FocusScope），于是会把刚还回去的焦点又抢到播放/暂停键上 ——
  /// CI 上正是这样挂的 4 个用例。`requestFocus` 要等下一帧的 postFrame 才
  /// 真正生效，所以这里再等一帧；复核到「已有人还了焦点」就立刻放手。
  void _restoreFocusIfLost() {
    if (!mounted || _queueOpen || _menuOpen) return;
    if (_isStableFocus(FocusManager.instance.primaryFocus)) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || _queueOpen || _menuOpen) return;
      final FocusNode? pf = FocusManager.instance.primaryFocus;
      if (_isStableFocus(pf)) return; // 显式还焦点的请求已生效：不干预
      Log.i('PLAYER_LAYOUT 焦点兜底：${pf?.debugLabel ?? 'null'} → player.play');
      _playNode.requestFocus();
    });
  }

  static bool _isStableFocus(FocusNode? node) {
    final String? label = node?.debugLabel;
    return label != null && _stableFocusLabels.contains(label);
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 只订阅「当前曲目」「布局模式」「是否已收藏」。
    //    进度/播放态的订阅下沉到 [_SeekRow] / [_TransportControls]，
    //    避免进度每秒跳动整页重建。
    final Track? song = context.select<PlaybackRepository, Track?>(
      (PlaybackRepository p) => p.current,
    );
    final PlayerLayout layout = context.select<LocalLibraryRepository,
        PlayerLayout>((LocalLibraryRepository l) => l.playerLayout);
    // ⚠️ 「当前曲是否已收藏」必须在这里读，**不能**下沉到 [_FusedCover]：
    //    那里从 `LayoutBuilder` 的 builder 里调用，而 builder 跑在
    //    **layout 阶段**，provider 的 `context.select` 会直接断言失败。
    final bool fav = context.select<LocalLibraryRepository, bool>(
      (LocalLibraryRepository l) => song != null && l.isFavorite(song.guid),
    );
    final MusicRepository music = context.read<MusicRepository>();
    final bool overlayOpen = _queueOpen || _menuOpen;

    // ⚠️ 切换播放页样式后的**焦点兜底恢复**。
    //
    // 顶部三键与进度区/控制行在两种布局下都常驻（`_stableFocusLabels`），
    // 所以正常情况下切换样式焦点会原地保留（这是需求要的）。
    // 但一旦焦点落在「新样式里已不存在的节点」上，焦点会被框架上交给
    // FocusScope —— 此时 primaryFocus 的 debugLabel 不在白名单里，
    // 表现为「方向键全失灵、顶部按键够不到」。这里在布局完成后检测并恢复。
    if (_laidOut != layout) {
      _laidOut = layout;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        _restoreFocusIfLost();
      });
    }

    return Material(
      color: TvColors.stageTo,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 整屏融合背景（模糊封面 + 压暗渐变），铺满不受 SafeArea 约束。
          _FusionBackground(song: song, music: music),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 14, 36, 16),
              // ⚠️ 队列/菜单打开时把**整个播放页**（含顶栏）排除出焦点树，
              //    否则方向键会跑到被遮住的按钮上（焦点"消失"）。
              child: ExcludeFocus(
                excluding: overlayOpen,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // 顶部行：**两种布局完全一致**的常驻键
                    // [返回/收起] ←→ [收藏] ←→ [更多]，每个 ↓ 进步度区。
                    SizedBox(
                      height: 44,
                      child: _TopControls(
                        song: song,
                        fav: fav,
                        backNode: _backNode,
                        favNode: _favNode,
                        moreNode: _moreNode,
                        seekNode: _seekNode,
                        onBack: widget.onBack,
                        onMore: _openMenu,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: layout == PlayerLayout.stage
                          ? _buildStageBody(song)
                          : _buildCoverBody(song),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_queueOpen) QueueSheet(onClose: _closeQueue),
          if (_menuOpen)
            _MoreSheet(
              onClose: _closeMenu,
              onToggleLayout: _toggleLayout,
              onReloadLyrics: _reloadLyrics,
            ),
        ],
      ),
    );
  }

  // ── 主体：两种展示模式 ────────────────────────────────────

  /// V6 融合布局（默认）：左区 = 封面渐隐融合 + 信息 + 进度 + 五键控制；
  /// 右区 = 独立整高的同步歌词。
  Widget _buildStageBody(Track? song) {
    if (song == null) {
      return const Center(
        child: Text('尚未选择歌曲',
            style: TextStyle(fontSize: 26, color: TvColors.textFaint)),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          flex: 47, // 左区约 47%（其余 53% 给歌词），按逻辑视口比例分配
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: _FusedCover(song: song)),
              const SizedBox(height: 12),
              // 信息行只放「歌名 + 歌手」；收藏/更多已上移到常驻顶部行，
              // 避免同一功能在两处各挂一个焦点节点（也消除「切换样式后
              // 图标消失、按不到」的隐患）。
              _InfoRow(song: song),
              const SizedBox(height: 8),
              _SeekRow(
                playbackNode: _seekNode,
                // ↑ 回信息行的收藏键（正上方）；↓ 去控制区最左（模式键）。
                upNode: _favNode,
                downNode: _modeNode,
              ),
              const SizedBox(height: 10),
              // 播放错误（解码失败等）：只在真的出错时占一行，平时零高度。
              const _ErrorLine(),
              const SizedBox(height: 6),
              _TransportControls(
                modeNode: _modeNode,
                prevNode: _prevNode,
                playNode: _playNode,
                nextNode: _nextNode,
                queueNode: _queueNode,
                seekNode: _seekNode,
                onQueue: _openQueue,
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
        // 右区：独立整高的歌词视口（内部已做居中滚动与状态呈现）。
        const Expanded(flex: 53, child: LyricView()),
      ],
    );
  }

  /// 旧「大封面」布局（[PlayerLayout.cover]，入口在更多菜单）：
  /// 封面放大为视觉主体、歌词在封面下方；进度与控制区保持一致。
  Widget _buildCoverBody(Track? song) {
    if (song == null) {
      return const Center(
        child: Text('尚未选择歌曲',
            style: TextStyle(fontSize: 26, color: TvColors.textFaint)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          flex: 6,
          child: _buildCoverPane(song, center: true, horizontal: true),
        ),
        const SizedBox(height: 10),
        const Expanded(flex: 4, child: LyricView()),
        const SizedBox(height: 10),
        _SeekRow(
          playbackNode: _seekNode,
          // ⚠️ 大封面布局也必须有一条边通到顶部行 —— 老实现这里指向自身，
          //    导致「主体按键永远够不到顶部返回/更多」（用户实测反馈的故障）。
          upNode: _favNode,
          downNode: _modeNode,
        ),
        const SizedBox(height: 10),
        const _ErrorLine(),
        const SizedBox(height: 6),
        _TransportControls(
          modeNode: _modeNode,
          prevNode: _prevNode,
          playNode: _playNode,
          nextNode: _nextNode,
          queueNode: _queueNode,
          seekNode: _seekNode,
          onQueue: _openQueue,
        ),
      ],
    );
  }

  /// 旧布局的「封面 + 曲目信息」面板（V4 验证过的尺寸预算，原样保留）。
  ///
  /// ⚠️ 本方法**只做布局**，任何 provider 订阅都由调用方（真正的 `build()`）
  /// 传进来 —— 它被 `LayoutBuilder` 的 builder 调用，那里不允许 `context.select`。
  Widget _buildCoverPane(
    Track song, {
    required bool center,
    bool horizontal = false,
  }) {
    final MusicRepository music = context.read<MusicRepository>();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        return _buildCoverPaneInner(song, box, center, horizontal, music);
      },
    );
  }

  Widget _buildCoverPaneInner(
    Track song,
    BoxConstraints box,
    bool center,
    bool horizontal,
    MusicRepository music,
  ) {
    // ── 尺寸预算（全部是显式常量，便于一眼核对）────────────────
    // 文字块三个部件的高度 —— 逐项对齐**真实渲染高度**，不凭字号估：
    //   ① 标题 `Text(fontSize:, height: 1.15)` → 行高 = ⌈字号 × 1.15⌉；
    //   ② 歌手行 `Text(fontSize: 20)` **没写 height** → 用 M3 默认 1.43
    //      → ⌈20 × 1.43⌉ = 29（按 20 算会少 9px）；
    //   ③ 规格胶囊 `_Chip` = 上下 padding 12 + ⌈16 × 1.43⌉ = 35
    //      （按 32 算会少 3px）；
    //   ④ **系统字体缩放**（Android 的「字体大小 / 显示大小」）会整体放大文字。
    //   Flutter 对**每一行**行盒向上取整，所以这里统一 `ceilToDouble()`。
    final double ts = MediaQuery.textScalerOf(context).scale(1.0);

    final double titleSize = center ? 38 : 34;
    final double titleLineH = (titleSize * ts * 1.15).ceilToDouble();
    final double artistLineH = (20 * ts * 1.43).ceilToDouble();
    final double chipH = (16 * ts * 1.43).ceilToDouble() + 12;
    const double gapBig = 22;
    const double gapSmall = 10;
    // 收尾余量：逐行取整 + 文字排版误差。不留这一项时，
    // 「正好等于可用高度」的算式会被判 `overflowed by 0.4 pixels`。
    const double slack = 2;

    // 最坏情况（2 行标题）先算一遍；装不下就退回 1 行。
    final double fullText =
        titleLineH * 2 + gapSmall + artistLineH + gapSmall + chipH;
    final double availH = box.maxHeight.isFinite ? box.maxHeight : 400;
    final double availW = box.maxWidth.isFinite ? box.maxWidth : 400;
    final bool twoLineTitle = (availH - gapBig - fullText) >= 150;
    final int titleLines = twoLineTitle ? 2 : 1;
    final double textBlock = titleLineH * titleLines +
        gapSmall +
        artistLineH +
        gapSmall +
        chipH;

    // 横向排布时文字在右边：封面可用宽度还要扣掉间距与文字宽度预算。
    // ⚠️ 这个 `textW` **必须同时用作下面 `ConstrainedBox` 的上限**。
    final bool useRow = horizontal && textBlock <= availH - slack;
    final double textW = useRow ? min(420.0, availW * 0.45) : 0.0;
    final double coverByWidth =
        useRow ? (availW - 28 - textW - slack) : (availW - slack);
    final double coverByHeight =
        useRow ? (availH - slack) : (availH - gapBig - textBlock - slack);

    // ⚠️ 设计下限**不能覆盖实际可用空间**（V4 教训，见 git 历史）。
    const double designMin = 110;
    final double upper = horizontal ? 460.0 : 360.0;
    final double fit = min(max(0.0, coverByWidth), max(0.0, coverByHeight));
    final double coverSize = fit >= designMin ? min(fit, upper) : fit;

    final Widget cover = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: CoverImage(
        music: music,
        coverId: song.effectiveCoverId,
        size: coverSize,
        radius: 16,
        iconScale: 0.3,
      ),
    );

    final Widget info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          song.title,
          // 空间不够时降为 1 行：宁可少一行，也不要整块被裁切
          maxLines: titleLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: center ? 38 : 34,
            height: 1.15,
            fontWeight: FontWeight.w700,
            color: TvColors.text,
          ),
        ),
        const SizedBox(height: gapSmall),
        Row(
          children: <Widget>[
            // ⚠️ 这里**不放心形图标**：老实现在这里画了一颗仅装饰用的心，
            //    看着像按钮但不可聚焦 —— 用户会反复按方向键试图选中它。
            //    收藏键现在唯一存在于顶部常驻行（可聚焦、可用 OK 触发）。
            Expanded(
              child: Text(
                song.artistNames.isEmpty
                    ? song.album.name
                    : '${song.artistNames} · ${song.album.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, color: TvColors.textDim),
              ),
            ),
          ],
        ),
        const SizedBox(height: gapSmall),
        // ⚠️ 规格胶囊必须完整可见（实机问题就是它被切掉）
        _Chip(text: song.audioSpec.display),
      ],
    );

    /// 给文字块套一层「必要时整体等比缩小」的兜底。
    /// `SizedBox(width: …)` 是必需的：`FittedBox` 交给子树的宽度是**无界**的，
    /// 而歌手行里有一个 `Expanded`，无界宽度会直接抛异常。
    Widget shrinkable(double width, double maxHeight) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: SizedBox(width: width, child: info),
          ),
        );

    if (useRow) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          cover,
          const SizedBox(width: 28),
          shrinkable(textW, availH - slack),
        ],
      );
    }

    return Column(
      crossAxisAlignment:
          center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        cover,
        const SizedBox(height: gapBig),
        shrinkable(availW, max(0.0, availH - gapBig - coverSize)),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// 融合背景与融合封面
// ═══════════════════════════════════════════════════════════════════

/// 整屏融合背景：**低分辨率模糊封面** + 暗色渐变压暗。
///
/// ## 颜色为什么「随封面自然变化」
/// 背景直接用封面自身的颜色（64px 缩略图放大 + 高斯模糊），
/// 不做取色算法 —— 模糊封面本身就是「封面的主色分布」，
/// 换歌时颜色自然跟着换，还没有任何取色误差。
///
/// ## 性能
/// - `cacheWidth: 64`：解码的是 64px 小图，放大后天然糊化，
///   再叠一层适度高斯模糊抹平马赛克感；
/// - `ImageFiltered` 只在图片替换时重绘一次，播放进度每秒的刷新
///   **完全不经过这里**（本页 build 不订阅 position）；
/// - 暗色渐变保证白色文字在亮色封面上依然可读（验收条件）。
///
/// ## 切歌不闪白
/// [AnimatedSwitcher] 600ms 交叉淡化：旧图淡出的同时新图淡入，
/// 底层还有站内渐变兜底，任何时刻都有内容、没有白屏。
class _FusionBackground extends StatelessWidget {
  final Track? song;
  final MusicRepository music;

  const _FusionBackground({required this.song, required this.music});

  @override
  Widget build(BuildContext context) {
    final String? coverId = song?.effectiveCoverId;
    final bool hasCover = coverId != null && coverId.isNotEmpty;

    final Widget layer;
    if (hasCover) {
      final String url = music.buildCoverUrl(coverId);
      final Map<String, String> headers = music.authHeaders;
      layer = SizedBox.expand(
        key: ValueKey<String>(coverId),
        child: ClipRect(
          // 放大 1.15 倍：模糊在边缘会「漏」出透明，放大后再由 ClipRect
          // 裁掉边缘，避免四周出现暗框。
          child: Transform.scale(
            scale: 1.15,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Image.network(
                url,
                headers: headers.isEmpty ? null : headers,
                cacheWidth: 64,
                fit: BoxFit.cover,
                alignment: Alignment.center,
                gaplessPlayback: true,
                // 加载失败/无网 → 露出底层渐变，绝不能抛错拖垮播放页。
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                loadingBuilder: (_, Widget child, ImageChunkEvent? ___) =>
                    child,
              ),
            ),
          ),
        ),
      );
    } else {
      layer = const SizedBox.expand(key: ValueKey<String>('no-cover'));
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 兜底渐变（也是无封面时的最终背景）。
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[TvColors.stageFrom, TvColors.stageTo],
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          child: layer,
        ),
        // 压暗层：上浅下深，保证歌名/控制区白字对比度。
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0x4D000000),
                Color(0x66000000),
                Color(0xA6000000),
              ],
              stops: <double>[0.0, 0.45, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

/// 左区主封面：右/下边缘**渐隐融合**进背景（无边界效果）。
///
/// - 尺寸 = `min(可用宽, 可用高)`：小视口自动让位给信息/控制区，
///   大视口按比例占满左区（4K 下自然变大），不做固定边长。
/// - 两层 `ShaderMask(dstIn)` 分别做水平与垂直渐隐；
///   主封面本身保持清晰（模糊只用在背景上）。
/// - 封面缺失时 `CoverImage` 的占位符同尺寸渲染，不会拉伸或留黑块。
class _FusedCover extends StatelessWidget {
  final Track song;

  const _FusedCover({required this.song});

  @override
  Widget build(BuildContext context) {
    final MusicRepository music = context.read<MusicRepository>();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth.isFinite ? c.maxWidth : 300;
        final double h = c.maxHeight.isFinite ? c.maxHeight : 300;
        final double size = max(0.0, min(w, h) - 2);
        return Align(
          alignment: Alignment.topCenter,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (Rect r) => const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: <Color>[Colors.white, Colors.white, Color(0x00FFFFFF)],
              stops: <double>[0.0, 0.78, 1.0],
            ).createShader(r),
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (Rect r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Colors.white, Colors.white, Color(0x00FFFFFF)],
                stops: <double>[0.0, 0.80, 1.0],
              ).createShader(r),
              child: CoverImage(
                music: music,
                coverId: song.effectiveCoverId,
                size: size,
                radius: 0,
                iconScale: 0.28,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// 左下：歌曲信息 / 进度 / 控制键
// ═══════════════════════════════════════════════════════════════════

/// 常驻顶部行（**两种布局完全一致**）：返回/收起 ←→ 收藏 ←→ 更多。
///
/// ## 为什么这三个键必须常驻顶部
/// 「切换播放页样式后遥控器选不中顶部按键」的真实根因有两条：
/// 1. 老实现把「收藏 / 更多」放进**信息行**，而大封面布局没有信息行 ——
///    切换样式时这两个 `FocusNode` 所在的整棵子树被卸载，焦点被框架上交到
///    FocusScope，表现就是方向键全部失灵；
/// 2. 老的大封面布局里，进度区的 `↑` 指向**自身**，即主体按键没有任何一条
///    边能走到顶部行 —— 顶部两个键只能靠彼此的左右键互达，一旦离开就回不去。
///
/// 现在三个键都挂在顶部（不随布局变化），链条为
/// `back ↔ fav ↔ more`，各自 `↓ → 进度区`，进度区 `↑ → fav`，
/// 因此「顶部 → 主体 → 顶部」始终闭环，任何布局、任何样式切换后都可达。
///
/// ⚠️ 收藏键在没有当前曲目时 `onPressed == null` → 不可聚焦（`canRequestFocus false`），
///    此时「返回」的右邻直接指向「更多」，不留悬空链节。
class _TopControls extends StatelessWidget {
  final Track? song;
  final bool fav;
  final FocusNode backNode;
  final FocusNode favNode;
  final FocusNode moreNode;
  final FocusNode seekNode;
  final VoidCallback onBack;
  final VoidCallback onMore;

  const _TopControls({
    required this.song,
    required this.fav,
    required this.backNode,
    required this.favNode,
    required this.moreNode,
    required this.seekNode,
    required this.onBack,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final Track? track = song;
    return Row(
      children: <Widget>[
        _RoundControl(
          node: backNode,
          debugLabel: 'player.back',
          icon: Icons.keyboard_arrow_down,
          iconSize: 28,
          size: 44,
          tooltip: '收起播放页',
          onPressed: onBack,
          nextLeft: backNode, // 左端：原地不动
          nextRight: track == null ? moreNode : favNode,
          nextUp: backNode,
          nextDown: seekNode,
        ),
        const Spacer(),
        _RoundControl(
          node: favNode,
          debugLabel: 'player.fav',
          icon: fav ? Icons.favorite : Icons.favorite_border,
          iconSize: 24,
          size: 44,
          iconColor: fav ? TvColors.brand : TvColors.textDim,
          tooltip: fav ? '取消收藏' : '收藏',
          onPressed: track == null
              ? null
              : () {
                  Log.i('UI 播放页 ${fav ? '取消收藏' : '收藏'} ${track.title}');
                  unawaited(
                    context
                        .read<LocalLibraryRepository>()
                        .toggleFavorite(track.guid),
                  );
                },
          nextLeft: backNode,
          nextRight: moreNode,
          nextUp: favNode, // 上方无可聚焦项：原地不动
          nextDown: seekNode,
        ),
        const SizedBox(width: 10),
        _RoundControl(
          node: moreNode,
          debugLabel: 'player.more',
          icon: Icons.more_vert,
          iconSize: 24,
          size: 44,
          iconColor: TvColors.textDim,
          tooltip: '更多（布局 / 歌词操作）',
          onPressed: onMore,
          nextLeft: track == null ? backNode : favNode,
          nextRight: moreNode, // 右端：原地不动
          nextUp: moreNode,
          nextDown: seekNode,
        ),
      ],
    );
  }
}

/// 歌曲信息行：歌名（可两行）+ 歌手。
///
/// 收藏 / 更多不在这里（见 [_TopControls]）：它们在顶部常驻，
/// 本行因此没有任何可聚焦控件，方向键不会停在这里（上方非焦点区）。
class _InfoRow extends StatelessWidget {
  final Track song;

  const _InfoRow({required this.song});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          song.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 26,
            height: 1.2, // 26×1.2≈32/行，固定预算（见文件头说明）
            fontWeight: FontWeight.w700,
            color: TvColors.text,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          song.artistNames.isEmpty ? song.album.name : song.artistNames,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            height: 1.2,
            color: TvColors.textDim,
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// 更多菜单（布局切换 / 歌词重试 / 队列信息）
// ═══════════════════════════════════════════════════════════════════

/// 「更多」菜单面板：替代旧底栏里的常驻「布局」胶囊。
///
/// - 数据全部来自真实仓储（队列信息 / 布局偏好 / 歌词重试），
///   不做任何装饰性按钮；
/// - 打开时焦点显式落在第一项（`autofocus` 在 ExcludeFocus 底下的
///   弹层里不可靠 —— 见 QueueSheet 同样的注释）；
/// - 关闭后由 [PlayerPage._closeMenu] 把焦点还给「更多」按钮。
class _MoreSheet extends StatefulWidget {
  final VoidCallback onClose;

  /// 由 [PlayerPage] 注入的真实动作（布局切换 / 歌词重载）。
  final VoidCallback onToggleLayout;
  final VoidCallback onReloadLyrics;

  const _MoreSheet({
    required this.onClose,
    required this.onToggleLayout,
    required this.onReloadLyrics,
  });

  @override
  State<_MoreSheet> createState() => _MoreSheetState();
}

class _MoreSheetState extends State<_MoreSheet> {
  final FocusNode _layoutNode = FocusNode(debugLabel: 'more.layout');
  final FocusNode _retryNode = FocusNode(debugLabel: 'more.retry');
  final FocusNode _closeNode = FocusNode(debugLabel: 'more.close');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _layoutNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _layoutNode.dispose();
    _retryNode.dispose();
    _closeNode.dispose();
    super.dispose();
  }

  Widget _item(
    FocusNode node, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    FocusNode? nextUp,
    FocusNode? nextDown,
  }) {
    return SizedBox(
      width: 340,
      child: TvFocus(
        focusNode: node,
        debugLabel: node.debugLabel,
        onPressed: onTap,
        nextUp: nextUp ?? node,
        nextDown: nextDown ?? node,
        builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
          status: s,
          radius: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          focusColor: const Color(0x2EFFFFFF),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 24, color: TvColors.text),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.2,
                    color: TvColors.text,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final LocalLibraryRepository local = context.read<LocalLibraryRepository>();
    final PlayerLayout layout = local.playerLayout;
    final String queueInfo = context.select<PlaybackRepository, String>(
      (PlaybackRepository p) =>
          '队列：${p.state.sourceLabel} · ${p.currentIndex + 1}/${p.queue.length}',
    );

    return Center(
      child: TvGlass(
        radius: 20,
        blur: false, // 面积大：不做实时模糊（V4 毛玻璃性能约定）
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 340,
              child: Text(
                queueInfo,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.2,
                  color: TvColors.textFaint,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _item(
              _layoutNode,
              icon: Icons.wallpaper,
              label: '切换布局（当前：${layout.shortLabel}）',
              onTap: () {
                widget.onToggleLayout();
                widget.onClose();
              },
              nextUp: _layoutNode,
              nextDown: _retryNode,
            ),
            const SizedBox(height: 8),
            _item(
              _retryNode,
              icon: Icons.refresh,
              label: '重新加载歌词',
              onTap: () {
                widget.onReloadLyrics();
                widget.onClose();
              },
              nextUp: _layoutNode,
              nextDown: _closeNode,
            ),
            const SizedBox(height: 8),
            _item(
              _closeNode,
              icon: Icons.close,
              label: '关闭菜单',
              onTap: widget.onClose,
              nextUp: _retryNode,
              nextDown: _closeNode,
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// 进度区（细线 + 小滑块）与传输控制（五个纯图标键）
// ═══════════════════════════════════════════════════════════════════

/// 进度 + 快退/快进（**组合控件**，整行一个焦点节点）。
///
/// ⚠️ 这是 V3 修好的关键路径，V6 只换外面版式、**不动语义**：
/// `←` / `→` 直接快退/快进 5 秒，`OK` 等价播放/暂停，
/// `↑` 回信息行（收藏键），`↓` 去控制区（模式键）。
///
/// 若把进度条拆成独立节点并允许它消费左右键，就必然出现
/// 「进了进度条只能按 BACK 出来的死区」—— V3 踩过，这里不复现。
class _SeekRow extends StatefulWidget {
  /// 本行的焦点节点（由 PlayerPage 创建，用于串联焦点链）。
  final FocusNode playbackNode;

  /// ↑ 的去处（顶部常驻行的收藏键；两种布局一致）。
  final FocusNode upNode;

  /// ↓ 的去处（控制区模式键）。
  final FocusNode downNode;

  const _SeekRow({
    required this.playbackNode,
    required this.upNode,
    required this.downNode,
  });

  @override
  State<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<_SeekRow> {
  /// 单次快退/快进。
  static const Duration _step = Duration(seconds: 5);

  /// 进度刷新定时器。⚠️ 必须取消（dispose 后 setState 会抛异常）。
  Timer? _ticker;

  /// 拖动中的本地值（拖动过程中不被外部 position 覆盖）。
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    // 只让这一小块每 400ms 重建 —— 控制键与歌词区完全不受影响。
    _ticker = Timer.periodic(
      const Duration(milliseconds: 400),
      (Timer _) {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _seekBy(int direction) {
    final p = context.read<PlaybackRepository>();
    Log.i('SEEK ${direction < 0 ? '快退' : '快进'} 5 秒');
    unawaited(p.seekRelative(_step * direction));
  }

  static String _fmt(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.read<PlaybackRepository>();
    final Duration pos = p.position ?? Duration.zero;
    final Duration dur = p.duration ?? Duration.zero;
    final double maxMs =
        dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
    final double shown =
        (_dragValue ?? pos.inMilliseconds.toDouble()).clamp(0.0, maxMs);
    // 音频规格：真实元数据小字（display 已按缺失字段自动省略）。
    final String spec =
        context.select<PlaybackRepository, Track?>(
              (PlaybackRepository p) => p.current,
            )
            ?.audioSpec
            .display ??
        '';

    return TvFocus(
      focusNode: widget.playbackNode,
      debugLabel: 'player.seek',
      // ⚠️ 左右键在这块是**进度操作**，不是焦点移动 —— 这正是需求里
      //    「明确设计的进度操作情形」。
      onArrowLeft: () => _seekBy(-1),
      onArrowRight: () => _seekBy(1),
      onPressed: () => unawaited(p.togglePlay()),
      nextUp: widget.upNode,
      nextDown: widget.downNode,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        focusColor: const Color(0x2EFFFFFF),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  _fmt(Duration(milliseconds: shown.round())),
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.2,
                    color: TvColors.textDim,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ExcludeFocus(
                    // 进度条自身**绝不获焦**：否则 Material 的 Slider 会吃掉
                    // 方向键，把焦点锁在进度条上（「进了进度区就出不来」的根因）。
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3, // 细线（视觉），焦点热区仍是整行
                        activeTrackColor: Colors.white.withValues(alpha: 0.9),
                        inactiveTrackColor: const Color(0x40FFFFFF),
                        thumbColor: Colors.white,
                        overlayShape: SliderComponentShape.noOverlay,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6),
                      ),
                      child: Slider(
                        value: shown,
                        max: maxMs,
                        onChanged: (double v) => setState(() => _dragValue = v),
                        // 只在拖动结束时 seek：拖动过程不产生播放请求。
                        onChangeEnd: (double v) {
                          Log.i('SEEK slider ${v.round()}ms');
                          unawaited(
                            p.seek(Duration(milliseconds: v.round())),
                          );
                          setState(() => _dragValue = null);
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _fmt(dur),
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.2,
                    color: TvColors.textDim,
                  ),
                ),
              ],
            ),
            if (spec.isNotEmpty) ...<Widget>[
              const SizedBox(height: 3),
              Text(
                spec,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  color: TvColors.textFaint,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 底部传输控制：模式 / 上一首 / 播放暂停 / 下一首 / 队列（纯图标）。
///
/// ⚠️ 播放态订阅收在这里：play/pause 切换只重建这一小块，
/// 封面、歌词、信息行的焦点节点都不受影响。
class _TransportControls extends StatelessWidget {
  final FocusNode modeNode;
  final FocusNode prevNode;
  final FocusNode playNode;
  final FocusNode nextNode;
  final FocusNode queueNode;
  final FocusNode seekNode;
  final VoidCallback onQueue;

  const _TransportControls({
    required this.modeNode,
    required this.prevNode,
    required this.playNode,
    required this.nextNode,
    required this.queueNode,
    required this.seekNode,
    required this.onQueue,
  });

  @override
  Widget build(BuildContext context) {
    final PlaybackRepository p = context.read<PlaybackRepository>();
    final bool playing = context.select<PlaybackRepository, bool>(
      (PlaybackRepository p) => p.isPlaying,
    );
    final PlayMode mode = context.select<PlaybackRepository, PlayMode>(
      (PlaybackRepository p) => p.mode,
    );
    // V5：是否有「上一首」由**播放历史**决定（不是队列下标）。
    final bool canPrevious = context.select<PlaybackRepository, bool>(
      (PlaybackRepository p) => p.hasPrevious,
    );

    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RoundControl(
          node: modeNode,
          debugLabel: 'player.mode',
          icon: _modeIcon(mode),
          iconSize: 26,
          size: 52,
          iconColor: TvColors.textDim,
          tooltip: '播放模式：${mode.label}',
          onPressed: () {
            // ⚠️ 用 `mode.next`：循环顺序是 `playback_control.dart` 里
            // 定义并注释的唯一一处，UI 不自己推一遍。
            final PlayMode nextMode = mode.next;
            Log.i('PLAY_MODE_CHANGE UI ${mode.storageKey} → '
                '${nextMode.storageKey}');
            unawaited(p.setMode(nextMode));
          },
          nextLeft: queueNode, // 左端环回队列（与屏幕顺序一致的两端环）
          nextRight: prevNode,
          nextUp: seekNode,
          nextDown: modeNode, // 最底部：原地不动
        ),
        const SizedBox(width: 18),
        _RoundControl(
          node: prevNode,
          debugLabel: 'player.prev',
          icon: Icons.skip_previous,
          iconSize: 30,
          size: 60,
          tooltip: canPrevious ? '上一首' : '没有上一首',
          iconColor: canPrevious ? TvColors.text : TvColors.textFaint,
          onPressed: () {
            Log.i('SKIP_PREVIOUS (player)');
            unawaited(p.previous());
          },
          nextLeft: modeNode,
          nextRight: playNode,
          nextUp: seekNode,
          nextDown: prevNode,
        ),
        const SizedBox(width: 22),
        _RoundControl(
          node: playNode,
          debugLabel: 'player.play',
          icon: playing ? Icons.pause : Icons.play_arrow,
          iconSize: 38,
          size: 76,
          tooltip: playing ? '暂停' : '播放',
          onPressed: () {
            Log.i('PLAY_TOGGLE (player) → ${playing ? '暂停' : '播放'}');
            unawaited(p.togglePlay());
          },
          nextLeft: prevNode,
          nextRight: nextNode,
          nextUp: seekNode,
          nextDown: playNode,
        ),
        const SizedBox(width: 22),
        _RoundControl(
          node: nextNode,
          debugLabel: 'player.next',
          icon: Icons.skip_next,
          iconSize: 30,
          size: 60,
          tooltip: '下一首',
          onPressed: () {
            Log.i('SKIP_NEXT (player)');
            unawaited(p.next());
          },
          nextLeft: playNode,
          nextRight: queueNode,
          nextUp: seekNode,
          nextDown: nextNode,
        ),
        const SizedBox(width: 18),
        _RoundControl(
          node: queueNode,
          debugLabel: 'player.queue',
          icon: Icons.format_list_bulleted,
          iconSize: 26,
          size: 52,
          iconColor: TvColors.textDim,
          tooltip: '打开当前播放队列',
          onPressed: onQueue,
          nextLeft: nextNode,
          nextRight: modeNode, // 右端环回模式
          nextUp: seekNode,
          nextDown: queueNode,
        ),
      ],
    );

    // 宽度不够（极小逻辑视口）时整体等比缩小，绝不静默裁切。
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.center,
      child: row,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// 基础控件
// ═══════════════════════════════════════════════════════════════════

/// 圆形/方形图标控制键（**纯图标、无底板**，聚焦时才出现细光环）。
///
/// ⚠️ **不要用 `ElevatedButton` / `IconButton`**：它们内部各自持有 FocusNode，
/// 与本组件的焦点节点互相打架，会出现「高亮在这个按钮上但 OK 按不动」
/// 或「按得动但没有高亮」—— 这正是 V3 修掉的故障。
class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.node,
    required this.debugLabel,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.nextLeft,
    this.nextRight,
    this.nextUp,
    this.nextDown,
    this.iconColor,
    this.size = 60,
    this.iconSize = 30,
  });

  final FocusNode node;
  final String debugLabel;
  final IconData icon;
  final String tooltip;

  /// null = 不可用（例如没有当前曲目时的收藏键）。
  final VoidCallback? onPressed;

  final Color? iconColor;
  final FocusNode? nextLeft;
  final FocusNode? nextRight;
  final FocusNode? nextUp;
  final FocusNode? nextDown;

  /// 控件边长（方形热区；光圈落点由 [TvFocusRing] 画在自身范围内）。
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: TvFocus(
        focusNode: node,
        debugLabel: debugLabel,
        onPressed: onPressed,
        canRequestFocus: onPressed != null,
        nextLeft: nextLeft,
        nextRight: nextRight,
        nextUp: nextUp,
        nextDown: nextDown,
        builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
          status: s,
          radius: size / 2,
          padding: EdgeInsets.zero,
          width: size,
          height: size,
          focusColor: const Color(0x2EFFFFFF),
          child: Icon(
            icon,
            size: iconSize,
            color: iconColor ?? TvColors.text,
          ),
        ),
      ),
    );
  }
}

/// 播放错误提示（解码失败 / 加载失败等）。
///
/// 只在**真的出错**时占一行；无错时 `SizedBox.shrink`，版面零扰动。
/// 信息行/队列序号等常规状态放进了「更多」菜单，错误却必须留在页面上 ——
/// 用户需要立刻知道「为什么没声音」。
class _ErrorLine extends StatelessWidget {
  const _ErrorLine();

  @override
  Widget build(BuildContext context) {
    final String? error = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.state.error,
    );
    if (error == null || error.isEmpty) return const SizedBox.shrink();
    return Text(
      error,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 14,
        height: 1.2,
        color: Color(0xFFFF8A8F),
      ),
    );
  }
}

/// 规格 / 属性小胶囊（仅旧「大封面」布局还在用）。
class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 16,
          color: TvColors.text,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

IconData _modeIcon(PlayMode m) => switch (m) {
      PlayMode.sequence => Icons.trending_flat,
      PlayMode.repeatAll => Icons.repeat,
      PlayMode.repeatOne => Icons.repeat_one,
      PlayMode.shuffle => Icons.shuffle,
    };
