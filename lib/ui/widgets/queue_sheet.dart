import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import 'cover_image.dart';
import 'tv_focus.dart';
import 'tv_glass.dart';

/// 行内文字的行高倍数。
///
/// ⚠️ 本文件所有「固定行高的行」里的 `Text` 都必须显式带上它。
/// M3 主题给 `DefaultTextStyle` 的行高是 `20/14 ≈ 1.43`，`TextStyle` 会与它
/// merge，于是 18 号字实际占 26px、14 号字占 20px —— 在 [QueueSheet] 的
/// 固定行高里必然 `RenderFlex overflowed`。
///
/// 取值还要满足「字号 × height 是整数」：Flutter 对每一行的行盒高度**向上取整**
/// （`19 × 1.2 = 22.8 → 23`），算式上「恰好等于行高」也会被判溢出
/// （`overview_page.dart` 的专辑瓦片曾因此差 `0.400 pixels`）。
const double _textHeight = 1.2;

/// 当前播放队列面板（播放页与首页迷你播放器**共用同一份**队列）。
///
/// ## 数据源
/// 直接读 [PlaybackRepository.queue] / `currentIndex` —— 队列状态**只**存在
/// 于播放仓储里，本面板既不复制也不缓存，因此「从迷你播放器打开」与
/// 「从播放页打开」看到的必然是同一个队列、同一个当前曲目。
///
/// ## 焦点
/// - 面板内**只有列表可聚焦**，上下移动交给框架（列表长度不定）；
/// - 打开时焦点落在**当前播放的那一行**，用户一睁眼就知道自己在队列的哪个位置；
/// - OK = 播放所选并关闭；BACK / 关闭按钮 = 关闭。
///
/// ⚠️ 「落在当前播放行」用的是**显式 `requestFocus()`**，而不是 `autofocus`：
/// 面板弹出时底下的播放页被 `ExcludeFocus` 排除，框架会把焦点上交给
/// 所在的 FocusScope ——此时 `autofocus` 可能因为「scope 已有焦点」而**不生效**，
/// 表现就是「打开队列后按方向键没反应」。显式请求不依赖任何启发式。
///
/// ⚠️ 调用方必须在自己那一层用 `ExcludeFocus` 把**底下的界面**排除掉，
/// 否则方向键会跑到被遮住的控件上（焦点「消失在看不见的地方」）。
class QueueSheet extends StatefulWidget {
  const QueueSheet({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<QueueSheet> {
  static const double _rowExtent = 74;

  final FocusNode _closeNode = FocusNode(debugLabel: 'queue.close');

  /// 当前播放那一行的焦点节点（面板打开时显式聚焦它）。
  final FocusNode _currentNode = FocusNode(debugLabel: 'queue.current');

  late final ScrollController _scroll;

  /// 打开时算一次：让当前曲目落在可视区中部附近。
  @override
  void initState() {
    super.initState();
    final int idx = context.read<PlaybackRepository>().currentIndex;
    _currentNode.debugLabel = 'queue.$idx';
    _scroll = ScrollController(
      initialScrollOffset: idx <= 2 ? 0 : (idx - 2) * _rowExtent,
    );
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _currentNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _closeNode.dispose();
    _currentNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _playAt(List<Track> queue, int index) async {
    Log.i('QUEUE_SHEET play index=$index');
    await context.read<PlaybackRepository>().playQueue(
          queue,
          source: context.read<PlaybackRepository>().source,
          startIndex: index,
        );
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final PlaybackRepository p = context.read<PlaybackRepository>();
    final List<Track> queue = p.queue;
    final int currentIndex = p.currentIndex;

    return Stack(
      children: <Widget>[
        TvScrim(onTap: widget.onClose),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: TvGlass(
              radius: 22,
              tint: TvColors.glassHi,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: SizedBox(
                width: 980,
                height: 620,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Icon(Icons.queue_music,
                            size: 24, color: TvColors.accent),
                        const SizedBox(width: 10),
                        const Text(
                          '播放队列',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: TvColors.text,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '共 ${queue.length} 首 · 正在第 ${currentIndex + 1} 首',
                          style: const TextStyle(
                              fontSize: 15, color: TvColors.textFaint),
                        ),
                        const Spacer(),
                        const Text(
                          'OK 播放所选 · 返回键关闭',
                          style: TextStyle(
                              fontSize: 14, color: TvColors.textFaint),
                        ),
                        const SizedBox(width: 14),
                        TvFocus(
                          focusNode: _closeNode,
                          debugLabel: 'queue.close',
                          onPressed: widget.onClose,
                          builder: (BuildContext context, TvFocusStatus s) =>
                              SizedBox(
                            width: 42,
                            height: 42,
                            child: TvFocusRing(
                              status: s,
                              radius: 21,
                              padding: EdgeInsets.zero,
                              width: 42,
                              height: 42,
                              child: const Icon(Icons.close,
                                  size: 22, color: TvColors.text),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: queue.isEmpty
                          ? const Center(
                              child: Text(
                                '队列是空的',
                                style: TextStyle(
                                    fontSize: 18, color: TvColors.textFaint),
                              ),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              itemExtent: _rowExtent,
                              itemCount: queue.length,
                              itemBuilder: (BuildContext context, int i) {
                                final Track t = queue[i];
                                return _QueueRow(
                                  index: i,
                                  track: t,
                                  isCurrent: i == currentIndex,
                                  focusNode: i == currentIndex
                                      ? _currentNode
                                      : null,
                                  onPressed: () => _playAt(queue, i),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 队列里的一行。
class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.index,
    required this.track,
    required this.isCurrent,
    required this.focusNode,
    required this.onPressed,
  });

  final int index;
  final Track track;
  final bool isCurrent;

  /// 当前播放行由面板传入的节点（面板打开时会显式聚焦它）。
  final FocusNode? focusNode;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final MusicRepository music = context.read<MusicRepository>();

    return TvFocus(
      // 当前曲目所在行由面板显式聚焦（见 `_QueueSheetState.initState`）。
      focusNode: focusNode,
      debugLabel: 'queue.$index',
      onPressed: onPressed,
      builder: (BuildContext context, TvFocusStatus s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: TvFocusRing(
          status: s,
          radius: 10,
          padding: EdgeInsets.zero,
          child: TvGlass(
            blur: false,
            radius: 10,
            showBorder: false,
            shadow: false,
            tint: isCurrent
                ? const Color(0x404F8CFF)
                : const Color(0x14FFFFFF),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: isCurrent
                            ? TvColors.accent
                            : TvColors.textFaint,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CoverImage(
                    music: music,
                    coverId: track.effectiveCoverId,
                    size: 42,
                    radius: 6,
                    iconScale: 0.42,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        // ⚠️ `height` 必须显式写死。
                        // M3 的 DefaultTextStyle 行高是 20/14 ≈ 1.43，会与
                        // TextStyle merge：18 号字实际占 26px、14 号字占 20px，
                        // 叠加 2px 间距后在固定行高里必然 RenderFlex 溢出。
                        // 且 字号 × height 必须落在整数上 —— Flutter 对**每一行**
                        // 的行盒高度向上取整（19×1.2=22.8→23），算式上「刚好相等」
                        // 也会被判溢出（overview 专辑瓦片曾因此差 0.400px）。
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            height: _textHeight, // 21.6 → 22
                            fontWeight: isCurrent
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isCurrent ? TvColors.accent : TvColors.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artistNames.isEmpty
                              ? track.album.name
                              : '${track.artistNames} · ${track.album.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            height: _textHeight, // 16.8 → 17
                            color: TvColors.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isCurrent)
                    const Icon(Icons.volume_up,
                        size: 20, color: TvColors.accent),
                  const SizedBox(width: 12),
                  Text(
                    _fmt(track.duration),
                    style: const TextStyle(
                        fontSize: 15, color: TvColors.textFaint),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
