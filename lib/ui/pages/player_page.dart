import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/player_layout.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/lyric_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/cover_image.dart';
import '../widgets/lyric_view.dart';
import '../widgets/queue_sheet.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_glass.dart';

/// 正在播放页（全屏覆盖层）。
///
/// ## V4 版式改动（需求「四、播放页布局改动」）
/// 1. **返回 / 播放顺序 / 模式切换 / 队列全部下沉到底部操作栏** ——
///    旧版把它们放在顶部两端，电视上要跨半个屏幕找；
/// 2. **封面放大为视觉主体**；
/// 3. 新增两种展示模式（[PlayerLayout]）：标准布局 / 大封面 + 歌词在下，
///    选择结果持久化，重新打开播放器仍生效；
/// 4. 新增**队列面板**（与首页迷你播放器打开的是同一份队列）。
///
/// ## 焦点（这是绝不能退化的部分）
/// 底部操作栏是一条**显式线性链，且与屏幕上的左右顺序完全一致**：
/// ```
/// [返回] ↔ [布局] ↔ [模式] ↔ [收藏] ↔ [上一首] ↔ [播放/暂停] ↔ [下一首] ↔ [队列]
///    ↑                                                                      │
///    └──────────────────（队列按 → 环回「返回」）────────────────────────────┘
/// ```
/// 逻辑顺序必须等于视觉顺序：若链条是「返回 → 模式 → 布局」而屏幕上是
/// 「返回 布局 模式」，用户按 → 时焦点会「跳过」中间那个控件，观感就是
/// 焦点乱跑（V4 修正过这个不一致）。
///
/// 进度区在操作栏**下方**，并保持 V3 已验证的行为：
/// - 底部任一控件按 ↓ → 进进度区；
/// - 进度区按 ↑ → **回播放/暂停**；
/// - 进度区按 ↓ → 原地不动（最下一层，绝不把焦点甩丢）；
/// - 进度区 ← / → = 快退 / 快进 5 秒，OK = 播放暂停。
///
/// 「进度区放在操作栏下方」而不是参考图的上方，是**刻意**的：
/// 若进度条在控制键上方，按 ↓ 焦点会向上跑，遥控器体验是坏的
/// （V3 已经踩过这个坑，这里不重复）。
///
/// ## 为什么控制区不会因进度刷新而丢焦点
/// 本页 `build` **不订阅** position：进度只在 [_SeekRow] 内部自刷新，
/// 播放/暂停只订阅 `isPlaying`，模式只订阅 `mode`，布局只订阅 `playerLayout`。
/// 进度跳动时控制按钮根本不重建，`FocusNode` 自然不会被换掉。
class PlayerPage extends StatefulWidget {
  /// 返回（回到进入播放页之前的位置）。音乐**继续播放**。
  final VoidCallback onBack;

  const PlayerPage({super.key, required this.onBack});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  // ── 焦点节点（全部在本 State 创建并释放）────────────────────
  final FocusNode _backNode = FocusNode(debugLabel: 'player.back');
  final FocusNode _modeNode = FocusNode(debugLabel: 'player.mode');
  final FocusNode _layoutNode = FocusNode(debugLabel: 'player.layout');
  final FocusNode _favNode = FocusNode(debugLabel: 'player.fav');
  final FocusNode _prevNode = FocusNode(debugLabel: 'player.prev');
  final FocusNode _playNode = FocusNode(debugLabel: 'player.play');
  final FocusNode _nextNode = FocusNode(debugLabel: 'player.next');
  final FocusNode _queueNode = FocusNode(debugLabel: 'player.queue');
  final FocusNode _seekNode = FocusNode(debugLabel: 'player.seek');

  /// 队列面板是否打开。
  bool _queueOpen = false;

  /// 已请求歌词的曲目 guid，用于检测换歌。
  String? _lyricForGuid;

