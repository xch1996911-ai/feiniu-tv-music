import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../repositories/auth_repository.dart';
import '../repositories/music_repository.dart';
import '../repositories/library_repository.dart';
import '../repositories/local_library_repository.dart';
import '../repositories/lyric_repository.dart';
import '../repositories/playback_repository.dart';
import '../ui/pages/login_page.dart';
import '../ui/shell/app_shell.dart';
import 'theme.dart';

/// 应用根：装配 Provider 树 + 两态流程（登录 ⇄ 正式界面）。
///
/// ⚠️ **登录成功后没有任何中间页**。
///
/// 早期版本这里是 `login → status → shell` 三段式，中间的 `status` 是
/// Phase 1 用来验证「NAS 是否可达」的临时测试页（显示原始 JSON、
/// 还有个「进入歌曲列表」按钮）。正式版把它删掉了：
/// 用户登录成功后必须**直接落到首页**，不该再多点一次、
/// 更不该看到一屏调试信息。
///
/// 现在只剩两个状态，判定依据只有一条 —— `AuthRepository.isLoggedIn`：
/// - 已登录（含启动时从安全存储恢复的会话）→ [Stage.shell]；
/// - 未登录（或登出 / token 失效且无法自动重登）→ [Stage.login]。
class App extends StatelessWidget {
  final AuthRepository auth;
  final MusicRepository music;
  final PlaybackRepository playback;
  final LibraryRepository library;
  final LyricRepository lyrics;
  final LocalLibraryRepository local;

  const App({
    super.key,
    required this.auth,
    required this.music,
    required this.playback,
    required this.library,
    required this.lyrics,
    required this.local,
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
        ChangeNotifierProvider<LocalLibraryRepository>.value(value: local),
      ],
      child: MaterialApp(
        title: '飞牛 TV 音乐',
        debugShowCheckedModeBanner: false,
        // 与启动引导页共用同一套主题，避免引导页 → 主界面切换时样式跳变。
        theme: buildTvTheme(),
        home: const AppFlow(),
      ),
    );
  }
}

/// 应用阶段。只有两个 —— 要么在登录，要么已经在正式界面里。
enum Stage { login, shell }

class AppFlow extends StatefulWidget {
  const AppFlow({super.key});

  @override
  State<AppFlow> createState() => _AppFlowState();
}

class _AppFlowState extends State<AppFlow> {
  Stage _stage = Stage.login;

  /// 提前持有引用：`dispose()` 里再 `context.read` 会向上查 Provider，
  /// 而此时本节点正在被卸载，属于不安全的用法（可能抛异常）。
  late final AuthRepository _auth;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthRepository>();
    // 启动时已从安全存储恢复出会话（记住密码/记住登录）→ 直接进正式界面，
    // 不显示登录页。
    if (_auth.isLoggedIn) {
      _stage = Stage.shell;
    }
    _auth.addListener(_onAuthChange);
  }

  /// 登录态变化的**唯一**响应点：
  /// - 变成已登录（登录成功 / 自动重登成功）→ 进正式界面；
  /// - 变成未登录（主动登出 / token 失效且无法自动重登）→ 回登录页。
  ///
  /// 注意：监听回调可能在页面已卸载后才触发，必须先判 mounted。
  void _onAuthChange() {
    if (!mounted) return;
    final Stage target = _auth.isLoggedIn ? Stage.shell : Stage.login;
    if (_stage != target) {
      setState(() => _stage = target);
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case Stage.login:
        // 登录成功后由 _onAuthChange 统一切到 shell；
        // 这里也保留一个回调，保证「按钮点下去立刻有反馈」不依赖通知时序。
        return LoginPage(onLoggedIn: () {
          if (mounted && _stage != Stage.shell) {
            setState(() => _stage = Stage.shell);
          }
        });
      case Stage.shell:
        return const AppShell();
    }
  }
}
