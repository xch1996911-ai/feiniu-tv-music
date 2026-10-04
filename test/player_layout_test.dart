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
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'support/fake_lyric_source.dart';
import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 【V5 修复】播放页布局的**可执行**回归（对应评审意见 C6）。
///
/// ## 这组测试要抓什么
///
/// 实机现象是「底部操作栏遮挡内容」/「歌曲规格信息被切掉」。
/// 读代码可以看到真实的机制不是"浮层盖住"，而是：
/// 1. 正文里封面栏的固有高度**超过**它所在 `Expanded` 的可用高度；
/// 2. Flutter 在 **release 构建下把 `RenderFlex` 溢出静默裁切**
///    （不打日志、不画黄黑条纹，条纹只在 debug 出现）。
///
/// 于是「在 debug 下跑一遍测试」正好能抓住它 —— 溢出在 debug 会抛异常，
/// `tester.takeException()` 拿得到。这比"看截图"客观得多，也能进 CI。
///
/// ## 为什么分辨率要写 1920×1080 + dpr 2.0
///
/// Android TV 在 1080p 面板上常见上报 **density 2.0**，Flutter 侧的逻辑视口
/// 只有 **960×540** —— 这才是实机真正面对的尺寸。
/// 只测 1920×1080 逻辑像素会得出"一切正常"的错误结论。
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
  Track longTrack() => Track(
        guid: 'g1',
        title: '这是一个故意写得很长的歌曲标题用来强制折成两行',
        durationMs: 245000,
        album: const AlbumRef(guid: 'al1', name: '同样很长的专辑名称占位'),
        artists: const <ArtistRef>[
          ArtistRef(guid: 'ar1', name: '一位名字也不短的歌手'),
        ],
        audioSpec: const AudioSpec(
          format: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          channel: 2,
        ),
      );

  final String chipText = longTrack().audioSpec.display;

  /// 逻辑视口 = physicalSize / devicePixelRatio。
  Future<void> pumpAt(
    WidgetTester tester, {
    required Size physical,
    required double dpr,
    required PlayerLayout layout,
  }) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);

    await local.setPlayerLayout(layout);
    playback.setQueue(<Track>[longTrack()], startIndex: 0);
    // 等假引擎把"加载当前曲目"跑完，否则页面显示「尚未选择歌曲」，
    // 这组测试就变成了空测。
    await playback.pendingLoads;

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
          home: Scaffold(body: PlayerPage(onBack: () {})),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// 三种分辨率 × 两种布局。第一行才是实机的真实逻辑视口。
  const List<List<Object>> cases = <List<Object>>[
    <Object>['960×540（电视 1080p + density 2.0，实机口径）', Size(1920, 1080), 2.0],
    <Object>['1280×720', Size(1280, 720), 1.0],
    <Object>['1920×1080', Size(1920, 1080), 1.0],
  ];

  for (final List<Object> c in cases) {
    final String label = c[0] as String;
    final Size physical = c[1] as Size;
    final double dpr = c[2] as double;

    for (final PlayerLayout layout in PlayerLayout.values) {
      testWidgets('$label · ${layout.name}：不得溢出，规格胶囊必须完整可见',
          (WidgetTester tester) async {
        await pumpAt(tester, physical: physical, dpr: dpr, layout: layout);

        // ① 溢出：debug 下 RenderFlex 溢出会抛异常，release 下则是静默裁切。
        expect(tester.takeException(), isNull,
            reason: '出现了 RenderFlex 溢出 —— 在 release 里这会表现为内容被静默裁掉');

        // ② 规格胶囊（实机被切掉的就是它）必须完整落在视口内。
        final Finder chip = find.text(chipText);
        expect(chip, findsOneWidget, reason: '规格胶囊必须被渲染出来');
        final Rect r = tester.getRect(chip);
        final double vh = tester.view.physicalSize.height / dpr;
        expect(r.top, greaterThanOrEqualTo(0), reason: '胶囊顶部被切: $r');
        expect(r.bottom, lessThanOrEqualTo(vh),
            reason: '胶囊底部被切（视口高 $vh）: $r');

        // ③ 进度区必须在操作条**上方**（顺序要求）。
        final Rect? seek = _rectOf(tester, 'player.seek');
        final Rect? play = _rectOf(tester, 'player.play');
        expect(seek, isNotNull, reason: '进度区必须存在');
        expect(play, isNotNull, reason: '操作条上的播放按钮必须存在');
        expect(seek!.center.dy, lessThan(play!.center.dy),
            reason: '“正文 → 进度区 → 最底部操作条”的顺序被破坏：'
                'seek.dy=${seek.center.dy} play.dy=${play.center.dy}');
      });
    }
  }
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
