import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../repositories/auth_repository.dart';
import '../repositories/music_repository.dart';
import '../repositories/playback_repository.dart';
import '../ui/pages/login_page.dart';
import '../ui/pages/player_page.dart';
import '../ui/pages/server_status_page.dart';
import '../ui/pages/song_list_page.dart';

/// 应用根：装配 Provider 树 + 线性流程（登录 → 状态 → 列表 → 播放）。
///
/// Phase 1 为临时验证 UI，采用最简线性 stage 切换而非完整路由；
/// 真实 TV 导航（Navigation Rail / Shelf）在 Phase 2 实现。
class App extends StatelessWidget {
  final AuthRepository auth;
  final MusicRepository music;
  final PlaybackRepository playback;

  const App({
    super.key,
    required this.auth,
    required this.music,
    required this.playback,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthRepository>.value(value: auth),
        ChangeNotifierProvider<MusicRepository>.value(value: music),
        ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
      ],
      child: MaterialApp(
        title: '飞牛 TV 音乐',
        debugShowCheckedModeBanner: false,
        theme: _tvTheme(),
        home: const Phase1Flow(),
      ),
    );
  }

  ThemeData _tvTheme() => ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0B0F),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 18),
          titleMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          titleLarge: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4F8CFF),
          surface: Color(0xFF15151C),
        ),
      );
}

enum Stage { login, status, songs, player }

class Phase1Flow extends StatefulWidget {
  const Phase1Flow({super.key});

  @override
  State<Phase1Flow> createState() => _Phase1FlowState();
}

class _Phase1FlowState extends State<Phase1Flow> {
  Stage _stage = Stage.login;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthRepository>();
    if (auth.isLoggedIn) _stage = Stage.status;
    auth.addListener(_onAuthChange);
  }

  void _onAuthChange() {
    final auth = context.read<AuthRepository>();
    // 登出 / token 失效清理 → 回到登录页。
    if (!auth.isLoggedIn && _stage != Stage.login) {
      setState(() => _stage = Stage.login);
    }
  }

  @override
  void dispose() {
    context.read<AuthRepository>().removeListener(_onAuthChange);
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
          onContinue: () => _go(Stage.songs),
          onBack: () => _go(Stage.login),
        );
      case Stage.songs:
        return SongListPage(
          onPick: () => _go(Stage.player),
          onBack: () => _go(Stage.status),
        );
      case Stage.player:
        return PlayerPage(onBack: () => _go(Stage.songs));
    }
  }
}
