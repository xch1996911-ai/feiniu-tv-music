import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/player_layout.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/repositories/lyric_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/pages/player_page.dart';
import 'package:feiniu_tv_music/ui/widgets/cover_image.dart';
import 'package:feiniu_tv_music/ui/widgets/tv_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'support/fake_lyric_source.dart';
import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 播放页布局的**可执行**分辨率矩阵（评审意见 C6）。
///
/// ## 先弄清一件事：面板分辨率对布局**没有任何直接影响**
///
/// Flutter 里所有尺寸都是**逻辑像素**（logical pixel），
/// 界面能看到的视口只有：
///
/// ```
/// 逻辑视口 = 物理像素 ÷ devicePixelRatio
/// devicePixelRatio = densityDpi / 160
/// ```
///
/// 所以「3840×2160 上布局会不会破」这个问题的前提是
/// **这台设备把 densityDpi 报成多少**。实测/DTS 里常见的组合：
///
/// | 面板物理像素 | densityDpi | dpr | 实际逻辑视口 | 备注 |
/// |---|---|---|---|---|
/// | 1920×1080 | 320 | 2.0 | **960×540** | Android TV 最常见（图4 的实机口径） |
/// | 1920×1080 | 240 | 1.5 | 1280×720 | |
/// | 1920×1080 | 160 | 1.0 | 1920×1080 | |
/// | 1280×720 | 240 | 1.5 | **853×480** | 最小的现实视口，压力用例 |
/// | 1280×720 | 160 | 1.0 | 1280×720 | |
/// | 3840×2160 | 640 | 4.0 | 960×540 | 4K 面板 + 高密度 |
/// | 3840×2160 | 320 | 2.0 | 1920×1080 | 4K 面板常见上报值 |
/// | 3840×2160 | 240 | 1.5 | 2560×1440 | |
/// | 3840×2160 | 160 | 1.0 | **3840×2160** | 4K 原生（界面只有 1/4 物理大小） |
///
/// 只测「1920×1080 逻辑像素」会得出「一切正常」的错误结论，
/// 而实机最常见的是 960×540 —— 这正是图4「一屏只有两张巨大专辑卡」的根因。
///
/// ## 这组测试要抓什么
///
/// 1. **纵向溢出**：正文里封面栏的固有高度超过它所在 `Expanded` 的可用高度。
///    在 debug 下 `RenderFlex` 溢出会抛异常（`takeException()` 拿得到），
///    而在 **release 下是静默裁切**（不打日志、不画黄黑条纹），
///    表现就是「歌曲规格信息被底部操作栏遮住」。
/// 2. **横向溢出**：底部操作条那一行的固有宽度是固定值之和，
///    逻辑视口偏小或系统字体放大时会顶破容器 —— 同样静默裁切。
/// 3. **系统字体缩放**：Android 的「字体大小 / 显示大小」会整体放大文字，
///    老代码的尺寸预算完全没算这一项。
/// ⚠️ **每个用例的显式超时**。
///
/// `flutter_test` 的默认超时是 **10 分钟**。这条默认值在本项目里已经造成过
/// 两次「CI 卡住 1 小时」：一个用例挂住 → 白白烧掉 10 分钟 → 而且它是在
/// `flutter test` 步骤内部挂的，从日志上看不出是哪一条。
/// 布局测试的正常耗时是**毫秒级**，45 秒已经宽到不可能误杀，
/// 但能让「挂住」在 45 秒内变成一条带用例名的失败。
const Timeout _fastFail = Timeout(Duration(seconds: 45));

