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
import 'package:feiniu_tv_music/ui/widgets/lyric_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'support/fake_lyric_source.dart';
import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 播放页布局的**可执行**分辨率矩阵（V6 融合版式）。
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
/// | 面板物理像素 | densityDpi | dpr | 实际逻辑视口 | 备注 |
/// |---|---|---|---|---|
/// | 1920×1080 | 320 | 2.0 | **960×540** | Android TV 最常见 |
/// | 1920×1080 | 240 | 1.5 | 1280×720 | |
/// | 1920×1080 | 160 | 1.0 | 1920×1080 | |
/// | 1280×720 | 240 | 1.5 | **853×480** | 最小的现实视口，压力用例 |
/// | 1280×720 | 160 | 1.0 | 1280×720 | |
/// | 3840×2160 | 640 | 4.0 | 960×540 | 4K 面板 + 高密度 |
/// | 3840×2160 | 320 | 2.0 | 1920×1080 | 4K 面板常见上报值 |
/// | 3840×2160 | 240 | 1.5 | 2560×1440 | |
/// | 3840×2160 | 160 | 1.0 | **3840×2160** | 4K 原生（界面只有 1/4 物理大小） |
///
/// ## 这组测试要抓什么
///
/// 1. **溢出**：debug 下 `RenderFlex` 溢出会抛异常（release 下是**静默裁切**，
///    实机表现就是「内容被遮住」）。
/// 2. **系统字体缩放**：Android 的「字体大小 / 显示大小」会整体放大文字。
/// 3. **纵向顺序**：信息行 → 进度区 → 控制行必须自上而下。
/// 4. **关键控件完整落在视口内**（规格小字、返回键、队列键）。
///
/// ⚠️ **每个用例的显式超时**：`flutter_test` 默认 10 分钟，本项目已两次
/// 因单条用例挂住而烧掉整条 CI；45 秒宽到不可能误杀正常用例。
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

    // ⚠️ 建队列 + 等加载**必须放进 `runAsync`**（root Zone 微任务问题，
    // 详见 tv_focus_test.dart 注释）。
    await tester.runAsync(() async {
      await local.setPlayerLayout(layout);
      playback.setQueue(<Track>[longTrack()], startIndex: 0);
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
          final Size page = tester.getSize(find.byType(PlayerPage));
          expect(page.width, closeTo(vw, 0.5), reason: '逻辑视口宽应为 $vw');
          expect(page.height, closeTo(vh, 0.5), reason: '逻辑视口高应为 $vh');

          // ② 溢出：debug 下 RenderFlex 溢出会抛异常，
          //    release 下则是**静默裁切**（实机表现就是「内容被遮住」）。
          final Object? layoutError = tester.takeException();
          if (layoutError != null) {
            // 把 diagnostics 与关键几何一起打进日志，便于 CI 定位。
            debugPrint('LAYOUT_OVERFLOW_DETAIL >>> $layoutError');
            if (layoutError is FlutterError) {
              for (final dynamic node in layoutError.diagnostics) {
                debugPrint('LAYOUT_OVERFLOW_NODE >>> '
                    '${node.toStringDeep().replaceAll('\n', ' | ')}');
              }
            }
            final Rect? seekRect = _rectOf(tester, 'player.seek');
            final Rect? backRect = _rectOf(tester, 'player.back');
            final Rect? playRect = _rectOf(tester, 'player.play');
            final Finder coverFinder = find.byType(CoverImage);
            debugPrint('LAYOUT_GEOMETRY >>> viewport=$vw×$vh '
                'seek=${seekRect?.toString()} back=${backRect?.toString()} '
                'play=${playRect?.toString()} '
                'cover=${coverFinder.evaluate().isEmpty ? '—' : tester.getRect(coverFinder.first)}');
          }
          expect(layoutError, isNull,
              reason: '出现布局溢出（release 下会静默裁掉内容）');

          // ③ 规格（含码率）必须以小字渲染，且完整落在视口内。
          //    融合布局里它在进度条下方；大封面布局里还有 _Chip —— 至少一处。
          final Finder specs = find.text(chipText);
          expect(specs, findsAtLeastNWidgets(1),
              reason: '音频规格必须被渲染出来');
          for (final Element e in specs.evaluate()) {
            final Rect r = tester.getRect(find.byWidget(e.widget));
            expect(r.top, greaterThanOrEqualTo(-0.5),
                reason: '规格顶部被切: $r');
            expect(r.bottom, lessThanOrEqualTo(vh + 0.5),
                reason: '规格底部被切（视口高 $vh）: $r');
          }

          // ④ 纵向顺序必须是「信息行 → 进度区 → 控制行」。
          final Rect? seekN = _rectOf(tester, 'player.seek');
          final Rect? playN = _rectOf(tester, 'player.play');
          expect(seekN, isNotNull, reason: '找不到进度区');
          expect(playN, isNotNull, reason: '找不到播放按钮');
          expect(seekN!.center.dy, lessThan(playN!.center.dy),
              reason: '顺序要求「信息 → 进度 → 控制」：'
                  'seek.dy=${seekN.center.dy} play.dy=${playN.center.dy}');

          // ⑤ 关键控件完整落在视口内 —— 专抓**水平/垂直**裁切。
          final Rect? backN = _rectOf(tester, 'player.back');
          final Rect? queueN = _rectOf(tester, 'player.queue');
          expect(backN, isNotNull, reason: '找不到返回按钮');
          expect(queueN, isNotNull, reason: '找不到队列按钮');
          expect(backN!.left, greaterThanOrEqualTo(-0.5),
              reason: '返回按钮被切: $backN');
          expect(queueN!.right, lessThanOrEqualTo(vw + 0.5),
              reason: '队列按钮右端被切（视口宽 $vw）: $queueN');
          expect(queueN.bottom, lessThanOrEqualTo(vh + 0.5),
              reason: '队列按钮底部被切（视口高 $vh）: $queueN');

          // ⑥ 融合布局专属：标题在进度区上方、封面与歌词区同时存在。
          if (layout == PlayerLayout.stage) {
            final Rect titleRect = tester.getRect(find.text(longTrack().title));
            expect(titleRect.top, lessThan(seekN.top),
                reason: '歌名必须高于进度区');
            expect(find.byType(CoverImage), findsOneWidget);
            expect(find.byType(LyricView), findsOneWidget,
                reason: '右侧歌词区必须存在');
          }
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

    // 占屏幕高度的比例：960×540 下约 14%，4K 原生下约 3.5%。
    expect(common.size.height / 540, greaterThan(0.13),
        reason: '960×540 上播放按钮应占屏高 13% 以上');
    expect(native4k.size.height / 2160, lessThan(0.05),
        reason: '4K 原生视口下播放按钮只占屏高不到 5% —— '
            '布局不破，但需要真机确认远距离可读性');
  });

  testWidgets('融合背景：换歌交叉淡化、无封面回落渐变（不抛异常）',
      timeout: _fastFail, (WidgetTester tester) async {
    // 测试环境里封面网络请求必然失败 → errorBuilder 降级为透明层，
    // 背景只剩兜底渐变 —— 本用例钉住「失败路径绝不抛异常、不阻塞布局」。
    await pumpAt(
      tester,
      physical: const Size(1920, 1080),
      dpr: 2.0,
      layout: PlayerLayout.stage,
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(AnimatedSwitcher), findsOneWidget);
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