  /// 播放仓储引用（构造时抓一次，避免 dispose 阶段再 `context.read`）。
  late final PlaybackRepository _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackRepository>();
    // 换歌（含自动下一首）要立刻换歌词：直接监听播放仓储，
    // 比轮询定时器更及时，也不会漏掉「用户按下一首」这种瞬间切歌。
    _playback.addListener(_syncLyric);
    // 进入播放页把焦点**直接落在播放/暂停**上（验收要求）。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _playNode.requestFocus();
      _syncLyric();
    });
  }

  @override
  void dispose() {
    _playback.removeListener(_syncLyric);
    for (final FocusNode n in <FocusNode>[
      _backNode,
      _modeNode,
      _layoutNode,
      _favNode,
      _prevNode,
      _playNode,
      _nextNode,
      _queueNode,
      _seekNode,
    ]) {
      n.dispose();
    }
    super.dispose();
  }

  /// 换歌时加载新歌词（自动下一首后歌词要跟着换）。
  ///
  /// 本方法会被**高频调用**（出现在播放仓储的监听链上），
  /// 因此第一件事就是比对 guid 后短路，绝不做多余工作。
  void _syncLyric() {
    if (!mounted) return;
    final Track? song = _playback.current;
    final lyrics = context.read<LyricRepository>();
    if (song == null) {
      if (_lyricForGuid != null) {
        lyrics.clear();
        _lyricForGuid = null;
      }
      return;
    }
    if (_lyricForGuid == song.guid) return;
    _lyricForGuid = song.guid;
    Log.i('LYRIC_LOAD 播放页检测到切歌 → ${song.guid}');
    // 刻意不 await：歌词慢不能挡住页面
    unawaited(lyrics.load(song));
  }

  void _openQueue() {
    Log.i('UI 打开播放队列 (player)');
    setState(() => _queueOpen = true);
  }

  void _closeQueue() {
    if (!_queueOpen) return;
    setState(() => _queueOpen = false);
    // 关闭队列后焦点**回到队列按钮**（需求：返回后回到原焦点位置）。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _queueNode.requestFocus();
    });
  }

  void _cycleLayout() {
    final LocalLibraryRepository local = context.read<LocalLibraryRepository>();
    final PlayerLayout nextLayout = local.playerLayout.next;
    Log.i('UI 播放页布局 ${local.playerLayout.storageKey} → ${nextLayout.storageKey}');
    unawaited(local.setPlayerLayout(nextLayout));
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 只订阅「当前曲目」与「布局模式」。
    //    进度用不着在这里监听 —— 一旦在这里 watch，
    //    进度每跳动一次整页就会重建，控件焦点与歌词视口都会跟着抖。
    final Track? song = context.select<PlaybackRepository, Track?>(
      (PlaybackRepository p) => p.current,
    );
    final PlayerLayout layout = context.select<LocalLibraryRepository,
        PlayerLayout>((LocalLibraryRepository l) => l.playerLayout);
    // ⚠️ 「当前曲是否已收藏」也必须在这里读，**不能**下沉到 [_buildCoverPane]：
    //    那两个布局方法是从 `LayoutBuilder` 的 builder 里调用的，而 builder
    //    跑在 **layout 阶段**（`debugDoingBuild == false`），provider 的
    //    `context.select` 会直接断言失败：
    //    `Failed assertion: 'widget is LayoutBuilder || debugDoingBuild'`。
    //    （`context.read` 没有这个限制，所以只有 select 会炸。）
    final bool fav = context.select<LocalLibraryRepository, bool>(
      (LocalLibraryRepository l) => song != null && l.isFavorite(song.guid),
    );

    return Material(
      color: TvColors.stageTo,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[TvColors.stageFrom, TvColors.stageTo],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: <Widget>[
              // ⚠️ 队列面板打开时把底下的播放页排除出焦点树，
              //    否则方向键会跑到被遮住的按钮上（焦点"消失"）。
              ExcludeFocus(
                excluding: _queueOpen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(36, 16, 36, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(child: _buildBody(song, layout, fav)),
                      // ⚠️ 纵向顺序必须是：正文 → 进度/队列状态区 → **最底部**操作条。
                      //    原来把操作条放在进度条**上面**，与需求相反，
                      //    也让「进度条在最下方」这个通用预期落空。
                      const SizedBox(height: 8),
                      _SeekRow(
                        playbackNode: _seekNode,
                        // 方向键：进度条↓ 回操作条（操作条现在在它下面）
                        downNode: _playNode,
                        upNode: _backNode,
                      ),
                      const SizedBox(height: 6),
                      const _StatusLine(),
                      const SizedBox(height: 10),
                      // 底部操作栏是一整块玻璃条（与全站毛玻璃视觉一致）
                      TvGlass(
                        radius: 20,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: _buildBottomBar(song, layout, fav),
                      ),
                    ],
                  ),
                ),
              ),
              if (_queueOpen) QueueSheet(onClose: _closeQueue),
            ],
          ),
        ),
      ),
    );
  }

  // ── 主体：两种展示模式 ────────────────────────────────────

  Widget _buildBody(Track? song, PlayerLayout layout, bool fav) {
    if (song == null) {
      return const Center(
        child: Text('尚未选择歌曲',
            style: TextStyle(fontSize: 26, color: TvColors.textFaint)),
      );
    }
    return switch (layout) {
      PlayerLayout.stage => _buildStageLayout(song, fav),
      PlayerLayout.cover => _buildCoverLayout(song, fav),
    };
  }

  /// 图四标准布局：左封面 + 信息，右歌词。
  Widget _buildStageLayout(Track song, bool fav) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 封面尺寸**不在这里算**：交给 `_buildCoverPane` 用它自己的约束反推
        //（见那里的说明 —— 用外层高度算会导致大封面模式溢出裁切）。
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              flex: 5,
              child: _buildCoverPane(song, fav, center: false),
            ),
            const SizedBox(width: 30),
            Expanded(flex: 4, child: _buildLyricPane(song)),
          ],
        );
      },
    );
  }

  /// 大封面模式：封面放大成视觉主体，歌词移到**封面下方**。
  Widget _buildCoverLayout(Track song, bool fav) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 同上：封面尺寸由 `_buildCoverPane` 用**子区域**约束反推。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              flex: 6,
              child: _buildCoverPane(
                song,
                fav,
                center: true,
                horizontal: true,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(flex: 4, child: _buildLyricPane(song)),
          ],
        );
      },
    );
  }

  /// 封面 + 曲目信息。
  ///
  /// [center] = true 时整体水平居中（大封面模式）；
  /// [horizontal] = true 时曲目信息放在封面**右侧**而不是下方，
  /// 避免大封面模式下文字把歌词区挤得太窄。
  ///
  /// ⚠️ 本方法**只做布局**，任何 provider 订阅都由调用方（真正的 `build()`）
  /// 传进来 —— 它被 `LayoutBuilder` 的 builder 调用，那里不允许 `context.select`。
  /// 封面 + 曲目信息。
  ///
  /// [center] = true 时整体水平居中（大封面模式）；
  /// [horizontal] = true 时曲目信息放在封面**右侧**而不是下方。
  ///
  /// ## ⚠️ 为什么封面尺寸必须在这里算，而不是由调用方传进来
  ///
  /// 原来 `_buildStageLayout` / `_buildCoverLayout` 用**外层整页高度**算好
  /// `coverSize` 再传进来。但 `_buildCoverLayout` 里封面所在的 `Expanded`
  /// 只占正文的 **60%** —— 于是「按整页 0.62 算出的封面」比它实际能用的高度还高，
  /// 在 release 构建下 `RenderFlex` 溢出**被静默裁切**（不打日志、不画条纹），
  /// 表现就是规格胶囊被切掉、看起来像被底部栏遮住。
  ///
  /// 现在改为：**用本子区域的约束**反推封面边长，并把文字块的固有高度先扣掉。
  /// 空间实在不够时把标题从 2 行降到 1 行（而不是溢出）。
  Widget _buildCoverPane(
    Track song,
    bool fav, {
    required bool center,
    bool horizontal = false,
  }) {
    final MusicRepository music = context.read<MusicRepository>();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        return _buildCoverPaneInner(song, fav, box, center, horizontal, music);
      },
    );
  }

  Widget _buildCoverPaneInner(
    Track song,
    bool fav,
    BoxConstraints box,
    bool center,
    bool horizontal,
    MusicRepository music,
  ) {
    // ── 尺寸预算（全部是显式常量，便于一眼核对）────────────────
    // 文字块三个部件的高度 —— 逐项对齐**真实渲染高度**，不凭字号估：
    //   ① 标题 `Text(fontSize:, height: 1.15)` → 行高 = ⌈字号 × 1.15⌉；
    //   ② 歌手行 `Text(fontSize: 20)` **没写 height** → 用 M3 默认 1.43
    //      → ⌈20 × 1.43⌉ = 29（按 20 算会少 9px）；
    //   ③ 规格胶囊 `_Chip` = 上下 padding 12 + ⌈16 × 1.43⌉ = 35
    //      （按 32 算会少 3px）；
    //   ④ **系统字体缩放**（Android 的「字体大小 / 显示大小」）会整体放大文字。
    //      老代码完全没算这一项 —— 字体放大到 1.3 就必然把封面栏顶破，
    //      而溢出在 release 下是**静默裁切**，界面上只表现为「规格被切」。
    //   Flutter 对**每一行**行盒向上取整，所以这里统一 `ceilToDouble()`。
    final double ts = MediaQuery.textScalerOf(context).scale(1.0);

    final double titleSize = center ? 38 : 34;
    final double titleLineH = (titleSize * ts * 1.15).ceilToDouble();
    final double artistLineH = (20 * ts * 1.43).ceilToDouble();
    final double chipH = (16 * ts * 1.43).ceilToDouble() + 12;
    const double gapBig = 22;
    const double gapSmall = 10;
    // 收尾余量：逐行取整 + 文字排版误差。不留这一项时，
    // 「正好等于可用高度」的算式会被判 `overflowed by 0.4 pixels`。
    const double slack = 2;

    // 最坏情况（2 行标题）先算一遍；装不下就退回 1 行。
    final double fullText =
        titleLineH * 2 + gapSmall + artistLineH + gapSmall + chipH;
    final double availH = box.maxHeight.isFinite ? box.maxHeight : 400;
    final double availW = box.maxWidth.isFinite ? box.maxWidth : 400;
    final bool twoLineTitle = (availH - gapBig - fullText) >= 150;
    final int titleLines = twoLineTitle ? 2 : 1;
    final double textBlock = titleLineH * titleLines +
        gapSmall +
        artistLineH +
        gapSmall +
        chipH;

    // 横向排布时文字在右边：封面可用宽度还要扣掉间距与文字宽度预算。
    // ⚠️ 这个 `textW` **必须同时用作下面 `ConstrainedBox` 的上限**：
    //    否则一边按 textW 扣封面宽度、另一边却仍允许文字排到 420，
    //    窄视口上就会水平溢出。
    final double textW = horizontal ? min(420.0, availW * 0.45) : 0.0;
    final double coverByWidth =
        horizontal ? (availW - 28 - textW - slack) : (availW - slack);
    final double coverByHeight =
        horizontal ? (availH - slack) : (availH - gapBig - textBlock - slack);

    // ⚠️ 设计下限**不能覆盖实际可用空间**。
    //    老代码写成 `.clamp(110.0, 360.0)`：逻辑视口偏小的电视
    //    （720p 面板 + density 1.5 → 853×480，扣掉进度区与操作条后正文只剩
    //    约 238）算出的可用封面高度只有 92，却被下限抬到 110 ——
    //    整个封面栏比可用高度高 18px，release 下静默裁切。
    //    规则：**装得下设计下限才用它，装不下就用实际装得下的值。**
    const double designMin = 110;
    final double upper = horizontal ? 460.0 : 360.0;
    final double fit = min(max(0.0, coverByWidth), max(0.0, coverByHeight));
    final double coverSize = fit >= designMin ? min(fit, upper) : fit;

    final Widget cover = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: CoverImage(
        music: music,
        coverId: song.effectiveCoverId,
        size: coverSize,
        radius: 16,
        iconScale: 0.3,
      ),
    );

    final Widget info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          song.title,
          // 空间不够时降为 1 行：宁可少一行，也不要整块被裁切
          maxLines: titleLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: center ? 38 : 34,
            height: 1.15,
            fontWeight: FontWeight.w700,
            color: TvColors.text,
          ),
        ),
        const SizedBox(height: gapSmall),
        Row(
          children: <Widget>[
            Icon(
              fav ? Icons.favorite : Icons.favorite_border,
              size: 20,
              color: fav ? TvColors.brand : TvColors.textFaint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                song.artistNames.isEmpty
                    ? song.album.name
                    : '${song.artistNames} · ${song.album.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, color: TvColors.textDim),
              ),
            ),
          ],
        ),
        const SizedBox(height: gapSmall),
        // ⚠️ 规格胶囊必须完整可见（实机问题就是它被切掉）
        _Chip(text: song.audioSpec.display),
      ],
    );

    if (horizontal) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          cover,
          const SizedBox(width: 28),
          ConstrainedBox(
            // ⚠️ 必须用上面算出的 `textW`，不能写死 420 ——
            //    封面可用宽度是按 textW 扣的，文字却允许排到 420，
            //    窄视口上两边对不上就会水平溢出。
            constraints: BoxConstraints(maxWidth: textW),
            child: info,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment:
          center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        cover,
        const SizedBox(height: gapBig),
        info,
      ],
    );
  }

  /// 歌词区（含标题行；不可聚焦）。
  Widget _buildLyricPane(Track song) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${song.title} - ${song.artistNames}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: TvColors.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          song.album.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, color: TvColors.textFaint),
        ),
        const SizedBox(height: 12),
        const Expanded(child: LyricView()),
      ],
    );
  }

  // ── 底部操作栏（返回 / 模式 / 布局 / 收藏 / 上一首 / 播放 / 下一首 / 队列）──

  /// 底部操作条：返回 / 布局 / 模式 / 收藏 / 上一首 / 播放 / 下一首 / 队列。
  ///
  /// ## 为什么要在这里做「装不装得下」的判断
  ///
  /// 一行的固有宽度是**固定值之和**（六个圆钮 + 三个胶囊）。在逻辑视口偏小的
  /// 电视上（720p 面板 + density 1.5 → 853×480，扣掉页面内边距后只剩 749）
  /// 或者系统字体放大时，这一行会顶出容器边界；而 `RenderFlex` 溢出在
  /// **release 构建下是静默裁切** —— 电视上只看到「最右边那个按钮被切一半」，
  /// 没有任何报错。所以这里显式判断：装得下用标准排布，装不下整体等比缩小。
  Widget _buildBottomBar(Track? song, PlayerLayout layout, bool fav) {
    final bool playing = context.select<PlaybackRepository, bool>(
      (PlaybackRepository p) => p.isPlaying,
    );
    final PlayMode mode = context.select<PlaybackRepository, PlayMode>(
      (PlaybackRepository p) => p.mode,
    );
    // V5：是否有「上一首」由**播放历史**决定（不是队列下标）。
    // 没有历史时按钮置灰 —— 需求要求「显示为不可用」，
    // 而不是让用户按了半天没反应还以为遥控器坏了。
    final bool canPrevious = context.select<PlaybackRepository, bool>(
      (PlaybackRepository p) => p.hasPrevious,
    );
    final PlaybackRepository p = context.read<PlaybackRepository>();
    final double ts = MediaQuery.textScalerOf(context).scale(1.0);

    List<Widget> children({required bool flexible}) => _bottomBarChildren(
          song: song,
          layout: layout,
          fav: fav,
          playing: playing,
          mode: mode,
          canPrevious: canPrevious,
          p: p,
          flexible: flexible,
        );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double need = _bottomBarIntrinsicWidth(
          ts,
          layout.shortLabel,
          mode.shortLabel,
        );
        if (!c.maxWidth.isFinite || c.maxWidth >= need) {
          return Row(children: children(flexible: true));
        }
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: Row(children: children(flexible: false)),
        );
      },
    );
  }

  /// 底部操作条的一行控件。
  ///
  /// [flexible] = true：两端用 `Spacer` 撑开（宽屏的标准排布，一个像素都不改）；
  /// false：两端换成固定间距 —— `FittedBox` 交给子树的宽度是**无界**的，
  /// 里面放 `Spacer`/`Expanded` 会直接抛
  /// 「RenderFlex children have non-zero flex but incoming width constraints
  /// are unbounded」。
  List<Widget> _bottomBarChildren({
    required Track? song,
    required PlayerLayout layout,
    required bool fav,
    required bool playing,
    required PlayMode mode,
    required bool canPrevious,
    required PlaybackRepository p,
    required bool flexible,
  }) {
    return <Widget>[
      // ── 左组：导航类（视觉顺序 = 焦点链顺序：返回 → 布局 → 模式 → 收藏）──
      _RoundControl(
        node: _backNode,
        debugLabel: 'player.back',
        icon: Icons.keyboard_arrow_down,
        tooltip: '返回',
        compact: true,
        onPressed: widget.onBack,
        nextLeft: _queueNode, // 环：左端接右端，左右永远有去有回
        nextRight: _layoutNode,
        // ⚠️ 操作条现在在进度条**下方**，所以「去进度条」是 ↑ 而不是 ↓。
        //    只移动控件而不改方向键，会让遥控器在这个区域"走不出去"。
        nextUp: _seekNode,
      ),
      const SizedBox(width: 12),
      _PillControl(
        node: _layoutNode,
        debugLabel: 'player.layout',
        icon: layout == PlayerLayout.stage
            ? Icons.view_agenda
            : Icons.wallpaper,
        label: layout.shortLabel,
        tooltip: '切换播放页布局（标准 / 大封面）',
        onPressed: _cycleLayout,
        nextLeft: _backNode,
        nextRight: _modeNode,
        // ⚠️ 操作条现在在进度条**下方**，所以「去进度条」是 ↑ 而不是 ↓。
        //    只移动控件而不改方向键，会让遥控器在这个区域"走不出去"。
        nextUp: _seekNode,
      ),
      const SizedBox(width: 10),
      _PillControl(
        node: _modeNode,
        debugLabel: 'player.mode',
        icon: _modeIcon(mode),
        label: mode.shortLabel,
        tooltip: '播放模式（${mode.label}）',
        onPressed: () {
          // ⚠️ 用 `mode.next` 而不是 `PlayMode.values[index+1]`：
          // 循环顺序（顺序 → 列表循环 → 随机 → 单曲 → 顺序）是
          // 在 `playback_control.dart` 里定义并注释的**唯一一处**，
          // UI 不应该再自己推一遍（否则改顺序时两边会不一致）。
          final PlayMode nextMode = mode.next;
          Log.i('PLAY_MODE_CHANGE UI ${mode.storageKey} → ${nextMode.storageKey}');
          unawaited(p.setMode(nextMode));
        },
        nextLeft: _layoutNode,
        nextRight: _favNode,
        // ⚠️ 操作条现在在进度条**下方**，所以「去进度条」是 ↑ 而不是 ↓。
        //    只移动控件而不改方向键，会让遥控器在这个区域"走不出去"。
        nextUp: _seekNode,
      ),
      const SizedBox(width: 10),
      _RoundControl(
        node: _favNode,
        debugLabel: 'player.fav',
        icon: fav ? Icons.favorite : Icons.favorite_border,
        iconColor: fav ? TvColors.brand : TvColors.text,
        tooltip: fav ? '取消收藏' : '收藏',
        compact: true,
        onPressed: song == null
            ? null
            : () {
                Log.i('UI 播放页 ${fav ? '取消收藏' : '收藏'} ${song.title}');
                unawaited(
                  context
                      .read<LocalLibraryRepository>()
                      .toggleFavorite(song.guid),
                );
              },
        nextLeft: _modeNode,
        nextRight: _prevNode,
        // ⚠️ 操作条现在在进度条**下方**，所以「去进度条」是 ↑ 而不是 ↓。
        //    只移动控件而不改方向键，会让遥控器在这个区域"走不出去"。
        nextUp: _seekNode,
      ),
      flexible ? const Spacer() : const SizedBox(width: 24),
      // ── 中组：播放控制（电视上最常用的三个，放正中间）──
      _RoundControl(
        node: _prevNode,
        debugLabel: 'player.prev',
        icon: Icons.skip_previous,
        // V5：没有上一首记录（或队列只有一首且当前模式不回绕）时置灰。
        tooltip: canPrevious ? '上一首' : '没有上一首',
        iconColor: canPrevious ? null : TvColors.textFaint,
        onPressed: () {
          Log.i('SKIP_PREVIOUS (player)');
          unawaited(p.previous());
        },
        nextLeft: _favNode,
        nextRight: _playNode,
        // ⚠️ 操作条现在在进度条**下方**，所以「去进度条」是 ↑ 而不是 ↓。
        //    只移动控件而不改方向键，会让遥控器在这个区域"走不出去"。
        nextUp: _seekNode,
      ),
      const SizedBox(width: 30),
      _RoundControl(
        node: _playNode,
        debugLabel: 'player.play',
        icon: playing ? Icons.pause : Icons.play_arrow,
        tooltip: playing ? '暂停' : '播放',
        large: true,
        onPressed: () {
          Log.i('PLAY_TOGGLE (player) → ${playing ? '暂停' : '播放'}');
          unawaited(p.togglePlay());
        },
        nextLeft: _prevNode,
        nextRight: _nextNode,
        // ⚠️ 操作条现在在进度条**下方**，所以「去进度条」是 ↑ 而不是 ↓。
        //    只移动控件而不改方向键，会让遥控器在这个区域"走不出去"。
        nextUp: _seekNode,
      ),
      const SizedBox(width: 30),
      _RoundControl(
        node: _nextNode,
        debugLabel: 'player.next',
        icon: Icons.skip_next,
        tooltip: '下一首',
        onPressed: () {
          Log.i('SKIP_NEXT (player)');
          unawaited(p.next());
        },
        nextLeft: _playNode,
        nextRight: _queueNode,
        // ⚠️ 操作条现在在进度条**下方**，所以「去进度条」是 ↑ 而不是 ↓。
        //    只移动控件而不改方向键，会让遥控器在这个区域"走不出去"。
        nextUp: _seekNode,
      ),
      flexible ? const Spacer() : const SizedBox(width: 24),
      // ── 右组：队列 ────────────────────────────────────
      _PillControl(
        node: _queueNode,
        debugLabel: 'player.queue',
        icon: Icons.queue_music,
        label: '队列',
        tooltip: '打开当前播放队列',
        onPressed: _openQueue,
        nextLeft: _nextNode,
        nextRight: _backNode,
        // ⚠️ 操作条现在在进度条**下方**，所以「去进度条」是 ↑ 而不是 ↓。
        //    只移动控件而不改方向键，会让遥控器在这个区域"走不出去"。
        nextUp: _seekNode,
      ),
    ];
  }
}

