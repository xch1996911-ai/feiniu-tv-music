import 'package:flutter/material.dart';

import '../../core/log.dart';
import '../pages/player_page.dart';
import '../pages/search_page.dart';
import '../pages/song_list_page.dart';
import '../widgets/mini_player.dart';

/// 全局 App Shell：**主舞台**。
///
/// ## 为什么必须有它（V2 §6 / 手机互联预留）
/// Mini Player 要「跨页面常驻」：在曲库、搜索、播放页之间来回切换时，
/// 它不能被重建、也不能丢失播放状态。
///
/// 如果把 Mini Player 放进各个页面：
/// - 每个页面各有一份 → 切页时重建 → 焦点丢失、状态闪烁；
/// - 页面各自 `dispose` → 极易误 `stop()` 全局播放器（V2 §18 明令禁止）。
///
/// 所以采用**全局 Shell**：内容区在上、Mini Player 常驻在下，
/// 播放页是覆盖在内容区之上的全屏层（不销毁 Shell）。
///
/// ## 职责
/// - 持有「当前主舞台」（曲库 / 搜索 / 播放页）；
/// - 常驻 Mini Player；
/// - **不持有任何播放状态** —— 播放状态只在 `PlaybackRepository` 里。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

/// 主舞台。
enum ShellStage { library, search, player }

class _AppShellState extends State<AppShell> {
  ShellStage _stage = ShellStage.library;

  /// 返回上一页（播放页 → 搜索页 → 曲库）。
  ///
  /// V2 §18：Back 键在播放页只回到列表，**音乐继续播放**。
  void _back() {
    setState(() {
      _stage = switch (_stage) {
        ShellStage.player =>
          // 播放页从哪儿来就回哪儿
          _cameFromSearch ? ShellStage.search : ShellStage.library,
        ShellStage.search => ShellStage.library,
        ShellStage.library => ShellStage.library,
      };
    });
    Log.i('UI Back → stage=$_stage');
  }

  /// 记住进入播放页前所在的舞台（Back 要能回到原处）。
  bool _cameFromSearch = false;

  void _openFrom(ShellStage from) {
    _cameFromSearch = from == ShellStage.search;
    setState(() => _stage = ShellStage.player);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Stack(
                children: <Widget>[
                  // 底层：主内容（曲库 / 搜索）
                  _buildContent(),
                  // 顶层：播放页（全屏覆盖，不销毁底层）
                  if (_stage == ShellStage.player)
                    PlayerPage(onBack: _back),
                ],
              ),
            ),
            // 常驻 Mini Player：播放页全屏时不显示（它自己就是全屏的）
            if (_stage != ShellStage.player)
              MiniPlayer(
                onOpenPlayer: () => _openFrom(_stage),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_stage) {
      case ShellStage.library:
        return SongListPage(
          onOpenPlayer: () => _openFrom(ShellStage.library),
          onOpenSearch: () => setState(() => _stage = ShellStage.search),
        );
      case ShellStage.search:
        return SearchPage(
          onBack: _back,
          onOpenPlayer: () => _openFrom(ShellStage.search),
        );
      case ShellStage.player:
        // 播放页是覆盖层，这里只放一个占位（正常不会被看到）
        return const SizedBox.shrink();
    }
  }
}
