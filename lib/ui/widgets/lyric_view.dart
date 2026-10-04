import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../domain/lyric.dart';
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

  /// 播放进度的订阅。**必须**在 `dispose` 里 cancel：
  /// 播放页每次开关都会新建/销毁一个 `LyricView`，
  /// 不取消的话旧订阅还在向已卸载的 State `setState`（既泄漏又抛异常）。
  StreamSubscription<Duration>? _positionSub;

  int _activeIndex = -1;

  /// 已渲染的歌词文档代号，用于识别「换歌」并重置视口。
  int _seenEpoch = -1;

  // ── 诊断面（仅测试/CI 日志使用，经 dynamic 访问私有 State）────────
  // 「歌词不跟随」这类问题在真机上只有表象、没有内部状态可看，
  // 本地又没有 Dart 工具链 —— 把关键内部量暴露出来，让 CI 日志
  // 一次性回答「订阅了吗 / 回调了几次 / 算到了第几行 / 进度是多少」。

  /// 进度流订阅是否存在。
  @visibleForTesting
  bool get debugSubscribed => _positionSub != null;

  /// `_refresh` 被调用的次数（区分「回调没来」与「来了但算错」）。
  @visibleForTesting
  int get debugRefreshCalls => _refreshCalls;
  int _refreshCalls = 0;

  /// 当前活动行下标。
  @visibleForTesting
  int get debugActiveIndex => _activeIndex;

  /// 单行高度（固定值 → 滚动定位可精确计算，不需要 GlobalKey 测量）。
  ///
  /// ⚠️ 必须 ≥ 活动行的真实内容高：活动行字号 25 × 行高 1.25 × **最多 2 行**
  ///    = 62.5。旧值 58 会把活动行内容顶出自身边界 —— debug 里是
  ///    RenderFlex 溢出异常，release 里是**静默裁掉第二行**，
  ///    表现就是「正在唱的那句显示不全」。64 留 1.5px 余量。
  static const double _lineExtent = 64;

  /// 滚动动画时长。太短会显得跳，太长会跟不上快进。
  static const Duration _scrollDuration = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    // ⚠️ 进度来源改用**引擎的 positionStream**，不再用 400ms 轮询。
    //
    // 旧实现依赖定时器轮询 `playback.position`，有三个问题：
    //   1. seek（遥控器 / 手机 / 拖动）之后要等最多 400ms 才重算 —— 拖到某句
    //      中间时先显示上一句，再「慢慢」跳过来；
    //   2. 定时器与播放状态毫无关联，暂停时也在空转，恢复播放后第一拍
    //      可能读到旧值；
    //   3. 「定时器存在」不等于「同步正确」—— 真正决定跟随的是
    //      进度是否实时 + 歌词是否有时间轴（见 `LyricDoc.isSyncable`）。
    //
    // `positionStream` 由 just_audio 以固定间隔发值，**seek 时立即发**，
    // 暂停时不发（位置本来就没变）⇒ 语义与「当前播放位置」严格一致。
    // 订阅在 `dispose` 取消，不重复、不泄漏。
    _positionSub = context
        .read<PlaybackRepository>()
        .handler
        .positionStream
        .listen((_) => _refresh());
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _positionSub = null;
    _scroll.dispose();
    super.dispose();
  }

  void _refresh() {
    _refreshCalls++;
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

  /// 文档被替换（换歌 / 加载完成 / 被清空）→ 视口回到顶部，
  /// 并**立刻按当前播放进度定位**（旧实现要等下一个 400ms 拍，
  /// 于是切歌/换布局后总是先停在开头一瞬间）。
  void _syncDoc(int epoch) {
    if (epoch == _seenEpoch) return;
    _seenEpoch = epoch;
    _activeIndex = -1;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
      // 首帧布局完成后再定位：此时视口尺寸与 maxScrollExtent 都已就绪，
      // 不会被「ScrollController 尚未 attach / 视口尺寸为 0」吞掉首次定位。
      _refresh();
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
    // 整篇是否有文字行 —— 决定「空行」要不要画成 ♪（见 _LyricLineRow 的说明）
    final bool hasAnyText =
        lines.any((LyricLine l) => l.text.trim().isNotEmpty);

    // ⚠️ 「有歌词」≠「能逐句同步」。NAS 的歌词源可能是纯文本（无时间轴），
    //    解析出来每行 `time == null`：这时高亮与滚动**本来就不会动**
    //    （`activeLineIndex` 恒为 -1）。必须把这一点明说，
    //    而不是让用户以为「歌词坏了」—— 正文照常显示与上下浏览。
    final bool syncable = lyrics.doc.isSyncable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!syncable)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 6),
            child: Text(
              '纯文本歌词 · 不支持逐句同步',
              style: TextStyle(fontSize: 15, color: TvColors.textFaint),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
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
                    hasAnyText: hasAnyText,
                    distance: _activeIndex < 0 ? -1 : (i - _activeIndex),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 单行歌词。
///
/// 用「与当前句的距离」算透明度：距离越远越暗，形成天然的渐隐观感，
/// 不需要 `ShaderMask`（电视 GPU 上少一个全屏滤镜就少一分掉帧风险）。
class _LyricLineRow extends StatelessWidget {
  const _LyricLineRow({
    required this.text,
    required this.hasAnyText,
    required this.distance,
  });

  final String text;

  /// 整篇歌词是否至少有一行文字。
  ///
  /// ⚠️ 用来避免「整篇只有空行时画出一串 ♪」—— 那种文档已经被
  /// `LyricDoc.isUsable` 判为无效并转入在线兜底，但如果将来有别的
  /// 入口塞进一个空行文档，这里也不会再变成「只有一个音乐符号」。
  final bool hasAnyText;

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
            // ⚠️ 只有「确实有别的文字行」时才用 ♪ 表示间奏停顿。
            //    整篇都是空行的情况已经被 LyricDoc.isUsable 拦在仓库层，
            //    不会走到这里（图5 那个孤零零的 ♪ 就是这么来的）。
            text.isEmpty && hasAnyText ? '♪' : text,
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
