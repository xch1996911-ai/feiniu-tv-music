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
import '../pages/collection_page.dart';
import '../pages/home_page.dart';
import '../pages/player_page.dart';
import '../pages/search_page.dart';
import '../pages/song_list_page.dart';
import '../widgets/mini_player.dart';
import '../widgets/nav_rail.dart';
import '../widgets/tv_focus.dart';
import 'shell_stage.dart';

/// 全局 App Shell：**主舞台**（参考图二的整体骨架）。
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
/// - 持有「当前舞台」与「播放页是否覆盖在上层」；
/// - 常驻 Mini Player；
/// - **不持有任何播放状态** —— 播放状态只在 `PlaybackRepository` 里。
///
/// ## 播放页打开时为什么要 `ExcludeFocus`
/// 播放页是覆盖在内容区之上的全屏层，底下的曲库列表**仍然挂在树上**。
/// 旧实现没有任何隔离，于是有两个真实故障：
/// 1. 方向键会跑到被完全遮住的列表项上（焦点「消失」在看不见的地方）；
/// 2. 从进度区按 ↑ 时可能被底层的某个节点接走，表现为「回不到播放控制区」。
///
/// 现在播放页打开时，整个底层（导航 + 内容 + Mini Player）都被
/// [ExcludeFocus] 排除出焦点树，播放页内部的三层焦点链因此是**闭合**的。
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

  late final List<FocusNode> _navNodes = List<FocusNode>.generate(
    _navItems.length,
    (int i) => FocusNode(debugLabel: 'nav.$i'),
  );
  final FocusNode _logoutNode = FocusNode(debugLabel: 'nav.logout');

  final FocusNode _searchNode = FocusNode(debugLabel: 'shell.search');
  final FocusNode _miniInfo = FocusNode(debugLabel: 'mini.info');
  final FocusNode _miniPrev = FocusNode(debugLabel: 'mini.prev');
  final FocusNode _miniPlay = FocusNode(debugLabel: 'mini.play');
  final FocusNode _miniNext = FocusNode(debugLabel: 'mini.next');

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
    _miniInfo.dispose();
    _miniPrev.dispose();
    _miniPlay.dispose();
    _miniNext.dispose();
    super.dispose();
  }

  /// 首屏引导：拉第一页曲库 → 建立播放队列（不自动播放）→ 定位上次播放点。
  ///
  /// 结尾**必须**显式给一个初始焦点：没有任何控件持有焦点时，
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
    // 焦点落在当前舞台对应的导航项上（启动时=首页）。
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
    setState(() => _stage = s);
    // 离开搜索页时它的 TextField 会被卸载，焦点随之丢失 ——
    // 必须补一个明确去处，否则遥控器会「静默失效」到下一次触碰为止。
    // 进入搜索页则不做（那里由输入框 autofocus 接管）。
    if (s == ShellStage.search) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _navNodes[_navIndex].requestFocus();
    });
  }

  void _openPlayer() {
    setState(() => _playerOpen = true);
  }

  void _closePlayer() {
    if (!_playerOpen) return;
    setState(() => _playerOpen = false);
    // 焦点回到可见的东西上：正在播放 → 底部播放条；否则 → 当前导航项。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      if (_playback.current != null && _miniPlay.canRequestFocus) {
        _miniPlay.requestFocus();
      } else {
        _navNodes[_navIndex].requestFocus();
      }
    });
  }

  /// 当前舞台在导航栏里的下标；-1 表示不在导航里（如「最近添加」「搜索」）。
  int get _navIndex {
    final int i = _navStages.indexOf(_stage);
    return i < 0 ? 0 : i;
  }

  int get _navSelected => _navStages.indexOf(_stage);

  @override
  Widget build(BuildContext context) {
    final bool atRoot = !_playerOpen && _stage == ShellStage.home;

    // Flutter 3.47 已废弃 WillPopScope，用 PopScope。
    // ⚠️ 只在这里注册**一个** PopScope：`PopScope.canPop` 是所有注册者的与运算，
    //    嵌套注册会让「关播放页」和「回首页」同时触发。
    return PopScope(
      canPop: atRoot,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        if (_playerOpen) {
          _closePlayer();
        } else {
          _goStage(ShellStage.home);
        }
      },
      child: Scaffold(
        backgroundColor: TvColors.bg,
        body: SafeArea(
          child: Stack(
            children: <Widget>[
              // ⚠️ ExcludeFocus 只包住**底层**（导航 + 内容 + Mini Player）。
              //    如果把 PlayerPage 也包进去，播放页自己的六个焦点节点会一并被
              //    排除，遥控器在播放页上会完全失灵。
              ExcludeFocus(
                excluding: _playerOpen,
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
                              infoNode: _miniInfo,
                              prevNode: _miniPrev,
                              playNode: _miniPlay,
                              nextNode: _miniNext,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_playerOpen) PlayerPage(onBack: _closePlayer),
            ],
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
      padding: const EdgeInsets.fromLTRB(26, 16, 26, 4),
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
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                baseColor: TvColors.panel,
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.search, size: 22, color: TvColors.textDim),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '搜索歌曲 / 歌手 / 专辑',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 18, color: TvColors.textFaint),
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
          const SizedBox(width: 16),
          if (user != null && user.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: TvColors.panel,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.person, size: 20, color: TvColors.ok),
                  const SizedBox(width: 8),
                  Text(
                    user,
                    style: const TextStyle(fontSize: 17, color: TvColors.textDim),
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
        return CollectionPage.grouped(
          title: '歌手',
          emptyHint: '曲库里还没有歌手信息。',
          buildGroups: LocalLibraryRepository.groupByArtist,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.albums:
        return CollectionPage.grouped(
          title: '专辑',
          emptyHint: '曲库里还没有专辑信息。',
          buildGroups: LocalLibraryRepository.groupByAlbum,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.genres:
        return CollectionPage.grouped(
          title: '风格',
          emptyHint: '曲库没有返回风格标签。\n\n'
              '飞牛曲目的 `genres` 字段在当前曲库里是空的，'
              '因此这个页面暂时没有内容 —— 这不是加载失败。',
          buildGroups: LocalLibraryRepository.groupByGenre,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.favorites:
        return CollectionPage.list(
          title: '收藏',
          emptyHint: '曲库里还没有被标记为收藏的歌曲。\n\n'
              '收藏状态由 NAS 返回（`isFavorite`），'
              '请在飞牛音乐里加心后再回到这里。',
          build: LocalLibraryRepository.favorites,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.recent:
        return CollectionPage.list(
          title: '最近播放',
          emptyHint: '本机还没有播放记录。\n\n'
              '飞牛没有提供播放历史接口，这里的记录由电视本机保存。',
          build: _local.recentTracks,
          onOpenPlayer: _openPlayer,
        );

      case ShellStage.recentAdded:
        return CollectionPage.list(
          title: '最近添加',
          emptyHint: '曲库没有返回「添加时间」，无法排序。',
          build: LocalLibraryRepository.recentlyAdded,
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