void main() {
  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late PlaybackRepository playback;
  late LyricRepository lyrics;
  late LocalLibraryRepository local;

  setUp(() {
    music = FakeMusicRepository();
    engine = FakePlaybackEngine();
    playback = PlaybackRepository(music: music, handler: engine);
    lyrics = LyricRepository(FakeLyricSource.sample());
    local = LocalLibraryRepository(store: FakeSecureStore());
  });

  tearDown(() async {
    lyrics.dispose();
    playback.dispose();
    local.dispose();
    await engine.close();
  });

  /// 故意用**长标题 + 长歌手 + 长专辑 + 长规格串**：
  /// 两行标题是最坏情况，短标题测不出问题。
  Track longTrack() => const Track(
        guid: 'g1',
        title: '这是一个故意写得很长的歌曲标题用来强制折成两行',
        durationMs: 245000,
        album: AlbumRef(guid: 'al1', name: '同样很长的专辑名称占位'),
        artists: <ArtistRef>[
          ArtistRef(guid: 'ar1', name: '一位名字也不短的歌手'),
        ],
        audioSpec: AudioSpec(
          format: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          channel: 2,
        ),
      );

  final String chipText = longTrack().audioSpec.display;

  /// 按「物理像素 + dpr + 字体缩放」渲染播放页。
  ///
  /// 字体缩放刻意**不用** `MediaQuery.textScaler` 之外的 API：
  /// 直接在 `MaterialApp` 的 `home` 外面套一层 `MediaQuery`，
  /// 既不会碰到已废弃的 `textScaleFactorTestValue`，
  /// 也能保证它盖住 `WidgetsApp` 自己插入的那层 `MediaQuery`。
  Future<void> pumpAt(
    WidgetTester tester, {
    required Size physical,
    required double dpr,
    required PlayerLayout layout,
    double fontScale = 1.0,
  }) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);

    // ⚠️ 建队列 + 等加载**必须放进 `runAsync`**。
    //
    // `PlaybackRepository` 的加载串行链挂在**构造期创建**的
    // `Future<void>.value()` 上，而构造发生在 `setUp`（root Zone）；
    // `_Future._addListener` 用 `this._zone` 调度回调 ⇒ 这些回调排在
    // **root Zone 的微任务队列**里，`testWidgets` 的假时钟永远不推进它。
    // 于是这一个 `await` 永久挂起，而 `flutter_test` 的默认超时是 10 分钟 ——
    // CI 上表现为「flutter test 卡住一小时，且不说是哪一条」。
    // 既有 `tv_focus_test.dart` 已经踩过同一个坑（那里写得比我早、注释更全）。
    // `runAsync` 把回调放回真实事件循环，从而复现真实运行时的行为。
    await tester.runAsync(() async {
      await local.setPlayerLayout(layout);
      playback.setQueue(<Track>[longTrack()], startIndex: 0);
      // 等假引擎把"加载当前曲目"跑完，否则页面显示「尚未选择歌曲」，
      // 这组测试就变成了空测。
      await playback.pendingLoads;
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: <SingleChildWidget>[
          ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
          ChangeNotifierProvider<LyricRepository>.value(value: lyrics),
          ChangeNotifierProvider<MusicRepository>.value(value: music),
          ChangeNotifierProvider<LocalLibraryRepository>.value(value: local),
        ],
        child: MaterialApp(
          theme: buildTvTheme(),
          home: Builder(
            builder: (BuildContext ctx) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(
                textScaler: TextScaler.linear(fontScale),
              ),
              child: Scaffold(body: PlayerPage(onBack: () {})),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// (标签, 物理像素, dpr) —— 逻辑视口 = 物理 ÷ dpr，见文件头表格。
  const List<List<Object>> panels = <List<Object>>[
    <Object>[
      '1080p 面板 · dpi320 → 960×540（Android TV 最常见）',
      Size(1920, 1080),
      2.0,
    ],
    <Object>['1080p 面板 · dpi240 → 1280×720', Size(1920, 1080), 1.5],
    <Object>['1080p 面板 · dpi160 → 1920×1080', Size(1920, 1080), 1.0],
    <Object>['720p 面板 · dpi240 → 853×480（最小现实视口）', Size(1280, 720), 1.5],
    <Object>['720p 面板 · dpi160 → 1280×720', Size(1280, 720), 1.0],
    <Object>['4K 面板 · dpi640 → 960×540', Size(3840, 2160), 4.0],
    <Object>['4K 面板 · dpi320 → 1920×1080', Size(3840, 2160), 2.0],
    <Object>['4K 面板 · dpi240 → 2560×1440', Size(3840, 2160), 1.5],
    <Object>['4K 面板 · dpi160 → 3840×2160（4K 原生）', Size(3840, 2160), 1.0],
  ];

  /// 系统字体缩放：1.0 = 默认；1.3 = Android「字体大小」调大一档（常见设置）。
  const List<double> fontScales = <double>[1.0, 1.3];

  for (final List<Object> panel in panels) {
    final String label = panel[0] as String;
    final Size physical = panel[1] as Size;
    final double dpr = panel[2] as double;

    for (final PlayerLayout layout in PlayerLayout.values) {
      for (final double fs in fontScales) {
        testWidgets('$label · ${layout.name} · 字体 ${fs}x',
            timeout: _fastFail,
            (WidgetTester tester) async {
          await pumpAt(
            tester,
            physical: physical,
            dpr: dpr,
            layout: layout,
            fontScale: fs,
          );

          final double vw = physical.width / dpr;
          final double vh = physical.height / dpr;

          // ① 先钉住「模型」本身：逻辑视口 = 物理 ÷ dpr。
          //    这一条如果不成立，下面所有断言都是在测错的尺寸。
          final Size page = tester.getSize(find.byType(PlayerPage));
          expect(page.width, closeTo(vw, 0.5), reason: '逻辑视口宽应为 $vw');
          expect(page.height, closeTo(vh, 0.5), reason: '逻辑视口高应为 $vh');

          // ② 溢出：debug 下 RenderFlex 溢出会抛异常，
          //    release 下则是**静默裁切**（实机表现就是「内容被遮住」）。
          final Object? layoutError = tester.takeException();
          if (layoutError != null) {
            // ⚠️ `takeException()` 把异常吞掉了，flutter_test 就不会打印
            //    RenderFlex 的完整转储（含 constraints 与 creator 链），
            //    日志里只剩一句「overflowed by N pixels」——定位不到是谁。
            //    这里把 diagnostics 与关键几何一起打进日志。
            debugPrint('LAYOUT_OVERFLOW_DETAIL >>> $layoutError');
            if (layoutError is FlutterError) {
              // 刻意用 `dynamic` 迭代：`DiagnosticsNode` 不一定被
              // `package:flutter/material.dart` 的 `show` 列表导出，
              // 显式写下类型名会让 analyze 直接失败（本项目 info 也判失败）。
              for (final dynamic node in layoutError.diagnostics) {
                debugPrint('LAYOUT_OVERFLOW_NODE >>> '
                    '${node.toStringDeep().replaceAll('\n', ' | ')}');
              }
            }
            final Rect? seekRect = _rectOf(tester, 'player.seek');
            final Rect? backRect = _rectOf(tester, 'player.back');
            final Rect chipRect = tester.getRect(find.text(chipText));
            final String lyricTitle =
                '${longTrack().title} - ${longTrack().artistNames}';
            final Finder lyricFinder = find.text(lyricTitle);
            final Finder coverFinder = find.byType(CoverImage);
            debugPrint('LAYOUT_GEOMETRY >>> viewport=$vw×$vh '
                'seek=${seekRect?.toString()} barTop=${backRect?.top} '
                'barBottom=${backRect?.bottom} '
                'bar=${find.byType(TvGlass).evaluate().isEmpty ? '—' : tester.getRect(find.byType(TvGlass).first)} '
                'cover=${coverFinder.evaluate().isEmpty ? '—' : tester.getRect(coverFinder.first)} '
                'chip=$chipRect '
                'lyricTitle=${lyricFinder.evaluate().isEmpty ? '—' : tester.getRect(lyricFinder)}');
          }
          expect(layoutError, isNull,
              reason: '出现布局溢出（release 下会静默裁掉内容）');

          // ③ 规格胶囊（实机被切掉的就是它）必须完整落在视口内。
          final Finder chip = find.text(chipText);
          expect(chip, findsOneWidget, reason: '规格胶囊必须被渲染出来');
          final Rect chipRect = tester.getRect(chip);
          expect(chipRect.width, greaterThan(0), reason: '胶囊宽度为 0');
          expect(chipRect.top, greaterThanOrEqualTo(-0.5),
              reason: '胶囊顶部被切: $chipRect');
          expect(chipRect.bottom, lessThanOrEqualTo(vh + 0.5),
              reason: '胶囊底部被切（视口高 $vh）: $chipRect');

          // ④ 纵向顺序必须是「正文 → 进度区 → 最底部操作条」。
          final Rect? seekN = _rectOf(tester, 'player.seek');
          final Rect? playN = _rectOf(tester, 'player.play');
          expect(seekN, isNotNull, reason: '找不到进度区');
          expect(playN, isNotNull, reason: '找不到播放按钮');
          expect(seekN!.center.dy, lessThan(playN!.center.dy),
              reason: '顺序要求「正文 → 进度区 → 最底部操作条」：'
                  'seek.dy=${seekN.center.dy} play.dy=${playN.center.dy}');

          // ⑤ 操作条两端与底部都必须在视口内 —— 这一条专抓**水平**溢出
          //    （老代码在 853×480 或字体放大时会把最右端切掉）。
          final Rect? backN = _rectOf(tester, 'player.back');
          final Rect? queueN = _rectOf(tester, 'player.queue');
          expect(backN, isNotNull, reason: '找不到返回按钮');
          expect(queueN, isNotNull, reason: '找不到队列按钮');
          expect(backN!.left, greaterThanOrEqualTo(-0.5),
              reason: '操作条左端被切: $backN');
          expect(queueN!.right, lessThanOrEqualTo(vw + 0.5),
              reason: '操作条右端被切（视口宽 $vw）: $queueN');
          expect(queueN.bottom, lessThanOrEqualTo(vh + 0.5),
              reason: '操作条底部被切（视口高 $vh）: $queueN');
        });
      }
    }
  }

  testWidgets('4K 原生视口（3840×2160）不破版，但界面**不随视口放大**——记录当前口径',
      timeout: _fastFail,
      (WidgetTester tester) async {
    // 结论要区分两件事，不能混着说：
    //   · 布局**没有破**：上面的矩阵已断言无溢出、无裁切；
    //   · 但界面元素仍是 960×540 那套**逻辑**尺寸，在 2160 高的面板上
    //     只占 1/4 的物理高度 —— 客厅距离下会小到看不清。
    // 这条用例把这个现状**固定下来**：一旦有人在某处引入「按视口缩放」的系数，
    // 它会立刻变红，提醒把这里的断言和交付说明里的结论一起更新。
    await pumpAt(
      tester,
      physical: const Size(1920, 1080),
      dpr: 2.0,
      layout: PlayerLayout.stage,
    );
    final Rect common = _rectOf(tester, 'player.play')!;

    await pumpAt(
      tester,
      physical: const Size(3840, 2160),
      dpr: 1.0,
      layout: PlayerLayout.stage,
    );
    final Rect native4k = _rectOf(tester, 'player.play')!;

    expect(native4k.size.width, closeTo(common.size.width, 0.01),
        reason: '两处的**逻辑**尺寸相同 —— 说明按固定逻辑尺寸设计，未按视口缩放');

    // 占屏幕高度的比例：960×540 下约 15%，4K 原生下约 3.8%。
    expect(common.size.height / 540, greaterThan(0.13),
        reason: '960×540 上播放按钮应占屏高 13% 以上');
    expect(native4k.size.height / 2160, lessThan(0.05),
        reason: '4K 原生视口下播放按钮只占屏高不到 5%（约 3.8%）—— '
            '布局不破，但需要真机确认远距离可读性');
  });
}

/// 用 `FocusNode.debugLabel` 找到控件的矩形。
Rect? _rectOf(WidgetTester tester, String label) {
  for (final Element e in find.byType(Focus).evaluate()) {
    final Focus w = e.widget as Focus;
    if (w.focusNode?.debugLabel != label) continue;
    return tester.getRect(find.byWidget(w));
  }
  return null;
}