/// 估算 `_PillControl` 在给定字体缩放下的总宽度。
///
/// 用 `TextPainter` **实测**文字宽度，而不是写死一个阈值常量：
/// 写死的阈值在系统字体放大（Android「字体大小」）时会被悄悄顶破，
/// 而溢出在 release 下是静默裁切，没有任何提示。
///
/// 常量口径（对齐 `_PillControl` / `TvFocusRing` 的实际实现）：
/// - `16 + 16` 左右内边距；
/// - `+ 6`：`TvFocusRing` 的 `Border.all(width: 3)` —— `Container` 会把
///   边框尺寸算进 padding（**焦点环会占位**，不占位的只有外发光）；
/// - `22` 图标 + `8` 图文间距。
double _pillWidthFor(String label, double ts) {
  final TextPainter tp = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(fontSize: 17 * ts, color: TvColors.text),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return 16 + 16 + 6 + 22 + 8 + tp.width;
}

/// 底部操作条一行的**固有宽度之和**（不含两端 `Spacer` 的余量）。
double _bottomBarIntrinsicWidth(
  double ts,
  String layoutLabel,
  String modeLabel,
) {
  // 左组：返回 54 + 间距 12 + 布局胶囊 + 10 + 模式胶囊 + 10 + 收藏 54
  final double left = 54 +
      12 +
      _pillWidthFor(layoutLabel, ts) +
      10 +
      _pillWidthFor(modeLabel, ts) +
      10 +
      54;
  // 中组：上一首 66 + 30 + 播放 82 + 30 + 下一首 66
  const double center = 66 + 30 + 82 + 30 + 66;
  // 右组：队列胶囊
  final double right = _pillWidthFor('队列', ts);
  return left + center + right;
}

