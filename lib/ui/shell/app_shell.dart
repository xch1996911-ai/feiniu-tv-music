import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../repositories/auth_repository.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/playback_repository.dart';
import '../pages/favorites_page.dart';
import '../pages/home_page.dart';
import '../pages/overview_page.dart';
import '../pages/player_page.dart';
import '../pages/search_page.dart';
import '../pages/song_list_page.dart';
import '../pages/track_list_page.dart';
import '../widgets/mini_player.dart';
import '../widgets/nav_rail.dart';
import '../widgets/queue_sheet.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_glass.dart';
import 'shell_stage.dart';

/// 全局 App Shell：**主舞台**。
///
/// ```
/// ┌──────────┬──────────────────────────────────────────────┐
/// │ 飞牛音乐  │  [🔍 搜索歌曲 / 歌手 / 专辑]        [已连接] │
/// │          ├──────────────────────────────────────────────┤
/// │ 首页     │                                              │
/// │ 音乐库   │              当前舞台内容                     │
/// │ 歌手     │                                              │
/// │ 专辑     │                                              │
/// │ 风格     │                                              │
/// │ 收藏     │                                              │
/// │ 最近     │                                              │
/// │ ──────── │                                              │
/// │ 退出登录  │  ┌─────────── Mini Player ───────────────┐   │
/// └──────────┴──────────────────────────────────────────────┘
/// ```
///
/// ## 职责
/// - 持有「当前舞台」「播放页是否覆盖在上层」「概览详情」「队列面板是否打开」；
/// - 常驻 Mini Player；
/// - **不持有任何播放状态** —— 播放状态只在 `PlaybackRepository` 里。
///
/// ## 为什么这些「二级状态」都放在 Shell
/// `PopScope` 的 `canPop` 是**所有注册者的与运算**，嵌套注册会让
/// 「关队列」「关播放页」「关详情」「回首页」同时触发。
/// 因此全 App 只保留**这一个** PopScope，回到哪一层由这里统一裁决。
///
/// ## 覆盖面时为什么要 `ExcludeFocus`
/// 播放页 / 队列面板都是覆盖层，底下的曲库列表**仍然挂在树上**。
/// 不作隔离会有两个真实故障：
/// 1. 方向键跑到被完全遮住的列表项上（焦点「消失」在看不见的地方）；
/// 2. 从进度区按 ↑ 时可能被底层某个节点接走，表现为「回不到播放控制区」。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const List<NavRailItem> _navItems = <NavRailItem>[
    NavRailItem(icon: Icons.home_outlined, label: '首页'),
    NavRailItem(icon: Icons.library_music_outlined, label: '音乐库'),
    NavRailItem(icon: Icons.person_outline, label: '歌手'),
    NavRailItem(icon: Icons.album_outlined, label: '专辑'),
    NavRailItem(icon: Icons.grid_view_outlined, label: '风格'),
    NavRailItem(icon: Icons.favorite_border, label: '收藏'),
    NavRailItem(icon: Icons.history, label: '最近'),
  ];

  /// 导航下标 → 舞台。顺序必须与 [_navItems] 一致。
  static const List<ShellStage> _navStages = <ShellStage>[
    ShellStage.home,
    ShellStage.library,
    ShellStage.artists,
    ShellStage.albums,
    ShellStage.genres,
    ShellStage.favorites,
    ShellStage.recent,
  ];

  ShellStage _stage = ShellStage.home;

  /// 全屏播放页是否覆盖在上层。
  bool _playerOpen = false;

  /// 队列面板是否打开（迷你播放器 / 播放页共用同一份队列）。
  bool _queueOpen = false;

  /// 歌手 / 专辑 / 风格 里点开的那条概览详情；null = 正在看概览。
  LibraryOverview? _openOverview;

  /// 进入播放页前持有焦点的节点，用于「返回时恢复到进入前的位置」。
  FocusNode? _focusBeforePlayer;

  late final List<FocusNode> _navNodes = List<FocusNode>.generate(
    _navItems.length,
    (int i) => FocusNode(debugLabel: 'nav.$i'),
  );
  final FocusNode _logoutNode = FocusNode(debugLabel: 'nav.logout');

  final FocusNode _searchNode = FocusNode(debugLabel: 'shell.search');
  final FocusNode _miniCover = FocusNode(debugLabel: 'mini.cover');
  final FocusNode _miniPrev = FocusNode(debugLabel: 'mini.prev');
  final FocusNode _miniPlay = FocusNode(debugLabel: 'mini.play');
  final FocusNode _miniNext = FocusNode(debugLabel: 'mini.next');
  final FocusNode _miniQueue = FocusNode(debugLabel: 'mini.queue');

  late final LibraryRepository _library;
  late final PlaybackRepository _playback;
  late final LocalLibraryRepository _local;
  late final AuthRepository _auth;

  /// 上次已记录进「最近播放」的 guid（去重，避免进度刷新反复写盘）。
  String? _recordedGuid;

  /// 定期把「上次播放到哪」落盘，供下次启动恢复。
  Timer? _restoreTimer;

  @override
  void initState() {
    super.initState();
    _library = context.read<LibraryRepository>();
    _playback = context.read<PlaybackRepository>();
    _local = context.read<LocalLibraryRepository>();
    _auth = context.read<AuthRepository>();

    _playback.addListener(_onPlaybackChanged);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _bootstrap());

    // 15 秒存一次播放点：太频繁会反复写安全存储，太稀疏则「看到一半关机」丢得多。
    _restoreTimer = Timer.periodic(const Duration(seconds: 15), (Timer _) {
      if (_playback.current == null) return;
      unawaited(_playback.saveRestorePoint());
    });
  }

  @override
  void dispose() {
    _restoreTimer?.cancel();
    _playback.removeListener(_onPlaybackChanged);
    for (final FocusNode n in _navNodes) {
      n.dispose();
    }
    _logoutNode.dispose();
    _searchNode.dispose();
    _miniCover.dispose();
    _miniPrev.dispose();
    _miniPlay.dispose();
    _miniNext.dispose();
    _miniQueue.dispose();
    super.dispose();
  }

  /// 首屏引导：拉第一页曲库 → 建立播放队列（不自动播放）→ 定位上次播放点
  /// → 首次播种收藏 → 给一个初始焦点。
  ///
  /// 结尾**必须**显式给初始焦点：没有任何控件持有焦点时，
  /// 遥控器第一次按方向键会「没反应」（框架没有起点可移动），
  /// 用户会直接判定「遥控器坏了」。
  Future<void> _bootstrap() async {
    await _library.loadFirst();
    if (!mounted) return;
    _playback.adoptQueue(_library.tracks);
    if (_playback.current == null && _playback.pendingRestoreGuid != null) {
      if (_playback.restoreToTrack(_library.tracks)) {
        Log.i('STATE_RESTORE UI 已定位上次播放（不自动播放）');
      }
    }
    // 收藏：首次把服务端 isFavorite 播种进本机集合（只做一次）。
    await _local.seedFavoritesIfNeeded(_library.tracks);
    if (!mounted) return;
    _navNodes[_navIndex].requestFocus();
  }

  /// 播放仓储任何变化都会进来：只在**换歌**时记一次收听历史。
  void _onPlaybackChanged() {
    final Track? t = _playback.current;
    if (t == null) return;
    if (_recordedGuid == t.guid) return;
    _recordedGuid = t.guid;
    _local.recordPlayed(t.guid);
  }

  void _goStage(ShellStage s) {
    if (_stage == s) return;
    setState(() {
      _stage = s;
      // 换页必然离开原来的概览详情。
      _openOverview = null;
    });
    // 离开搜索页时它的 TextField 会被卸载，焦点随之丢失 ——
    // 必须补一个明确去处，否则遥控器会「静默失效」到下一次触碰为止。
    // 进入搜索页则不做（那里由输入框 autofocus 接管）。
    if (s == ShellStage.search) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _navNodes[_navIndex].requestFocus();
    });
  }

  // ── 概览详情 ──────────────────────────────────────────────

  void _openDetail(LibraryOverview o) {
    setState(() => _openOverview = o);
  }

  void _closeDetail() {
    if (_openOverview == null) return;
    setState(() => _openOverview = null);
    // 焦点交还给概览页 —— 它自己会把焦点还给原来那一行并滚回原位置
    // （见 `OverviewPage.didUpdateWidget`）。
  }

  // ── 播放页 ────────────────────────────────────────────────

  void _openPlayer() {
    _focusBeforePlayer = FocusManager.instance.primaryFocus;
    setState(() => _playerOpen = true);
  }

  void _closePlayer() {
    if (!_playerOpen) return;
    setState(() => _playerOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      // 回到**进入播放页之前**的焦点位置；拿不到就退回到迷你播放器封面。
      final FocusNode? before = _focusBeforePlayer;
      if (before != null && before.canRequestFocus) {
        before.requestFocus();
      } else if (_playback.current != null && _miniCover.canRequestFocus) {
        _miniCover.requestFocus();
      } else {
        _navNodes[_navIndex].requestFocus();
      }
      _focusBeforePlayer = null;
    });
  }

  // ── 队列面板 ──────────────────────────────────────────────

  void _openQueue() {
    Log.i('UI 打开播放队列 (shell)');
    setState(() => _queueOpen = true);
  }

  void _closeQueue() {
    if (!_queueOpen) return;
    setState(() => _queueOpen = false);
    // 关闭后焦点回迷你播放器的队列按钮。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      if (_miniQueue.canRequestFocus) {
        _miniQueue.requestFocus();
      } else {
        _navNodes[_navIndex].requestFocus();
      }
    });
  }

  /// 当前舞台在导航栏里的下标；不在导航里（最近添加 / 搜索）时回落到首页。
  int get _navIndex {
    final int i = _navStages.indexOf(_stage);
    return i < 0 ? 0 : i;
  }

  int get _navSelected => _navStages.indexOf(_stage);

  @override
  Widget build(BuildContext context) {
    final bool overlayOpen = _playerOpen || _queueOpen;
    final bool atRoot =
        !overlayOpen && _openOverview == null && _stage == ShellStage.home;

    // Flutter 3.47 已废弃 WillPopScope，用 PopScope。
    // ⚠️ 只在这里注册**一个** PopScope：`PopScope.canPop` 是所有注册者的与运算，
    //    嵌套注册会让「关播放页」和「回首页」同时触发。
    return PopScope(
      canPop: atRoot,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        // 由内到外逐层关闭，每次只关一层。
        if (_queueOpen) {
          _closeQueue();
        } else if (_playerOpen) {
          _closePlayer();
        } else if (_openOverview != null) {
          _closeDetail();
        } else {
          _goStage(ShellStage.home);
        }
      },
      child: Scaffold(
        backgroundColor: TvColors.bg,
        body: DecoratedBox(
          // 柔和的深蓝紫渐变底：毛玻璃面板透出层次感，
          // 比纯色底更接近参考图的观感（也让「玻璃」有东西可透）。
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFF171730), Color(0xFF0A0A12)],
            ),
          ),
          child: SafeArea(
            child: Stack(
              children: <Widget>[
                // ⚠️ ExcludeFocus 只包住**底层**（导航 + 内容 + Mini Player）。
                //    如果把覆盖层也包进去，它自己的焦点节点会被一并排除，
                //    遥控器在覆盖层上会完全失灵。
                ExcludeFocus(
                  excluding: overlayOpen,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      NavRail(
                        items: _navItems,
                        selected: _navSelected,
                        nodes: _navNodes,
                        logoutNode: _logoutNode,
                        onSelected: (int i) => _goStage(_navStages[i]),
                        onLogout: _logout,
                      ),
                      Expanded(
                        child: Column(
                          children: <Widget>[
                            if (_stage != ShellStage.search) _buildTopBar(),
                            Expanded(child: _buildStage()),
                            if (_hasSong)
                              MiniPlayer(
                                onOpenPlayer: _openPlayer,
                                onOpenQueue: _openQueue,
                                coverNode: _miniCover,
                                prevNode: _miniPrev,
                                playNode: _miniPlay,
                                nextNode: _miniNext,
                                queueNode: _miniQueue,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_playerOpen) PlayerPage(onBack: _closePlayer),
                if (_queueOpen) QueueSheet(onClose: _closeQueue),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _hasSong => context.select<PlaybackRepository, bool>(
        (PlaybackRepository p) => p.current != null,
      );

  Future<void> _logout() async {
    Log.i('UI 退出登录');
    await _auth.logout();
  }

  // ── 顶部搜索栏 ─────────────────────────────────────────────
  Widget _buildTopBar() {
    final String? user = context.select<AuthRepository, String?>(
      (AuthRepository a) => a.username,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 14, 26, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TvFocus(
              focusNode: _searchNode,
              debugLabel: 'shell.search',
              onPressed: () => _goStage(ShellStage.search),
              builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
                status: s,
                radius: 24,
                padding: EdgeInsets.zero,
                child: TvGlass(
                  radius: 24,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.search, size: 22, color: TvColors.textDim),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          '搜索歌曲 / 歌手 / 专辑',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 18, color: TvColors.textFaint),
                        ),
                      ),
                      Text(
                        '按 OK 进入搜索',
                        style: TextStyle(
                          fontSize: 14,
                          color: TvColors.textFaint.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          if (user != null && user.isNotEmpty)
            TvGlass(
              radius: 24,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.person, size: 20, color: TvColors.ok),
                  const SizedBox(width: 8),
                  Text(
                    user,
                    style: const TextStyle(
                        fontSize: 17, color: TvColors.textDim),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── 主舞台内容 ─────────────────────────────────────────────
  Widget _buildStage() {
    switch (_stage) {
      case ShellStage.home:
        return HomePage(
          onOpenPlayer: _openPlayer,
          onOpenStage: _goStage,
        );

      case ShellStage.library:
        return SongListPage(onOpenPlayer: _openPlayer);

      case ShellStage.artists:
        return OverviewPage(
          kind: OverviewKind.artist,
          title: '歌手',
          emptyHint: '曲库里还没有歌手信息。',
          detail: _openOverview,
          onOpenDetail: _openDetail,
          onCloseDetail: _closeDetail,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.albums:
        return OverviewPage(
          kind: OverviewKind.album,
          title: '专辑',
          emptyHint: '曲库里还没有专辑信息。',
          detail: _openOverview,
          onOpenDetail: _openDetail,
          onCloseDetail: _closeDetail,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.genres:
        return OverviewPage(
          kind: OverviewKind.genre,
          title: '风格',
          emptyHint: '暂无风格标签\n\n'
              '飞牛曲目的 `genres` 字段在当前曲库里是空的，'
              '因此这个页面暂时没有内容 —— 这不是加载失败，'
              '也不会把全部歌曲硬塞进「未知风格」。',
          detail: _openOverview,
          onOpenDetail: _openDetail,
          onCloseDetail: _closeDetail,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.favorites:
        return FavoritesPage(
          onOpenPlayer: _openPlayer,
          onOpenLibrary: () => _goStage(ShellStage.library),
        );

      case ShellStage.recent:
        return TrackListPage(
          source: TrackListSource.recent,
          title: '最近播放',
          emptyIcon: Icons.history,
          emptyText: '暂无最近播放\n\n'
              '飞牛没有提供播放历史接口，这里的记录由电视本机保存。\n'
              '从「音乐库」里挑一首开始播放，这里就会留下痕迹。',
          emptyActionLabel: '去音乐库',
          onEmptyAction: () => _goStage(ShellStage.library),
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.recentAdded:
        return TrackListPage(
          source: TrackListSource.recentlyAdded,
          title: '最近添加',
          emptyIcon: Icons.fiber_new,
          emptyText: '暂无「最近添加」\n\n'
              '曲库没有返回曲目的添加时间（`createdAt`），无法排序。',
          emptyActionLabel: '去音乐库',
          onEmptyAction: () => _goStage(ShellStage.library),
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.search:
        return SearchPage(
          onBack: () => _goStage(ShellStage.home),
          onOpenPlayer: _openPlayer,
        );
    }
  }
}
