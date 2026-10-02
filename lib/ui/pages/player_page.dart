import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../repositories/playback_repository.dart';

/// 正在播放页（Phase 1 临时 UI）。
/// 显示当前曲目信息 + 规格 + 进度 + 上一首/播放暂停/下一首。
/// 后台播放与遥控媒体键由 audio_service MediaSession 提供（见 playback/）。
class PlayerPage extends StatelessWidget {
  final VoidCallback onBack;

  const PlayerPage({super.key, required this.onBack});

  @override
  Widget build(BuildContext context) {
    // Flutter 3.47 已废弃 WillPopScope（且不兼容 Android 预测式返回），改用 PopScope。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onBack();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('正在播放')),
        body: Consumer<PlaybackRepository>(
          builder: (context, pb, _) {
            final t = pb.current;
            return Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (t != null) ...[
                    Text(t.title,
                        style: const TextStyle(
                            fontSize: 32, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text('${t.artistNames} · ${t.album.name}',
                        style: const TextStyle(fontSize: 22)),
                    const SizedBox(height: 8),
                    Text(t.audioSpec.display,
                        style: const TextStyle(
                            fontSize: 18, color: Colors.blueGrey)),
                    const SizedBox(height: 24),
                    _Progress(pb),
                  ] else
                    const Text('尚未选择歌曲',
                        style: TextStyle(fontSize: 22, color: Colors.grey)),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _MediaButton(
                        label: '⏮ 上一首',
                        onPressed: pb.previous,
                      ),
                      const SizedBox(width: 24),
                      _MediaButton(
                        label: pb.isPlaying ? '⏸ 暂停' : '▶ 播放',
                        onPressed: pb.togglePlay,
                        primary: true,
                      ),
                      const SizedBox(width: 24),
                      _MediaButton(
                        label: '下一首 ⏭',
                        onPressed: pb.next,
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MediaButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool primary;

  const _MediaButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
        backgroundColor: primary ? Colors.blue : null,
      ),
      child: Text(label, style: const TextStyle(fontSize: 20)),
    );
  }
}

class _Progress extends StatelessWidget {
  final PlaybackRepository pb;

  const _Progress(this.pb);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: pb.handler.positionStream,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final dur = pb.duration ?? Duration.zero;
        final ratio = dur.inMilliseconds > 0
            ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: ratio, minHeight: 6),
            const SizedBox(height: 8),
            Text('${_fmt(pos)} / ${_fmt(dur)}',
                style: const TextStyle(fontSize: 18)),
          ],
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
