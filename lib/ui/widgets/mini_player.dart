import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/log.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import 'cover_image.dart';

/// 底部 Mini Player。
///
/// ## 存在意义
/// 曲库浏览时不必回播放页就能看到「现在在放什么」并控制播放 —— 这是
/// 「拿电视长期听歌」的基本要求。
///
/// ## 焦点处理（V2 §17 重点）
/// - 内部四个可聚焦区（信息 / 上一首 / 播放暂停 / 下一首）各自持有 `FocusNode`，
///   在 `initState` 创建、`dispose` 释放（V2 §29 明确要求检查 FocusNode 泄漏）；
/// - 所有可聚焦区都有**明显的焦点描边**，电视 3 米外能看清焦点在哪；
/// - 播放/暂停与上下首直接调 [PlaybackRepository]，与播放页和 MediaSession
///   走**同一套**逻辑（不存在第二份播放状态）。
class MiniPlayer extends StatefulWidget {
  /// 点击曲目信息区 / 按 OK 时进入完整播放页。
  final VoidCallback onOpenPlayer;

  const MiniPlayer({super.key, required this.onOpenPlayer});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  final FocusNode _infoNode = FocusNode();
  final FocusNode _prevNode = FocusNode();
  final FocusNode _playNode = FocusNode();
  final FocusNode _nextNode = FocusNode();

  @override
  void dispose() {
    // ⚠️ 释放必须在 dispose：曲库页反复进出会泄漏（V2 §29 检查项）。
    _infoNode.dispose();
    _prevNode.dispose();
    _playNode.dispose();
    _nextNode.dispose();
    super.dispose();
  }

  void _open() {
    Log.i('UI 打开完整播放页 (mini player)');
    widget.onOpenPlayer();
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackRepository>();
    final music = context.read<MusicRepository>();
    final song = playback.current;

    // 没有播放过任何歌曲 → 隐藏（V2 §6 允许）
    if (song == null) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 88,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF15151C),
        border: Border(top: BorderSide(color: Color(0xFF26262F))),
      ),
      child: Row(
        children: <Widget>[
          CoverImage(
            music: music,
            coverId: song.effectiveCoverId,
            size: 64,
            radius: 6,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _FocusableBox(
              node: _infoNode,
              onPressed: _open,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artistNames} · ${song.album.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          _MiniButton(
            node: _prevNode,
            icon: Icons.skip_previous,
            onPressed: () {
              Log.i('SKIP_PREVIOUS (mini player)');
              playback.previous();
            },
          ),
          const SizedBox(width: 8),
          _MiniButton(
            node: _playNode,
            icon: playback.isPlaying ? Icons.pause : Icons.play_arrow,
            onPressed: () {
              Log.i('SEEK ${playback.isPlaying ? '暂停' : '播放'} (mini player)');
              playback.togglePlay();
            },
          ),
          const SizedBox(width: 8),
          _MiniButton(
            node: _nextNode,
            icon: Icons.skip_next,
            onPressed: () {
              Log.i('SKIP_NEXT (mini player)');
              playback.next();
            },
          ),
        ],
      ),
    );
  }
}

/// 带焦点描边的可聚焦盒子。
///
/// 抽出来是为了让「信息区」和「按钮」共用同一套焦点表现，
/// 避免各处自己写 `onFocusChange` 而漏掉视觉反馈。
class _FocusableBox extends StatefulWidget {
  final FocusNode node;
  final VoidCallback onPressed;
  final Widget child;

  const _FocusableBox({
    required this.node,
    required this.onPressed,
    required this.child,
  });

  @override
  State<_FocusableBox> createState() => _FocusableBoxState();
}

class _FocusableBoxState extends State<_FocusableBox> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.node.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant _FocusableBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // node 换了就换监听，避免旧 node 的回调打到新 widget 上。
    if (!identical(oldWidget.node, widget.node)) {
      oldWidget.node.removeListener(_onFocus);
      widget.node.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    // 只解绑，不 dispose：node 的所有权在父组件。
    widget.node.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() => _focused = widget.node.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.node,
      onFocusChange: (has) {
        if (mounted) setState(() => _focused = has);
      },
      child: Material(
        color: _focused ? Colors.white10 : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _focused ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Mini Player 上的图标按钮。
class _MiniButton extends StatelessWidget {
  final FocusNode node;
  final IconData icon;
  final VoidCallback onPressed;

  const _MiniButton({
    required this.node,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return _FocusableBox(
      node: node,
      onPressed: onPressed,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Icon(icon, size: 30, color: Colors.white),
      ),
    );
  }
}
