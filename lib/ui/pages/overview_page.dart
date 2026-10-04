import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../domain/genre.dart';
import '../../domain/genre_inferencer.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';
import '../widgets/cover_image.dart';
import '../widgets/track_row.dart';
import '../widgets/tv_focus.dart';

// ── 行内文字的行高 ────────────────────────────────────────────
//
// ⚠️ 本文件所有位于**固定行高**里的 `Text` 都必须显式带上 [_textHeight]。
//    M3 主题给 `DefaultTextStyle` 的行高是 20/14 ≈ 1.43，`TextStyle` 会与它
//    merge，于是 21 号字实际占 30px 而不是 25px —— 行高按「看上去的高度」写
//    就必然 `RenderFlex overflowed`（电视上就是黄黑条纹）。
//    队列面板行此前就是这么溢出 2px 的。
//
// ⚠️ 取值还必须满足「字号 × height 是整数」：Flutter 会把**每一行**的行盒
//    高度向上取整。曾经用 19 / 14 配 1.2 得到 22.8 / 16.8 → 取整后 23 / 17，
//    于是「封面正方形 + 两行文字」这种算式上正好等于行高的布局被判溢出
//    `RenderFlex overflowed by 0.400 pixels`（0.2 + 0.2，正好是两行的取整差）。
/// 行内文字的单行倍高。配 20 / 15 / 21 / 16 号字都落在整数上。
const double _textHeight = 1.2;

// ── 专辑瓦片的几何常量 ────────────────────────────────────────
//
// ⚠️ 这些值**必须**与 `_AlbumTile` 里的实际用法一致：网格的 `mainAxisExtent`
//    就是用 `tileWidth + _albumTextBlock + _albumHeightSlack` 反推出来的。
//    写死一个「看起来够高」的常量会导致宽屏上封面变大、行高不变
//    → `RenderFlex overflowed`（实测 1920 宽下专辑网格溢出 67px）。

/// 封面与标题之间的间距。
const double _albumCoverGap = 10;

/// 标题与副标题之间的间距。
const double _albumTitleGap = 3;

/// 专辑名字号。⚠️ 与 [_textHeight] 的乘积必须是**整数**（原因见上）。
const double _albumTitleSize = 20;

/// 副标题（歌手 · N 首）字号。同样要求乘积是整数。
const double _albumSubSize = 15;

/// 瓦片里焦点环占掉的高度（`padding: all(10)` × 2 + 环线 3 × 2）。
const double _albumRingInset = 26;

/// 高度余量。
///
/// 行高与内容「恰好相等」时不会溢出，但不同平台 / 字体的度量会有
/// 零点几像素的差异，留一点余量更稳。
const double _albumHeightSlack = 2;

/// 封面下方「文字块」的总高。
///
/// 必须与 [_AlbumTile] 里实际的 `SizedBox` / `fontSize` / `height` 完全一致，
/// 否则网格行高与实际内容对不上（见上面 [_albumHeightSlack] 的说明）。
const double _albumTextBlock = _albumCoverGap +
    _albumTitleSize * _textHeight +
    _albumTitleGap +
    _albumSubSize * _textHeight;

/// 概览类型（决定版式与统计口径）。
enum OverviewKind {
  /// 歌手：横向行（头像 + 名字 + N 首歌 · M 张专辑 + 进入箭头）。
  artist,

  /// 专辑：网格（封面 + 专辑名 + 歌手）。
  album,

  /// 风格：横向行（图标 + 名字 + N 首）。
  genre,
}