/// 队列来源 / 当前序号 / 播放错误。既有信息，不能因为改版而丢掉。
class _StatusLine extends StatelessWidget {
  const _StatusLine();

  @override
  Widget build(BuildContext context) {
    final String label = context.select<PlaybackRepository, String>(
      (PlaybackRepository p) => '队列：${p.state.sourceLabel} · '
          '${p.currentIndex + 1}/${p.queue.length}',
    );
    final String? error = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.state.error,
    );

    return Column(
      children: <Widget>[
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, color: Color(0xFFFF8A8F)),
            ),
          ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, color: TvColors.textFaint),
        ),
      ],
    );
  }
}

/// 进度 + 快退/快进（**组合控件**，整行一个焦点节点）。
///
/// ⚠️ 这是 V3 修好的关键路径，V4 只换外面版式、**不动这里的语义**：
/// `←` / `→` 直接快退/快进 5 秒，`OK` 等价播放/暂停，
/// `↑` 回播放/暂停，`↓` 原地不动。
///
/// 若把进度条拆成独立节点并允许它消费左右键，就必然出现
/// 「进了进度条只能按 BACK 出来的死区」—— V3 踩过，这里不复现。
class _SeekRow extends StatefulWidget {
  /// 本行的焦点节点（由 PlayerPage 创建，用于串联焦点链）。
  final FocusNode playbackNode;

