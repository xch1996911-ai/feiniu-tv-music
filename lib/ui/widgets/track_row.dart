import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../domain/track.dart';
import '../../repositories/music_repository.dart';
import 'cover_image.dart';
import 'tv_focus.dart';

/// 曲目列表项 —— **全项目唯一**的一份实现。
///
/// ## 为什么要统一
/// 旧代码在「全部歌曲」「搜索结果」里各写了一份几乎一样的行，
/// 于是焦点描边、当前播放高亮、字号在三处各不相同，改一处漏两处。
/// 现在所有列表（首页最近播放 / 音乐库 / 搜索 / 收藏 / 最近 / 分组）
/// 都用这一个组件，视觉与焦点行为天然一致。
///
/// ## 焦点
/// 内部是**单个** [TvFocus]，不再套 `ListTile` / `InkWell`
/// （它们会各自建 FocusNode，与焦点环抢状态）。
/// 上下方向的焦点移动**不显式指定**，交给框架的方向遍历 ——
/// 列表长度不定、位置还在滚动，框架比写死节点更稳；
/// 左右方向也交回框架，这样在窄列表里能自然走到侧栏。
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.isCurrent,
    required this.onPressed,
    this.trailingText,
    this.focusNode,
  });

  final Track track;

  /// 是否是当前正在播放的曲目（高亮 + 图标）。
  final bool isCurrent;

  final VoidCallback onPressed;

  /// 右侧文案。默认显示时长。
  final String? trailingText;

  /// 外部焦点节点（一般不需要传）。
  final FocusNode? focusNode;

  static String formatDuration(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final music = context.read<MusicRepository>();
    final String sub = track.artistNames.isEmpty
        ? track.album.name
        : '${track.artistNames} · ${track.album.name}';

    return TvFocus(
      focusNode: focusNode,
      debugLabel: 'track.${track.guid}',
      onPressed: onPressed,
      builder: (BuildContext context, TvFocusStatus s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: TvFocusRing(
          status: s,
          radius: 10,
          // 正在播放的行即使没有焦点也要能看出来（与参考图二一致）
          baseColor:
              isCurrent ? const Color(0x2A4F8CFF) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              CoverImage(
                music: music,
                coverId: track.effectiveCoverId,
                size: 46,
                radius: 6,
                iconScale: 0.42,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w500,
                        color: isCurrent ? TvColors.accent : TvColors.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        color: TvColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (isCurrent)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: Icon(Icons.volume_up,
                      size: 20, color: TvColors.accent),
                ),
              Text(
                trailingText ?? formatDuration(track.duration),
                style: const TextStyle(fontSize: 15, color: TvColors.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分组标题行（歌手 / 专辑 / 风格）。
///
/// **刻意不可聚焦**：分组只是视觉分隔，能聚焦就必须处理「选中分组之后做什么」，
/// 而电视上多一层跳转就多一次迷路。直接列曲目最省事。
class TrackGroupHeader extends StatelessWidget {
  const TrackGroupHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: TvColors.text,
              ),
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
            const SizedBox(width: 10),
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 15, color: TvColors.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

/// 列表里的空态提示。
class TrackListEmpty extends StatelessWidget {
  const TrackListEmpty({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 19,
            height: 1.6,
            color: TvColors.textFaint,
          ),
        ),
      ),
    );
  }
}
