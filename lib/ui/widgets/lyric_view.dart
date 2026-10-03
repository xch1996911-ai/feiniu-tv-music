import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../repositories/lyric_repository.dart';
import '../../repositories/playback_repository.dart';

/// 歌词显示区：当前行高亮 + **自动居中滚动**。
///
/// ## 参考图三的呈现方式
/// 没有边框、没有底色，就是右侧一列文字：当前句亮白加粗，
/// 离当前句越远越暗。这样在大屏上「正在唱哪一句」一眼可见。
///
/// ## 修复的两个真实故障
/// 1. **歌词不跟随**：旧实现只有一个 500ms 定时器改高亮下标，
///    **完全没有滚动逻辑** —— 歌词其实在走，但视口永远停在开头，
///    用户看到的是「前奏那几句」不动。本版加了 ScrollController +
///    居中滚动（见 [_scrollToActive]）。
/// 2. **切歌后残留 / 不重来**：靠 `LyricRepository.docEpoch` 检测文档替换，
///    一旦换歌就把视口弹回顶部并清掉旧高亮；
///    `LyricRepository.load()` 也会在请求发出前先把旧歌词清空。
///
/// ## 焦点（关键）
/// 歌词是**只读**的，整块用 [ExcludeFocus] 排除在焦点树之外：
/// - 方向键绝不会被歌词吞掉（旧实现用 `FocusTraversalGroup`，
///   在 `ListView` 场景下仍可能被内部可滚动节点截住）；
/// - 自动滚动、每 500ms 的高亮刷新都不会**夺走播放控件的焦点**
///   （这是「播着播着按钮就选不中了」的根因之一）。
class LyricView extends StatefulWidget {
  const LyricView({super.key});

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  final ScrollController _scroll = ScrollController();

  Timer? _timer;

  int _activeIndex = -1;

  /// 已渲染的歌词文档代号，用于识别「换歌」并重置视口。
  int _seenEpoch = -1;

  /// 单行高度（固定值 → 滚动定位可精确计算，不需要 GlobalKey 测量）。
  static const double _lineExtent = 58;

  /// 滚动动画时长。太短会显得跳，太长会跟不上快进。
  static const Duration _scrollDuration = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final lyrics = context.read<LyricRepository>();
    final playback = context.read<PlaybackRepository>();

    if (lyrics.doc.isEmpty) {
      if (_activeIndex != -1) {
        setState(() => _activeIndex = -1);
      }
      return;
    }

    // 位置直接问播放层（权威值），不做本地推算 —— 快进/快退/切歌都能立刻反映。
    final idx = lyrics.activeLineIndex(playback.position ?? Duration.zero);
    if (idx != _activeIndex) {
      setState(() => _activeIndex = idx);
      _scrollToActive();
    }
  }

  /// 把当前句滚到视口正中。
  ///
  /// 数学很干净：因为列表上下各留了 `(viewport - lineExtent) / 2` 的 padding，
  /// 「第 i 行居中」对应的滚动量恰好就是 `i * lineExtent`。
  void _scrollToActive() {
    if (_activeIndex < 0) return;
    if (!_scroll.hasClients) return;
    final ScrollPosition pos = _scroll.position;
    if (!pos.hasViewportDimension || !pos.hasContentDimensions) return;

    final double target = _activeIndex * _lineExtent;
    final double clamped = target.clamp(0.0, pos.maxScrollExtent);
    // 已经在位就不要再动：每 400ms 反复 animate 会让整块歌词抖。
    if ((pos.pixels - clamped).abs() < 1.0) return;
    _scroll.animateTo(
      clamped,
      duration: _scrollDuration,
      curve: Curves.easeOut,
    );
  }

  /// 文档被替换（换歌 / 加载完成 / 被清空）→ 视口回到顶部。
  void _syncDoc(int epoch) {
    if (epoch == _seenEpoch) return;
    _seenEpoch = epoch;
    _activeIndex = -1;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = context.watch<LyricRepository>();
    _syncDoc(lyrics.docEpoch);

    // 整块歌词不参与焦点链（见类注释）。
    return ExcludeFocus(
      child: _buildBody(lyrics),
    );
  }

  Widget _buildBody(LyricRepository lyrics) {
    // 正在加载且还没有内容 → 转圈（有超时兜底，不会永远转下去）
    if (lyrics.isLoading && lyrics.doc.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    // 无歌词（接口为空 / 失败 / 超时）—— 统一显示「暂无歌词」，绝不影响播放
    if (lyrics.doc.isEmpty) {
      return const Center(
        child: Text(
          '暂无歌词',
          style: TextStyle(fontSize: 22, color: TvColors.textFaint),
        ),
      );
    }

    final lines = lyrics.doc.lines;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double viewport = c.maxHeight;
        final double pad = ((viewport - _lineExtent) / 2).clamp(
          0.0,
          double.infinity,
        );
        return ListView.builder(
          controller: _scroll,
          itemExtent: _lineExtent,
          physics: const ClampingScrollPhysics(),
          padding: EdgeInsets.symmetric(vertical: pad),
          itemCount: lines.length,
          itemBuilder: (BuildContext context, int i) {
            return _LyricLineRow(
              text: lines[i].text,
              distance: _activeIndex < 0 ? -1 : (i - _activeIndex),
            );
          },
        );
      },
    );
  }
}

/// 单行歌词。
///
/// 用「与当前句的距离」算透明度：距离越远越暗，形成天然的渐隐观感，
/// 不需要 `ShaderMask`（电视 GPU 上少一个全屏滤镜就少一分掉帧风险）。
class _LyricLineRow extends StatelessWidget {
  const _LyricLineRow({required this.text, required this.distance});

  final String text;

  /// 与当前高亮行的距离；-1 表示当前没有高亮行。
  final int distance;

  @override
  Widget build(BuildContext context) {
    final bool active = distance == 0;
    final int d = distance < 0 ? 3 : distance;

    final double alpha = active ? 1.0 : (0.62 - 0.09 * d).clamp(0.16, 0.62);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        // 当前句左侧的强调竖条（图三里「正在唱」的那一句）
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 4,
          height: active ? 26 : 0,
          decoration: BoxDecoration(
            color: active ? TvColors.focusRing : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text.isEmpty ? '♪' : text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: active ? 25 : 21,
              height: 1.25,
              color: TvColors.text.withValues(alpha: alpha),
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}
