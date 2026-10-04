import 'dart:math' as math;

import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/pages/overview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 专辑网格在不同**逻辑视口**下的列数与溢出检查。
///
/// ## 为什么单独测这一页
///
/// 图4 的实机问题是「一屏只有两张巨大的专辑卡」。根因不是"宽屏没铺满"，
/// 而是**列数阈值按 1920 逻辑宽标定，而电视上真实的逻辑视口只有 960×540**
/// （1080p 面板 + densityDpi 320）：
///
/// ```
/// 可用宽 = 960 - 206(侧栏) - 40(内边距) = 714
/// 老阈值 250 → floor(714 / (250 + 12)) = 2   ← 就是图4
/// 新阈值 150 → floor(714 / (150 + 12)) = 4
/// ```
///
/// 所以这一页的列数**必须**按真实逻辑视口验收，而不是按面板分辨率。
/// 物理像素与 dpr 的对应关系见 `player_layout_test.dart` 的文件头表格。
/// 见 `player_layout_test.dart` 里同一常量的说明：把 10 分钟的默认超时
/// 压到 45 秒，让「挂住」变成一条带用例名的失败，而不是烧掉一小时 CI。
const Timeout _fastFail = Timeout(Duration(seconds: 45));

void main() {
  /// 侧栏固定宽度（与 `NavRail` 一致）。这里用常量占位，
  /// 因为本用例只关心**内容区**的可用宽度。
  const double railWidth = 206;

  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late PlaybackRepository playback;
  late LibraryRepository library;
  late LocalLibraryRepository local;

  setUp(() {
    music = FakeMusicRepository();
    engine = FakePlaybackEngine();
    playback = PlaybackRepository(music: music, handler: engine);
    library = LibraryRepository(music);
    local = LocalLibraryRepository(store: FakeSecureStore());
  });

  tearDown(() async {
    library.dispose();
    playback.dispose();
    local.dispose();
    await engine.close();
  });

  /// 9 张专辑 —— 足够在任何列数下铺满第一行。
  List<Track> catalogue() => <Track>[
        for (int i = 1; i <= 9; i++)
          Track(
            guid: 'g$i',
            title: '歌曲$i',
            durationMs: 180000,
            album: AlbumRef(guid: 'al$i', name: '专辑$i'),
            artists: <ArtistRef>[ArtistRef(guid: 'ar$i', name: '歌手$i')],
            audioSpec: const AudioSpec(
              format: 'flac',
              sampleRate: 44100,
              bitDepth: 16,
            ),
          ),
      ];

  Future<void> pumpGrid(
    WidgetTester tester, {
    required Size physical,
    required double dpr,
  }) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);

    music.catalogue = catalogue();
    await tester.runAsync(() async {
      await library.loadFirst();
    });

    final double vw = physical.width / dpr;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryRepository>.value(value: library),
          ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
          ChangeNotifierProvider<LocalLibraryRepository>.value(value: local),
          ChangeNotifierProvider<MusicRepository>.value(value: music),
        ],
        child: MaterialApp(
          theme: buildTvTheme(),
          home: Scaffold(
            body: Row(
              children: <Widget>[
                const SizedBox(width: railWidth),
                Expanded(
                  child: OverviewPage(
                    kind: OverviewKind.album,
                    title: '专辑',
                    emptyHint: '暂无专辑',
                    detail: null,
                    onOpenDetail: (LibraryOverview o) {},
                    onCloseDetail: () {},
                    onOpenPlayer: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 内容区可用宽度必须正好是「逻辑宽 - 侧栏」—— 列数全靠它算。
    final Size content = tester.getSize(find.byType(OverviewPage));
    expect(content.width, closeTo(vw - railWidth, 1.0),
        reason: '内容区宽度应为 $vw - $railWidth');
  }

  /// 第一行里有多少张专辑卡 = 实际列数。
  int firstRowColumns(WidgetTester tester) {
    final List<Rect> rects = <Rect>[];
    for (int i = 1; i <= 9; i++) {
      final Finder f = find.text('专辑$i');
      if (f.evaluate().isEmpty) continue;
      rects.add(tester.getRect(f));
    }
    expect(rects, isNotEmpty, reason: '网格里必须渲染出专辑卡');
    final double top = rects.map((Rect r) => r.top).reduce(math.min);
    return rects.where((Rect r) => (r.top - top).abs() < 1.0).length;
  }

  /// (标签, 物理像素, dpr, 期望列数)。
  ///
  /// 期望值按 `floor((逻辑宽 - 206 - 40) / (150 + 12)).clamp(3, 6)` 推出，
  /// 写死在这里是为了**钉住行为**：阈值或侧栏宽度一改，这里就会变红，
  /// 提醒重新核对实机列数，而不是悄悄退化回 2 列。
  const List<List<Object>> cases = <List<Object>>[
    <Object>['1080p 面板 · dpi320 → 960×540（最常见）', Size(1920, 1080), 2.0, 4],
    <Object>['720p 面板 · dpi240 → 853×480（最小现实视口）', Size(1280, 720), 1.5, 3],
    <Object>['1080p 面板 · dpi160 → 1920×1080', Size(1920, 1080), 1.0, 6],
    <Object>['4K 面板 · dpi640 → 960×540', Size(3840, 2160), 4.0, 4],
    <Object>['4K 面板 · dpi320 → 1920×1080', Size(3840, 2160), 2.0, 6],
    <Object>['4K 面板 · dpi160 → 3840×2160（4K 原生）', Size(3840, 2160), 1.0, 6],
  ];

  for (final List<Object> c in cases) {
    final String label = c[0] as String;
    final Size physical = c[1] as Size;
    final double dpr = c[2] as double;
    final int expected = c[3] as int;

    testWidgets('$label：列数 $expected，且瓦片不溢出',
        timeout: _fastFail, (WidgetTester tester) async {
      await pumpGrid(tester, physical: physical, dpr: dpr);

      final double vw = physical.width / dpr;
      final double vh = physical.height / dpr;

      // 溢出在 release 下是静默裁切 —— 必须以异常形式在 debug 抓住。
      expect(tester.takeException(), isNull, reason: '网格出现布局溢出');

      expect(firstRowColumns(tester), expected,
          reason: '第一行列数应为 $expected（逻辑视口 $vw×$vh）');

      // ⚠️ 只断言**第一行**完整可见。
      //    网格是可滚动的：第二行被视口下沿裁掉是正常行为，不是布局缺陷
      //    （最初写成「所有卡片都必须在屏内」，在 853×480 上必然误报）。
      //    横向被切才是真 bug —— 那说明列宽算错了。
      final List<Rect> rects = <Rect>[];
      for (int i = 1; i <= 9; i++) {
        final Finder f = find.text('专辑$i');
        if (f.evaluate().isEmpty) continue;
        rects.add(tester.getRect(f));
      }
      final double top = rects.map((Rect r) => r.top).reduce(math.min);
      final List<Rect> firstRow =
          rects.where((Rect r) => (r.top - top).abs() < 1.0).toList();
      expect(firstRow.length, expected, reason: '第一行应当正好有 $expected 张');
      for (final Rect r in firstRow) {
        expect(r.left, greaterThanOrEqualTo(-0.5), reason: '第一行卡片左侧被切: $r');
        expect(r.right, lessThanOrEqualTo(vw + 0.5),
            reason: '第一行卡片右侧被切: $r');
        expect(r.bottom, lessThanOrEqualTo(vh + 0.5),
            reason: '第一行卡片底部被切（视口高 $vh）: $r');
      }
    });
  }
}