/// 「概览 → 详情」两级浏览页（歌手 / 专辑 / 风格共用）。
///
/// ## 为什么改成两级（本轮需求）
/// 旧版把某位歌手的**全部歌曲**直接铺开在同一页（真实反馈：进了「歌手」
/// 看到的是 Adele 的 37 首歌一路向下），既看不到「有哪些歌手」，
/// 也无法在几百位歌手里定位 —— 这就是图一暴露的问题。
///
/// 现在：概览只画**统计**（歌曲数 / 专辑数），点进去才展开曲目。
///
/// ## 返回原位置（需求明确要求）
/// 进入详情时记录 `_savedOffset` 与最后聚焦的行号；返回时：
/// 1. 把概览列表滚回原 offset；
/// 2. 用**显式的 `requestFocus()`** 把焦点还给**原来那一行**
///    （不用 `autofocus`：从详情返回时框架可能已把焦点上交给所在的
///    FocusScope，`autofocus` 就不再生效）。
/// 两步缺一不可 —— 只恢复滚动位置而不给焦点，
/// 遥控器会因为「没有任何控件持有焦点」而第一次按键无反应（V3 踩过的坑）。
///
/// ## 详情状态为什么放在 Shell
/// `PopScope` 的 `canPop` 是**所有注册者的与运算**，嵌套注册会让
/// 「关播放页」和「关详情」同时触发。因此全 App 只保留 Shell 里那**一个**
/// PopScope，详情开没开由 Shell 掌握（见 `AppShell._openOverview`）。
class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.kind,
    required this.title,
    required this.emptyHint,
    required this.onOpenPlayer,
    required this.detail,
    required this.onOpenDetail,
    required this.onCloseDetail,
  });

  final OverviewKind kind;
  final String title;
  final String emptyHint;
  final VoidCallback onOpenPlayer;

  /// 当前打开的详情；null 表示正在看概览。
  final LibraryOverview? detail;

  final ValueChanged<LibraryOverview> onOpenDetail;
  final VoidCallback onCloseDetail;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  /// 行高（固定值 —— 概览是固定行高列表，才能精确算回滚位置）。
  ///
  /// ⚠️ 固定行高**必须**装得下「焦点环内边距 + 环线 + 内容」：
  /// 小于内容高度就是 `RenderFlex overflowed`（电视上是黄黑条纹）。
  /// 反直觉的一点是内容比看上去高 —— M3 主题给 Text 的默认行高是 1.43。
  /// 因此下面每个 Text 都显式写了 `height: _textHeight`，算式才成立
  /// （取整后的实际占位，向上取整见 [_textHeight] 的说明）：
  /// - 歌手行：可用 92-4-4-8-8-3-3 = 62；头像 56 ≤ 62 ✅；
  ///   文字 21×1.2 + 4 + 15×1.2 = 25.2+4+18 → 取整 26+4+18 = 48 ≤ 62 ✅
  /// - 风格行：可用 78-4-4-14-14-3-3 = 36；最高子项（箭头图标 26）≤ 36 ✅
  static const double _artistRowExtent = 92;
  static const double _genreRowExtent = 78;
  // 间距从 18 收到 12：960 逻辑宽下 (714-3×12)/4 ≈ 169px 瓦片宽，
  // 刚好稳稳放下 4 列（18 会退化成 3 列）。
  static const double _albumSpacing = 12;

  final ScrollController _scroll = ScrollController();

  /// 详情页「返回」按钮的焦点节点（由本 State 持有）。
  ///
  /// ⚠️ 详情页的入口是概览里的某一行，那一行在切到详情时会**被卸载**，
  /// 它持有的焦点也随之消失。若不在进入详情后显式把焦点放到一个确定的
  /// 控件上，遥控器的下一次按键会「没反应」（框架没有起点可移动）——
  /// 这是本项目反复踩过的故障类型。
  final FocusNode _detailBackNode = FocusNode(debugLabel: 'ovdetail.back');

  /// 从详情返回时，用来把焦点**交还给原来那一行**的节点。
  ///
  /// 用一个「游标式」节点而不是给每一行都建节点：
  /// 概览可能有几百项，逐行建节点既浪费又会引入泄漏风险；
  /// 而返回时只需要恢复**一行**的焦点。
  ///
  /// ⚠️ 与队列面板同理，这里刻意用**显式 `requestFocus()`** 而不是
  /// `autofocus`：从详情返回时框架可能把焦点上交给所在的 FocusScope，
  /// 那样 `autofocus` 就不生效了（遥控器会「失灵一次」）。
  final FocusNode _restoreNode = FocusNode(debugLabel: 'ov.restore');

  /// 进入详情前的滚动位置。
  double _savedOffset = 0;

  /// 进入详情前最后聚焦的行号（-1 = 无）。
  int _lastFocused = -1;

  /// 返回概览时要把焦点还给的行号（-1 = 不需要）。
  int _pendingFocus = -1;

  /// 目标行是否在**本次构建中真的被建出来**了。
  ///
  /// 概览可能有几百项、且是懒构建的列表：被跳走的行完全可能不在可视区，
  /// 那时 [_restoreNode] 处于「未挂到焦点树上」的状态 ——
  /// 对它 `requestFocus()` 会让焦点落在一个不存在的节点上（比不恢复更糟）。
  /// 因此先记这个标记，只在目标行确实存在时才请求焦点。
  bool _restoreRowBuilt = false;

  List<LibraryOverview> _overviews = const <LibraryOverview>[];
  List<Track>? _source;

  /// 上次用于计算 [_overviews] 的风格归纳结果（见 [_compute] 的说明）。
  GenreInferenceResult? _inferenceSource;

  @override
  void didUpdateWidget(covariant OverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.kind != oldWidget.kind) {
      // ⚠️ 换了分类必须**整体重置**。
      //
      // 正常情况下外壳会给每个分类不同的 `ValueKey`（见 `app_shell.dart`），
      // 切分类时会换一个全新的 State，这里根本不会被调用。但 OverviewPage
      // 是公开组件，任何调用方都可能像外壳曾经那样「同槽位换 kind」——
      // 那时 `_compute()` 的缓存键是 `identical(曲库实例)`，而曲库实例
      // 对三个分类是**同一份** ⇒ 旧分类的分组结果会被原样显示在新分类上。
      //
      // 这里重置的是「派生结果」，不触碰曲库本体、播放队列、收藏与偏好 ——
      // 那些都不归本组件管。
      _source = null;
      _inferenceSource = null;
      _overviews = const <LibraryOverview>[];
      _lastFocused = -1;
      _pendingFocus = -1;
      if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
    }
    if (oldWidget.detail == null && widget.detail != null) {
      // 进入详情：记下当前位置，返回时用；并把焦点交给详情页的「返回」。
      _savedOffset = _scroll.hasClients ? _scroll.offset : 0;
      _pendingFocus = -1;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted) return;
        _detailBackNode.requestFocus();
      });
    } else if (oldWidget.detail != null && widget.detail == null) {
      // 从详情返回：回滚到原位置，并把焦点还给原来那一行。
      // `_lastFocused` 理论上一定 ≥0（用户必须聚焦某一行才能按 OK 进去），
      // 但兜到 0 更安全 —— 宁可回到第一行，也不能让焦点凭空消失。
      final int target = _lastFocused < 0 ? 0 : _lastFocused;
      _pendingFocus =
          _overviews.isNotEmpty && target < _overviews.length ? target : -1;
      if (_pendingFocus >= 0) {
        _restoreNode.debugLabel =
            'ov.${widget.kind.name}.${_overviews[_pendingFocus].key}';
      }
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted) return;
        if (_scroll.hasClients) {
          final double max = _scroll.position.maxScrollExtent;
          _scroll.jumpTo(_savedOffset.clamp(0.0, max));
        }
        // 再等一帧：让"跳回原位置"引发的重建先把目标行建出来。
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          if (!mounted) return;
          if (_pendingFocus >= 0 && _restoreRowBuilt) {
            _restoreNode.requestFocus();
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _detailBackNode.dispose();
    _restoreNode.dispose();
    super.dispose();
  }

  /// 概览列表（按曲库实例做缓存 —— `LibraryRepository` 每合并一页都会换新
  /// List 实例，用 `identical` 判断「变了没」比比较几千条内容便宜得多）。
  ///
  /// ⚠️ V5：风格概览的缓存键**多了一个** [GenreInferenceResult] ——
  /// 归纳结果会在「用户手动确认风格」或「规则版本变化」时换成新对象，
  /// 而曲目列表可能完全没变（`identical` 判定为「没变」），
  /// 只按列表缓存会导致用户改完风格后页面纹丝不动。
  List<LibraryOverview> _compute(
    LibraryRepository library,
    LocalLibraryRepository local,
  ) {
    final List<Track> catalogue = library.tracks;
    final GenreInferenceResult? inference = library.genreInference;
    if (identical(_source, catalogue) &&
        identical(_inferenceSource, inference)) {
      return _overviews;
    }
    _source = catalogue;
    _inferenceSource = inference;
    _overviews = switch (widget.kind) {
      OverviewKind.artist => LocalLibraryRepository.artistOverviews(catalogue),
      OverviewKind.album => LocalLibraryRepository.albumOverviews(catalogue),
      OverviewKind.genre =>
        local.genreOverviewsOf(catalogue, inference: inference),
    };
    return _overviews;
  }

  void _playAll(List<Track> tracks, {required bool shuffle}) {
    if (tracks.isEmpty) return;
    final PlaybackRepository p = context.read<PlaybackRepository>();
    final int start = shuffle ? Random().nextInt(tracks.length) : 0;
    Log.i('OVERVIEW_PLAY ${widget.title} '
        '${shuffle ? '随机' : '顺序'} count=${tracks.length} start=$start');
    if (shuffle) p.setMode(PlayMode.shuffle);
    p.playQueue(tracks, source: QueueSource.local, startIndex: start);
    widget.onOpenPlayer();
  }

  @override
  Widget build(BuildContext context) {
    final LibraryRepository library = context.watch<LibraryRepository>();
    final LocalLibraryRepository local = context.watch<LocalLibraryRepository>();
    final String? currentGuid = context.select<PlaybackRepository, String?>(
      (PlaybackRepository p) => p.current?.guid,
    );

    final LibraryOverview? detail = widget.detail;
    if (detail != null) {
      return _buildDetail(detail, currentGuid);
    }

    final List<LibraryOverview> items = _compute(library, local);

    if (items.isEmpty) {
      if (library.phase == LibraryPhase.loading && library.tracks.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SectionHeader(title: widget.title, subtitle: null),
          Expanded(child: TrackListEmpty(text: widget.emptyHint)),
        ],
      );
    }

    return switch (widget.kind) {
      OverviewKind.album => _buildAlbumGrid(items),
      _ => _buildRowList(items),
    };
  }

  // ── 概览：横向行列表（歌手 / 风格）─────────────────────────

  Widget _buildRowList(List<LibraryOverview> items) {
    final bool isArtist = widget.kind == OverviewKind.artist;
    final double extent = isArtist ? _artistRowExtent : _genreRowExtent;
    _restoreRowBuilt = false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SectionHeader(
          title: widget.title,
          subtitle: _listSubtitle(items, isArtist: isArtist),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            itemExtent: extent,
            itemCount: items.length,
            itemBuilder: (BuildContext context, int i) {
              final LibraryOverview o = items[i];
              final bool isTarget = i == _pendingFocus;
              if (isTarget) _restoreRowBuilt = true;
              return isArtist
                  ? _ArtistRow(
                      overview: o,
                      focusNode: isTarget ? _restoreNode : null,
                      onFocus: () => _lastFocused = i,
                      onPressed: () => _open(o),
                    )
                  : _GenreRow(
                      overview: o,
                      focusNode: isTarget ? _restoreNode : null,
                      onFocus: () => _lastFocused = i,
                      onPressed: () => _open(o),
                    );
            },
          ),
        ),
      ],
    );
  }

  /// 行列表副标题。
  ///
  /// ⚠️ 风格页必须如实提示「部分歌曲待分类」（需求 §三.4）：
  /// 「待分类」是一个**真实的分类条目**而不是失败态，
  /// 在副标题里说清楚，用户才不会以为风格功能坏了。
  String _listSubtitle(List<LibraryOverview> items, {required bool isArtist}) {
    if (isArtist) return '共 ${items.length} 位歌手';
    final bool hasPending =
        items.any((LibraryOverview o) => o.title == GenreRules.unclassified);
    return hasPending
        ? '共 ${items.length} 种风格 · 部分歌曲待分类'
        : '共 ${items.length} 种风格';
  }

  // ── 概览：专辑网格 ────────────────────────────────────────

  Widget _buildAlbumGrid(List<LibraryOverview> items) {
    _restoreRowBuilt = false;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 列数按可用宽度自适应。
        //
        // ⚠️ V5 标定依据（实机图4）：Android TV 盒子在 1080p 面板上通常上报
        //    **density 2.0**，也就是 Flutter 侧只有 **960×540 逻辑像素**。
        //    用 250 当最小瓦片宽时：usable ≈ 960-206(侧栏)-40 = 714，
        //    `floor(714/266) = 2` —— 正好就是用户看到的「一屏只有两张巨大的卡」。
        //    所以问题不是「宽屏没铺满」，而是**设计时按 1920 逻辑宽算的阈值，
        //    在电视的实际逻辑视口下退化成 2 列**。
        //    取 150 后：960 宽 → 4 列；1280 宽 → 6 列；1920 宽 → 上限 6 列。
        const double tileMin = 150;
        const int maxColumns = 6;
        const int minColumns = 3;
        final double usable = c.maxWidth - 40;
        final int columns = (usable / (tileMin + _albumSpacing))
            .floor()
            .clamp(minColumns, maxColumns);

        // ⚠️ 行高**由瓦片宽度反推**，不能写死：
        //    封面是「瓦片内宽的正方形」，宽屏上封面更大，
        //    固定行高必然被挤爆（1920 宽实测溢出 67px）。
        //    同一屏内列数固定 ⇒ 行高恒定，回滚位置照样能精确算。
        final double tileWidth =
            (usable - _albumSpacing * (columns - 1)) / columns;
        final double cover = tileWidth - _albumRingInset;
        // 行高 = 封面 + 文字块 + 余量（见各常量上的说明）
        final double tileExtent =
            tileWidth + _albumTextBlock + _albumHeightSlack;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _SectionHeader(
              title: widget.title,
              subtitle: '共 ${items.length} 张专辑',
            ),
            Expanded(
              child: GridView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: tileExtent,
                  crossAxisSpacing: _albumSpacing,
                  mainAxisSpacing: _albumSpacing,
                ),
                itemCount: items.length,
                itemBuilder: (BuildContext context, int i) {
                  final LibraryOverview o = items[i];
                  if (i == _pendingFocus) _restoreRowBuilt = true;
                  return _AlbumTile(
                    overview: o,
                    coverSize: cover,
                    focusNode: i == _pendingFocus ? _restoreNode : null,
                    onFocus: () => _lastFocused = i,
                    onPressed: () => _open(o),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _open(LibraryOverview o) {
    Log.i('OVERVIEW_OPEN ${widget.kind.name} key=${o.key} '
        'tracks=${o.trackCount}');
    widget.onOpenDetail(o);
  }

  // ── 详情：该分组的曲目列表 ────────────────────────────────

  Widget _buildDetail(LibraryOverview o, String? currentGuid) {
    final String sub = switch (widget.kind) {
      OverviewKind.artist => '${o.trackCount} 首歌 · ${o.albumCount} 张专辑',
      OverviewKind.album => o.subtitle == null
          ? '${o.trackCount} 首'
          : '${o.subtitle} · ${o.trackCount} 首',
      OverviewKind.genre => '${o.trackCount} 首',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DetailHeader(
          title: o.title,
          subtitle: sub,
          coverId: o.coverId,
          roundCover: widget.kind == OverviewKind.artist,
          backNode: _detailBackNode,
          onBack: widget.onCloseDetail,
          onPlayAll: () => _playAll(o.tracks, shuffle: false),
          onShuffle: () => _playAll(o.tracks, shuffle: true),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            itemCount: o.tracks.length,
            itemBuilder: (BuildContext context, int i) {
              final Track t = o.tracks[i];
              return TrackRow(
                track: t,
                isCurrent: t.guid == currentGuid,
                onPressed: () {
                  Log.i('OVERVIEW_DETAIL_PLAY index=$i guid=${t.guid}');
                  context.read<PlaybackRepository>().playQueue(
                        o.tracks,
                        source: QueueSource.local,
                        startIndex: i,
                      );
                  widget.onOpenPlayer();
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 区块标题（「歌手  共 188 位歌手」）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 16, 26, 12),
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
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: TvColors.text,
              ),
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
            const SizedBox(width: 14),
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 17, color: TvColors.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

/// 歌手概览行（参考图二）。
class _ArtistRow extends StatelessWidget {
  const _ArtistRow({
    required this.overview,
    required this.focusNode,
    required this.onFocus,
    required this.onPressed,
  });

  final LibraryOverview overview;

  /// 由 [OverviewPage] 传入的「焦点归还」节点（仅从详情返回时给目标行）。
  final FocusNode? focusNode;

  final VoidCallback onFocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final MusicRepository music = context.read<MusicRepository>();

    return TvFocus(
      focusNode: focusNode,
      debugLabel: 'ov.artist.${overview.key}',
      onFocusChange: (bool f) {
        if (f) onFocus();
      },
      onPressed: onPressed,
      builder: (BuildContext context, TvFocusStatus s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: TvFocusRing(
          status: s,
          radius: 14,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              ClipOval(
                child: CoverImage(
                  music: music,
                  coverId: overview.coverId,
                  size: 56,
                  radius: 28,
                  iconScale: 0.42,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      overview.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 21,
                        height: _textHeight,
                        fontWeight: FontWeight.w600,
                        color: TvColors.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${overview.trackCount} 首歌 · ${overview.albumCount} 张专辑',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        height: _textHeight,
                        color: TvColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right,
                  size: 26, color: TvColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// 专辑概览块（参考图三的网格）。
class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.overview,
    required this.coverSize,
    required this.focusNode,
    required this.onFocus,
    required this.onPressed,
  });

  final LibraryOverview overview;

  /// 封面边长（正方形）。
  ///
  /// 由 [_OverviewPageState._buildAlbumGrid] 按瓦片宽度算好后传入 ——
  /// 网格的 `mainAxisExtent` 用的是**同一个值**，两者必须同源，
  /// 否则行高与内容对不上就是 `RenderFlex overflowed`。
  final double coverSize;

  /// 由 [OverviewPage] 传入的「焦点归还」节点。
  final FocusNode? focusNode;

  final VoidCallback onFocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final MusicRepository music = context.read<MusicRepository>();

    return TvFocus(
      focusNode: focusNode,
      debugLabel: 'ov.album.${overview.key}',
      onFocusChange: (bool f) {
        if (f) onFocus();
      },
      onPressed: onPressed,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 14,
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CoverImage(
              music: music,
              coverId: overview.coverId,
              size: coverSize,
              radius: 12,
              iconScale: 0.3,
            ),
            const SizedBox(height: _albumCoverGap),
            Text(
              overview.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: _albumTitleSize,
                height: _textHeight,
                fontWeight: FontWeight.w600,
                color: TvColors.text,
              ),
            ),
            const SizedBox(height: _albumTitleGap),
            Text(
              '${overview.subtitle ?? ''}'
              '${overview.subtitle != null && overview.subtitle!.isNotEmpty ? ' · ' : ''}'
              '${overview.trackCount} 首',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: _albumSubSize,
                height: _textHeight,
                color: TvColors.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 风格概览行。
/// 风格行图标：待分类用「问号」，其余用默认图标。
IconData _genreIconFor(LibraryOverview o) =>
    o.title == GenreRules.unclassified ? Icons.help_outline : Icons.grid_view;

class _GenreRow extends StatelessWidget {
  const _GenreRow({
    required this.overview,
    required this.focusNode,
    required this.onFocus,
    required this.onPressed,
  });

  final LibraryOverview overview;

  /// 由 [OverviewPage] 传入的「焦点归还」节点。
  final FocusNode? focusNode;

  final VoidCallback onFocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: focusNode,
      debugLabel: 'ov.genre.${overview.key}',
      onFocusChange: (bool f) {
        if (f) onFocus();
      },
      onPressed: onPressed,
      builder: (BuildContext context, TvFocusStatus s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: TvFocusRing(
          status: s,
          radius: 14,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              Icon(
                _genreIconFor(overview),
                size: 24,
                color: overview.inferred ? TvColors.warn : TvColors.accent,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  overview.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 21,
                    height: _textHeight,
                    fontWeight: FontWeight.w600,
                    color: TvColors.text,
                  ),
                ),
              ),
              // 需求 §三.4：「风格概览可显示『推断』标识，
              // 避免把推断当作原始标签」。只有**整类都由推断得出**时才标 ——
              // 只要有一首是服务端标签或用户确认，就不该整类被标成推断。
              if (overview.inferred) ...<Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: TvColors.warn.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    '推断',
                    style: TextStyle(
                      fontSize: 13,
                      height: _textHeight,
                      color: TvColors.warn,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Text(
                '${overview.trackCount} 首',
                style: const TextStyle(
                  fontSize: 16,
                  height: _textHeight,
                  color: TvColors.textFaint,
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right,
                  size: 26, color: TvColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// 详情页头部：返回 + 标题 + 播放全部 / 随机播放。
///
/// 「返回」的焦点节点由 [OverviewPage] 持有（进入详情时要显式把焦点放上去，
/// 见 `_OverviewPageState._detailBackNode`）。
class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.title,
    required this.subtitle,
    required this.coverId,
    required this.roundCover,
    required this.backNode,
    required this.onBack,
    required this.onPlayAll,
    required this.onShuffle,
  });

  final String title;
  final String subtitle;
  final String? coverId;
  final bool roundCover;
  final FocusNode backNode;
  final VoidCallback onBack;
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final MusicRepository music = context.read<MusicRepository>();

    return _HeaderNodes(
      builder: (FocusNode playNode, FocusNode shuffleNode) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Row(
          children: <Widget>[
            TvFocus(
              focusNode: backNode,
              debugLabel: 'ovdetail.back',
              onPressed: onBack,
              nextDown: playNode,
              builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
                status: s,
                radius: 22,
                padding: EdgeInsets.zero,
                width: 46,
                height: 46,
                baseColor: const Color(0x33FFFFFF),
                child: const Icon(Icons.arrow_back,
                    size: 24, color: TvColors.text),
              ),
            ),
            const SizedBox(width: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(roundCover ? 26 : 10),
              child: CoverImage(
                music: music,
                coverId: coverId,
                size: 52,
                radius: roundCover ? 26 : 10,
                iconScale: 0.4,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: TvColors.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
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
            _HeaderAction(
              node: playNode,
              icon: Icons.play_arrow,
              label: '播放全部',
              nextLeft: backNode,
              nextRight: shuffleNode,
              onPressed: onPlayAll,
            ),
            const SizedBox(width: 10),
            _HeaderAction(
              node: shuffleNode,
              icon: Icons.shuffle,
              label: '随机',
              nextLeft: playNode,
              nextRight: null,
              onPressed: onShuffle,
            ),
          ],
        ),
      ),
    );
  }
}

/// 详情头部的「播放全部 / 随机」两个焦点节点由本 State
/// **一次性创建并跨帧保持**。
///
/// ⚠️ 绝不能在 `build` 里 `FocusNode()`：每次重建都会换一个新节点，
/// 旧节点泄漏、焦点瞬间丢失 —— 这正是电视端「焦点无故消失」的典型来源。
/// （「返回」的节点由 [OverviewPage] 自己持有，因为进入详情时要显式聚焦它。）
class _HeaderNodes extends StatefulWidget {
  const _HeaderNodes({required this.builder});

  final Widget Function(FocusNode play, FocusNode shuffle) builder;

  @override
  State<_HeaderNodes> createState() => _HeaderNodesState();
}

class _HeaderNodesState extends State<_HeaderNodes> {
  final FocusNode _play = FocusNode(debugLabel: 'ovdetail.play');
  final FocusNode _shuffle = FocusNode(debugLabel: 'ovdetail.shuffle');

  @override
  void dispose() {
    _play.dispose();
    _shuffle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_play, _shuffle);
}

/// 详情头部上的胶囊按钮。
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.node,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.nextLeft,
    required this.nextRight,
  });

  final FocusNode node;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode? nextLeft;
  final FocusNode? nextRight;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: node,
      debugLabel: 'ovdetail.$label',
      onPressed: onPressed,
      nextLeft: nextLeft,
      nextRight: nextRight,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: 22,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: TvColors.text),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 17, color: TvColors.text),
            ),
          ],
        ),
      ),
    );
  }
}
