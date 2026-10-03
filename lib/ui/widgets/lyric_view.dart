import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../repositories/lyric_repository.dart';
import '../../repositories/playback_repository.dart';

/// 歌词显示区：当前行高亮 + 自动跟随滚动。
///
/// ## 性能（V2 §19）
/// 曲库可能几千首，但歌词**只加载当前一首**（见 [LyricRepository]）。
/// 高亮刷新用 500ms 定时器**只更新高亮下标**，并仅在行号变化时才
/// `setState`（播放中同一句停留数秒，不该每 500ms 重建一次）。
///
/// ## 焦点（V2 §17）
/// 歌词区是**只读**的，不参与焦点遍历
/// （`FocusTraversalGroup(descendantsAreFocusable: false)`）——
/// 否则方向键会被歌词「吃掉」，无法移动到播放控件。
class LyricView extends StatefulWidget {
  const LyricView({super.key});

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  /// 高亮刷新定时器。⚠️ 必须在 dispose 取消。
  Timer? _timer;

  int _activeIndex = -1;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final lyrics = context.read<LyricRepository>();
    final playback = context.read<PlaybackRepository>();
    if (lyrics.doc.isEmpty) {
      if (_activeIndex != -1) setState(() => _activeIndex = -1);
      return;
    }
    final idx = lyrics.activeLineIndex(playback.position ?? Duration.zero);
    // 只有行号真的变了才 setState（避免无谓重建）
    if (idx != _activeIndex) {
      setState(() => _activeIndex = idx);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = context.watch<LyricRepository>();

    // 加载中
    if (lyrics.isLoading && lyrics.doc.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    // 无歌词 / 加载失败 —— 都显示「暂无歌词」，绝不影响播放
    if (lyrics.doc.isEmpty) {
      return const Center(
        child: Text('暂无歌词',
            style: TextStyle(fontSize: 20, color: Colors.white38)),
      );
    }

    final lines = lyrics.doc.lines;

    return FocusTraversalGroup(
      // 歌词是只读的，不参与焦点遍历
      descendantsAreFocusable: false,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF12121A),
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ListView.builder(
          // 懒构建：歌词可能有几百行
          itemCount: lines.length,
          // 居中对齐当前行
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemBuilder: (context, i) {
            final active = i == _activeIndex;
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Text(
                lines[i].text.isEmpty ? '♪' : lines[i].text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: active ? 22 : 18,
                  height: 1.4,
                  // 当前行高亮（颜色 + 粗体），电视 3 米外可读
                  color: active
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.4),
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