  /// ↑ 的去处（顶部返回按钮）。
  final FocusNode? upNode;

  /// ↓ 的去处（最底部操作条上的播放/暂停按钮）。
  final FocusNode? downNode;

  const _SeekRow({
    required this.playbackNode,
    this.upNode,
    this.downNode,
  });

  @override
  State<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<_SeekRow> {
  /// 单次快退/快进。
  static const Duration _step = Duration(seconds: 5);

  /// 进度刷新定时器。⚠️ 必须取消（dispose 后 setState 会抛异常）。
  Timer? _ticker;

  /// 拖动中的本地值（拖动过程中不被外部 position 覆盖）。
  double? _dragValue;

  /// 最近一次 ← / → 的方向（-1 后退 / 1 前进 / 0 无），用于闪一下对应按钮。
  int _flash = 0;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    // 只让这一小块每 400ms 重建 —— 底部操作栏与歌词区因此完全不受影响。
    _ticker = Timer.periodic(
      const Duration(milliseconds: 400),
      (Timer _) {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

  void _seekBy(int direction) {
    final p = context.read<PlaybackRepository>();
    Log.i('SEEK ${direction < 0 ? '快退' : '快进'} 5 秒');
    unawaited(p.seekRelative(_step * direction));
    setState(() => _flash = direction);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 260), () {
      if (mounted) setState(() => _flash = 0);
    });
  }

  static String _fmt(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.read<PlaybackRepository>();
    final Duration pos = p.position ?? Duration.zero;
    final Duration dur = p.duration ?? Duration.zero;
    final double maxMs =
        dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
    final double shown =
        (_dragValue ?? pos.inMilliseconds.toDouble()).clamp(0.0, maxMs);

    return TvFocus(
      focusNode: widget.playbackNode,
      debugLabel: 'player.seek',
      // ⚠️ 左右键在这块是**进度操作**，不是焦点移动 —— 这正是需求里
      //    「明确设计的进度操作情形」。它不会造成死区：↑ 始终能回控制区。
      onArrowLeft: () => _seekBy(-1),
      onArrowRight: () => _seekBy(1),
      onPressed: () => unawaited(p.togglePlay()),
      nextUp: widget.upNode,
      // ↓ 去最底部操作条的播放/暂停按钮；没有就指回自己（原地不动）。
      // ⚠️ 指回自己而不是留空：留空时框架的方向遍历可能把焦点甩到
      // 不可预期的节点上（那正是「按 ↓ 焦点就不见了」的来源）。
      nextDown: widget.downNode ?? widget.playbackNode,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        focusColor: const Color(0x33FFFFFF),
        ringColor: TvColors.focusRing,
        child: Row(
          children: <Widget>[
            _SeekChip(
              icon: Icons.fast_rewind,
              label: '5秒',
              highlighted: _flash < 0,
            ),
            const SizedBox(width: 12),
            Text(
              _fmt(Duration(milliseconds: shown.round())),
              style: const TextStyle(fontSize: 18, color: TvColors.textDim),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ExcludeFocus(
                // 进度条自身**绝不获焦**：否则 Material 的 Slider 会吃掉
                // 方向键，把焦点锁在进度条上（这正是「进了进度区就出不来」
                // 的根因）。
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 7,
                    activeTrackColor: TvColors.focusRing,
                    inactiveTrackColor: const Color(0x40FFFFFF),
                    thumbColor: Colors.white,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 9),
                  ),
                  child: Slider(
                    value: shown,
                    max: maxMs,
                    onChanged: (double v) => setState(() => _dragValue = v),
                    // 只在拖动结束时 seek：拖动过程不产生播放请求。
                    onChangeEnd: (double v) {
                      Log.i('SEEK slider ${v.round()}ms');
                      unawaited(p.seek(Duration(milliseconds: v.round())));
                      setState(() => _dragValue = null);
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _fmt(dur),
              style: const TextStyle(fontSize: 18, color: TvColors.textDim),
            ),
            const SizedBox(width: 12),
            _SeekChip(
              icon: Icons.fast_forward,
              label: '5秒',
              trailing: true,
              highlighted: _flash > 0,
            ),
          ],
        ),
      ),
    );
  }
}

/// 快退 / 快进 5 秒的视觉提示（被 ← / → 触发时点亮）。
///
/// 刻意做成**不可聚焦**的提示块：真正的操作热区是整个 [_SeekRow]。
/// 这样「看得见的按钮」和「按得动的位置」是同一块区域，不会出现
/// 「看着有个按钮但焦点进不去」的困惑。
class _SeekChip extends StatelessWidget {
  const _SeekChip({
    required this.icon,
    required this.label,
    required this.highlighted,
    this.trailing = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  /// true 表示图标在文字右侧（快进）。
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    final Color color =
        highlighted ? TvColors.focusRing : TvColors.textFaint;
    final Widget iconWidget = Icon(icon, size: 24, color: color);
    final Widget textWidget = Text(
      label,
      style: TextStyle(fontSize: 16, color: color),
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlighted ? const Color(0x33FFFFFF) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: trailing
            ? <Widget>[textWidget, const SizedBox(width: 6), iconWidget]
            : <Widget>[iconWidget, const SizedBox(width: 6), textWidget],
      ),
    );
  }
}

/// 圆形播放控制键。
///
/// ⚠️ **不要用 `ElevatedButton` / `IconButton`**：它们内部各自持有 FocusNode，
/// 与本组件的焦点节点互相打架，会出现「高亮在这个按钮上但 OK 按不动」
/// 或「按得动但没有高亮」—— 这正是 V3 修掉的故障。
class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.node,
    required this.debugLabel,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.nextLeft,
    required this.nextRight,
    this.nextUp,
    this.iconColor,
    this.large = false,
    this.compact = false,
  });

  final FocusNode node;
  final String debugLabel;
  final IconData icon;
  final String tooltip;

  /// null = 不可用（例如没有当前曲目时的收藏键）。
  final VoidCallback? onPressed;

  final Color? iconColor;
  final FocusNode? nextLeft;
  final FocusNode? nextRight;
  /// ↑ 的去处（进度区）。
  final FocusNode? nextUp;
  final bool large;

  /// 略小的圆形（返回 / 收藏这类次要动作）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final double box = large ? 82 : (compact ? 54 : 66);
    return Tooltip(
      message: tooltip,
      child: TvFocus(
        focusNode: node,
        debugLabel: debugLabel,
        onPressed: onPressed,
        canRequestFocus: onPressed != null,
        nextLeft: nextLeft,
        nextRight: nextRight,
        nextUp: nextUp,
        builder: (BuildContext context, TvFocusStatus s) => SizedBox(
          width: box,
          height: box,
          child: TvFocusRing(
            status: s,
            radius: box / 2,
            padding: EdgeInsets.zero,
            width: box,
            height: box,
            baseColor: const Color(0x33FFFFFF),
            child: Icon(
              icon,
              size: large ? 40 : (compact ? 26 : 30),
              color: iconColor ?? TvColors.text,
            ),
          ),
        ),
      ),
    );
  }
}

/// 胶囊控件（带文字），用于播放顺序 / 布局 / 队列这类需要自解释的按钮。
class _PillControl extends StatelessWidget {
  const _PillControl({
    required this.node,
    required this.debugLabel,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    required this.nextLeft,
    required this.nextRight,
    this.nextUp,
  });

  final FocusNode node;
  final String debugLabel;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  final FocusNode? nextLeft;
  final FocusNode? nextRight;
  /// ↑ 的去处（进度区）。
  final FocusNode? nextUp;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: TvFocus(
        focusNode: node,
        debugLabel: debugLabel,
        onPressed: onPressed,
        nextLeft: nextLeft,
        nextRight: nextRight,
        nextUp: nextUp,
        builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
          status: s,
          radius: 24,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          baseColor: const Color(0x33FFFFFF),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 22, color: TvColors.text),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(fontSize: 17, color: TvColors.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 规格 / 属性小胶囊。
class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 16,
          color: TvColors.text,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

IconData _modeIcon(PlayMode m) => switch (m) {
      PlayMode.sequence => Icons.trending_flat,
      PlayMode.repeatAll => Icons.repeat,
      PlayMode.repeatOne => Icons.repeat_one,
      PlayMode.shuffle => Icons.shuffle,
    };
