import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/diagnostics.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/auth_repository.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../pages/diagnostics_page.dart';
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
import '../../services/remote/remote_server.dart';
import '../pages/remote_control_page.dart';
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

  /// 诊断与帮助是否打开（V5：技术细节的唯一去处）。
  bool _diagOpen = false;

  /// 手机遥控是否打开（V5 §七）。
  bool _remoteOpen = false;

  /// 手机遥控服务。**由 Shell 持有**（而不是页面）：
  /// 手机扫码后要能持续控制，用户离开这个页面（比如去看播放队列）
  /// 不该把手机踢下线。
  RemoteControlServer? _remote;

  /// 歌手 / 专辑 / 风格 里点开的那条概览详情；null = 正在看概览。
  LibraryOverview? _openOverview;

  /// 进入播放页前持有焦点的节点，用于「返回时恢复到进入前的位置」。
  FocusNode? _focusBeforePlayer;

  late final List<FocusNode> _navNodes = List<FocusNode>.generate(
    _navItems.length,
    (int i) => FocusNode(debugLabel: 'nav.$i'),
  );
  final FocusNode _logoutNode = FocusNode(debugLabel: 'nav.logout');
  final FocusNode _diagNode = FocusNode(debugLabel: 'nav.diagnostics');
  final FocusNode _remoteNode = FocusNode(debugLabel: 'nav.remote');

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

  /// 上次已喂给播放队列的曲目数（避免每次通知都重复 append）。
  int _indexSyncedCount = -1;

  @override
  void initState() {
    super.initState();
    _library = context.read<LibraryRepository>();
    _playback = context.read<PlaybackRepository>();
    _local = context.read<LocalLibraryRepository>();
    _auth = context.read<AuthRepository>();

    _playback.addListener(_onPlaybackChanged);
    _library.addListener(_onLibraryChanged);
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
    _library.removeListener(_onLibraryChanged);
    for (final FocusNode n in _navNodes) {
      n.dispose();
    }
    _logoutNode.dispose();
    _diagNode.dispose();
    _remoteNode.dispose();
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
  /// ⚠️ V5：这里**只负责「尽快有东西可看」**，不再负责「把曲库拉全」。
  /// 全库整理由 `LibraryRepository.startSync()` 在登录后立即启动
  /// （见 `boot_screen.dart`），与用户是否打开音乐库、是否滚动列表**无关**。
  /// 整理完成后本页会收到通知并把新曲目**追加**进队列（不打断当前播放）。
  ///
  /// 结尾**必须**显式给初始焦点：没有任何控件持有焦点时，
  /// 遥控器第一次按方向键会「没反应」（框架没有起点可移动），
  /// 用户会直接判定「遥控器坏了」。
  Future<void> _bootstrap() async {
    // 兜底：如果启动时还没登录（登录页进来），登录成功后再触发一次整理。
    if (_auth.isLoggedIn && !_library.syncStatus.syncing &&
        _library.tracks.isEmpty) {
      unawaited(_library.startSync(_auth.catalogueIdentity));
    }

    await _library.loadFirst();
    if (!mounted) return;
    _playback.adoptQueue(_library.tracks);
    if (_playback.current == null && _playback.pendingRestoreGuid != null) {
      if (_playback.restoreToTrack(_library.tracks)) {
        Log.i('STATE_RESTORE UI 已定位上次播放（不自动播放）');
      }
    }
    // 收藏：首次把服务端 isFavorite 播种进本机集合（只做一次）。
    // ⚠️ 用**已索引的全部曲目**播种，而不是首屏 50 首 ——
    //    否则服务端收藏超过 50 首时，前 50 首之外的收藏会被永久漏掉
    //    （播种只做一次，之后本机集合即唯一数据源）。
    await _local.seedFavoritesIfNeeded(_library.tracks);
    if (!mounted) return;
    _navNodes[_navIndex].requestFocus();
  }

  /// 曲库整理推进 → 把新索引到的曲目**追加**进队列（不移动 currentIndex）。
  ///
  /// 两条硬约束：
  /// 1. 需求 §三-A.10：全库索引**不得**把整个曲库替换进当前播放队列。
  ///    这里用 [PlaybackRepository.appendToQueue]（只增不改），
  ///    正在播的那首与被用户选定的起点都不受影响；
  /// 2. 只有「队列本来就来自曲库」时才追加 —— 否则会把整张曲库
  ///    混进搜索结果队列或某个歌手的详情队列里。
  ///
  /// 追加的是**全部已索引曲目**而不是「新增的几首」：`appendToQueue`
  /// 自己按 guid 去重，重复调用是幂等的。
  void _onLibraryChanged() {
    if (!mounted) return;
    if (!_library.indexComplete) return; // 半成品不喂队列
    if (_indexSyncedCount == _library.tracks.length) return; // 无变化
    final QueueSource src = _playback.source;
    if (src != QueueSource.library && src != QueueSource.restored) return;    _indexSyncedCount = _library.tracks.length;
    final int total = _playback.appendToQueue(_library.tracks);
    Log.i('QUEUE_APPEND 曲库整理推进 → 队列 $total 首');
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

  // ── 诊断与帮助 ────────────────────────────────────────────

  void _openDiagnostics() {
    Log.i('UI 打开诊断与帮助');
    _focusBeforePlayer = FocusManager.instance.primaryFocus;
    setState(() => _diagOpen = true);
  }

  // ── 手机遥控 ──────────────────────────────────────────────

  Future<void> _openRemote() async {
    Log.i('UI 打开手机遥控');
    final RemoteControlServer server =
        _remote ??= RemoteControlServer(
      playback: _playback,
      music: context.read<MusicRepository>(),
      library: _library,
      local: _local,
    );
    if (!server.isRunning) {
      final int? port = await server.start();
      if (port == null) {
        Diagnostics.event('遥控服务启动失败：端口被占用或权限不足');
      }
    }
    if (!mounted) return;
    _focusBeforePlayer = FocusManager.instance.primaryFocus;
    setState(() => _remoteOpen = true);
  }

  void _closeRemote() {
    if (!_remoteOpen) return;
    setState(() => _remoteOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      final FocusNode? before = _focusBeforePlayer;
      if (before != null && before.canRequestFocus) {
        before.requestFocus();
      } else {
        _navNodes[_navIndex].requestFocus();
      }
      _focusBeforePlayer = null;
    });
  }

  void _closeDiagnostics() {
    if (!_diagOpen) return;
    setState(() => _diagOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      final FocusNode? before = _focusBeforePlayer;
      if (before != null && before.canRequestFocus) {
        before.requestFocus();
      } else {
        _navNodes[_navIndex].requestFocus();
      }
      _focusBeforePlayer = null;
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
    final bool overlayOpen =
        _playerOpen || _queueOpen || _diagOpen || _remoteOpen;
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
        if (_remoteOpen) {
          _closeRemote();
        } else if (_diagOpen) {
          _closeDiagnostics();
        } else if (_queueOpen) {
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
                        diagnosticsNode: _diagNode,
                        remoteNode: _remoteNode,
                        onSelected: (int i) => _goStage(_navStages[i]),
                        onLogout: _logout,
                        onDiagnostics: _openDiagnostics,
                        onRemote: _openRemote,
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
                if (_remoteOpen && _remote != null)
                  Positioned.fill(
                    child: RemoteControlPage(
                      server: _remote!,
                      onBack: _closeRemote,
                    ),
                  ),
                if (_diagOpen)
                  Positioned.fill(
                    child: ColoredBox(
                      color: TvColors.bg,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: DiagnosticsPage(
                            onRebuildIndex: () => _library.rebuildIndex(),
                          ),
                        ),
                      ),
                    ),
                  ),
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
    // 需求 §七.9：退出登录后旧手机会话必须立即失效。
    // 停止服务会一并 revoke 会话（见 RemoteControlServer.stop）。
    await _remote?.stop(reason: '退出登录');
    _remote = null;
    await _auth.logout();
  }

  // ── 顶部搜索栏 ─────────────────────────────────────────────
  Widget _buildTopBar() {
    final String? user = context.select<AuthRepository, String?>(
      (AuthRepository a) => a.username,
    );
    // 曲库整理进度。**只有正在整理时才出现**，完成后自动消失 ——
    // 需求要求「提供简短的『正在整理曲库：已处理 X 首』状态」，
    // 但整页不该常年挂着一个技术状态条。
    final CatalogueSyncStatus sync = context.select<LibraryRepository,
        CatalogueSyncStatus>((LibraryRepository l) => l.syncStatus);

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TvFocus(
              focusNode: _searchNode,
              debugLabel: 'shell.search',
              onPressed: () => _goStage(ShellStage.search),
              builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
                status: s,
                radius: 22,
                padding: EdgeInsets.zero,
                child: TvGlass(
                  radius: 22,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.search, size: 20, color: TvColors.textDim),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          '搜索歌曲 / 歌手 / 专辑',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 17, color: TvColors.textFaint),
                        ),
                      ),
                      Text(
                        '按 OK 进入搜索',
                        style: TextStyle(
                          fontSize: 13,
                          color: TvColors.textFaint.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (sync.syncing)
            TvGlass(
              radius: 22,
              blur: false,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: <Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(TvColors.accent),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    sync.label,
                    style: const TextStyle(
                        fontSize: 15, color: TvColors.textDim),
                  ),
                ],
              ),
            ),
          if (sync.syncing) const SizedBox(width: 12),
          if (user != null && user.isNotEmpty)
            TvGlass(
              radius: 22,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.person, size: 18, color: TvColors.ok),
                  const SizedBox(width: 8),
                  Text(
                    user,
                    style: const TextStyle(
                        fontSize: 16, color: TvColors.textDim),
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
          // ⚠️ 必须带 key：三个分类共用 OverviewPage 这一个 Widget 类型、
          //    又在同一个槽位（Expanded(child: _buildStage())）里切换 ——
          //    不带 key 时 Flutter 会**复用同一个 State**，而概览页内部按
          //    `identical(曲库实例)` 缓存分组结果，曲库实例三页共享同一份 ⇒
          //    从「风格」切到「歌手」时直接命中缓存，把风格分组原样显示在
          //    歌手页上（实机现象：先看风格再看歌手，页面内容不换；
          //    重新进音乐库才恢复 —— 因为那会换成 SongListPage，State 被销毁）。
          //    带 key 后每个分类有**自己的 State**，互不串。
          key: const ValueKey<OverviewKind>(OverviewKind.artist),
          kind: OverviewKind.artist,
          title: '歌手',
          // ⚠️ V5：空态文案只留一句短的。
          //    技术解读（`artists` 字段为空、接口返回什么）一律进诊断页
          //    （见 `lib/core/diagnostics.dart`）。
          emptyHint: '暂无歌手',
          detail: _openOverview,
          onOpenDetail: _openDetail,
          onCloseDetail: _closeDetail,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.albums:
        return OverviewPage(
          key: const ValueKey<OverviewKind>(OverviewKind.album),
          kind: OverviewKind.album,
          title: '专辑',
          emptyHint: '暂无专辑',
          detail: _openOverview,
          onOpenDetail: _openDetail,
          onCloseDetail: _closeDetail,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.genres:
        return OverviewPage(
          key: const ValueKey<OverviewKind>(OverviewKind.genre),
          kind: OverviewKind.genre,
          title: '风格',
          // 风格页现在有自动归纳兜底，只有「曲库为空」才会走到这个文案。
          emptyHint: '暂无歌曲',
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
          key: const ValueKey<TrackListSource>(TrackListSource.recent),
          source: TrackListSource.recent,
          title: '最近播放',
          emptyIcon: Icons.history,
          // 短文案 + 一个可聚焦的操作。原因说明在诊断页。
          emptyText: '暂无最近播放',
          emptyActionLabel: '去音乐库',
          onEmptyAction: () => _goStage(ShellStage.library),
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.recentAdded:
        return TrackListPage(
          key: const ValueKey<TrackListSource>(TrackListSource.recentlyAdded),
          source: TrackListSource.recentlyAdded,
          title: '最近添加',
          emptyIcon: Icons.fiber_new,
          emptyText: '暂无最近添加',
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
