import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../repositories/auth_repository.dart';
import '../repositories/music_repository.dart';
import '../repositories/library_repository.dart';
import '../repositories/lyric_repository.dart';
import '../repositories/playback_repository.dart';
import '../ui/pages/login_page.dart';
import '../ui/pages/server_status_page.dart';
import '../ui/shell/app_shell.dart';
import 'theme.dart';

/// 应用根：装配 Provider 树 + 线性流程（登录 → 状态 → 列表 → 播放）。
///
/// Phase 1 为临时验证 UI，采用最简线性 stage 切换而非完整路由；
/// 真实 TV 导航（Navigation Rail / Shelf）在 Phase 2 实现。
class App extends StatelessWidget {
  final AuthRepository auth;
  final MusicRepository music;
  final PlaybackRepository playback;
  final LibraryRepository library;
  final LyricRepository lyrics;

  const App({
    super.key,
    required this.auth,
    required this.music,
    required this.playback,
    required this.library,
    required this.lyrics,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthRepository>.value(value: auth),
        ChangeNotifierProvider<MusicRepository>.value(value: music),
        ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
        ChangeNotifierProvider<LibraryRepository>.value(value: library),
        ChangeNotifierProvider<LyricRepository>.value(value: lyrics),
      ],
      child: MaterialApp(
        title: '飞牛 TV 音乐',
        debugShowCheckedModeBanner: false,
        // 与启动引导页共用同一套主题，避免引导页 → 主界面切换时样式跳变。
        theme: buildTvTheme(),
        home: const Phase1Flow(),
      ),
    );
  }
}

/// 应用阶段。
///
/// V2 把 `songs` / `player` 合并为 [Stage.shell]：
/// 曲库、搜索、播放页之间的切换交给 [AppShell]，
/// 这样 Mini Player 能**跨页面常驻**（放在 Shell 上而不是各页面里）。
enum Stage { login, status, shell }

class Phase1Flow extends StatefulWidget {
  const Phase1Flow({super.key});

  @override
  State<Phase1Flow> createState() => _Phase1FlowState();
}

class _Phase1FlowState extends State<Phase1Flow> {
  Stage _stage = Stage.login;

  /// 提前持有引用：`dispose()` 里再 `context.read` 会向上查 Provider，
  /// 而此时本节点正在被卸载，属于不安全的用法（可能抛异常）。
  late final AuthRepository _auth;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthRepository>();
    if (_auth.isLoggedIn) {
      _stage = Stage.status;
    }
    _auth.addListener(_onAuthChange);
  }

  void _onAuthChange() {
    // 登出 / token 失效清理 → 回到登录页。
    // 注意：监听回调可能在页面已卸载后才触发，必须先判 mounted。
    if (!mounted) {
      return;
    }
    if (!_auth.isLoggedIn && _stage != Stage.login) {
      setState(() => _stage = Stage.login);
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChange);
    super.dispose();
  }

  void _go(Stage s) => setState(() => _stage = s);

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case Stage.login:
        return LoginPage(onLoggedIn: () => _go(Stage.status));
      case Stage.status:
        return ServerStatusPage(
          onContinue: () => _go(Stage.shell),
          onBack: () => _go(Stage.login),
        );
      case Stage.shell:
        return const AppShell();
    }
  }
}
