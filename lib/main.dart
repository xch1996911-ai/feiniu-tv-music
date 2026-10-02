import 'package:flutter/material.dart';

import 'app/app.dart';
import 'playback/media_session_service.dart';
import 'repositories/auth_repository.dart';
import 'repositories/music_repository.dart';
import 'repositories/playback_repository.dart';

/// 入口。
///
/// 启动顺序（technical_research.md 决策 D3：认证先行）：
/// 1. 初始化 MediaSession / 后台播放（必须在 runApp 前，否则恢复播放状态时 baseUrl 未就绪）。
/// 2. 恢复持久化会话（惰性，不主动联网）。
/// 3. 装配 Repository 树并启动。
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final handler = await MediaSessionService.init();
  final auth = AuthRepository();
  await auth.restore();

  final music = MusicRepository(auth);
  final playback = PlaybackRepository(music: music, handler: handler);

  runApp(App(auth: auth, music: music, playback: playback));
}
