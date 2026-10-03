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
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

Track tr(
  String guid, {
  required String title,
  String artist = '',
  String artistGuid = '',
  String album = '',
  String albumGuid = '',
}) =>
    Track(
      guid: guid,
      title: title,
      durationMs: 180000,
      album: AlbumRef(guid: albumGuid, name: album),
      artists: artist.isEmpty
          ? const <ArtistRef>[]
          : <ArtistRef>[ArtistRef(guid: artistGuid, name: artist)],
      audioSpec: const AudioSpec(format: 'flac', sampleRate: 44100, bitDepth: 16),
    );

/// 迷你版 Shell：只为 `OverviewPage` 提供「详情开没开」这一个外部状态。
///
/// ⚠️ 真实 App 里这份状态放在 `AppShell`（因为 `PopScope.canPop` 是所有
/// 注册者的与运算，全 App 只能有一个）。测试里用最小实现复现同一套契约。
class _Host extends StatefulWidget {
  const _Host({required this.kind, required this.emptyHint});

  final OverviewKind kind;
  final String emptyHint;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  LibraryOverview? _detail;
  int openPlayerCalls = 0;

  @override
  Widget build(BuildContext context) {
    return OverviewPage(
      kind: widget.kind,
      title: switch (widget.kind) {
        OverviewKind.artist => '歌手',
        OverviewKind.album => '专辑',
        OverviewKind.genre => '风格',
      },
      emptyHint: widget.emptyHint,
      detail: _detail,
      onOpenDetail: (LibraryOverview o) => setState(() => _detail = o),
      onCloseDetail: () => setState(() => _detail = null),
      onOpenPlayer: () => openPlayerCalls++,
    );
  }
}

void main() {
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

  String? focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  /// 按 `debugLabel` 找到 `TvFocus` 内部那个 `FocusNode` 并聚焦。
  ///
  /// 概览行不设 `autofocus`（进入页面的初始焦点由 Shell 给到左侧导航），
  /// 所以测试要自己把焦点放到目标行上，才能按 OK 进详情。
  FocusNode? nodeForLabel(WidgetTester tester, String label) {
    for (final Focus f in tester.widgetList<Focus>(find.byType(Focus))) {
      if (f.focusNode?.debugLabel == label) return f.focusNode;
    }
    return null;
  }

  Future<void> focusLabel(WidgetTester tester, String label) async {
    final FocusNode? n = nodeForLabel(tester, label);
    expect(n, isNotNull, reason: '找不到焦点节点 $label');
    n!.requestFocus();
    await tester.pump();
    expect(focusedLabel(), label);
  }

  Future<void> pumpHost(
    WidgetTester tester, {
    required OverviewKind kind,
    String emptyHint = '空',
    List<Track> catalogue = const <Track>[],
  }) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    music.catalogue = catalogue;
    await tester.runAsync(() async {
      await library.loadFirst();
    });

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
            body: _Host(kind: kind, emptyHint: emptyHint),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> tearDownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  final List<Track> artistCatalogue = <Track>[
    tr('t1', title: '遇见', artist: '孙燕姿', artistGuid: 'ar_syz', album: 'The Moment', albumGuid: 'alb_a'),
    tr('t2', title: '天黑黑', artist: '孙燕姿', artistGuid: 'ar_syz', album: '孙燕姿', albumGuid: 'alb_b'),
    tr('t3', title: '晴天', artist: '周杰伦', artistGuid: 'ar_jl', album: '叶惠美', albumGuid: 'alb_c'),
  ];

  group('歌手：概览 → 详情（需求「一、1」）', () {
    testWidgets('概览只画统计，不展开曲目', (WidgetTester tester) async {
      await pumpHost(tester, kind: OverviewKind.artist, catalogue: artistCatalogue);

      expect(find.text('共 2 位歌手'), findsOneWidget);

      // 每位歌手一行，显示「N 首歌 · M 张专辑」
      expect(find.text('孙燕姿'), findsOneWidget);
      expect(find.text('2 首歌 · 2 张专辑'), findsOneWidget);
      expect(find.text('周杰伦'), findsOneWidget);
      expect(find.text('1 首歌 · 1 张专辑'), findsOneWidget);

      // 概览里**不能**出现具体曲目（旧版的毛病就是直接铺开全部歌曲）
      expect(find.text('遇见'), findsNothing);
      expect(find.text('天黑黑'), findsNothing);

      await tearDownTree(tester);
    });

    testWidgets('点选歌手 → 进详情，展示该歌手的曲目与统计',
        (WidgetTester tester) async {
      await pumpHost(tester, kind: OverviewKind.artist, catalogue: artistCatalogue);

      await focusLabel(tester, 'ov.artist.a:ar_syz');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(find.text('播放全部'), findsOneWidget);
      expect(find.text('随机'), findsOneWidget);

      // 详情头部：该歌手的两首歌都在，别的歌手的不在
      expect(find.text('遇见'), findsOneWidget);
      expect(find.text('天黑黑'), findsOneWidget);
      expect(find.text('晴天'), findsNothing);

      await tearDownTree(tester);
    });

    testWidgets('进详情后焦点落在「返回」上（不会平白消失）',
        (WidgetTester tester) async {
      await pumpHost(tester, kind: OverviewKind.artist, catalogue: artistCatalogue);

      await focusLabel(tester, 'ov.artist.a:ar_syz');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(focusedLabel(), 'ovdetail.back',
          reason: '概览行被卸载后焦点会消失，必须显式交给详情页的返回按钮');

      await tearDownTree(tester);
    });

    testWidgets('从详情返回 → 回到概览，且焦点回到原来那一行',
        (WidgetTester tester) async {
      await pumpHost(tester, kind: OverviewKind.artist, catalogue: artistCatalogue);

      // 先停在第二位歌手（周杰伦）上，再进去 —— 这样才测得出「回原位置」
      await focusLabel(tester, 'ov.artist.a:ar_jl');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(focusedLabel(), 'ovdetail.back');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // 返回
      await tester.pump();
      await tester.pump();

      // 回到概览
      expect(find.text('共 2 位歌手'), findsOneWidget);
      expect(find.text('播放全部'), findsNothing);
      expect(focusedLabel(), 'ov.artist.a:ar_jl',
          reason: '返回后焦点必须回到原来那一行，否则遥控器会「失灵」一次');

      await tearDownTree(tester);
    });
  });

  group('专辑：概览 → 详情（需求「一、2」）', () {
    testWidgets('概览显示封面 / 专辑名 / 歌手 / 歌曲数', (WidgetTester tester) async {
      await pumpHost(tester, kind: OverviewKind.album, catalogue: artistCatalogue);

      expect(find.text('共 3 张专辑'), findsOneWidget);
      expect(find.text('The Moment'), findsOneWidget);
      // ⚠️ 孙燕姿有两张专辑（The Moment / 孙燕姿），副标题都是「孙燕姿 · 1 首」，
      //    所以这里必须是 2 个 —— 用 findsOneWidget 是测试自己写错了。
      expect(find.text('孙燕姿 · 1 首'), findsNWidgets(2));
      expect(find.text('叶惠美'), findsOneWidget);
      expect(find.text('周杰伦 · 1 首'), findsOneWidget);

      await tearDownTree(tester);
    });

    testWidgets('点选专辑 → 进详情，只显示该专辑的曲目',
        (WidgetTester tester) async {
      await pumpHost(tester, kind: OverviewKind.album, catalogue: artistCatalogue);

      await focusLabel(tester, 'ov.album.al:alb_c'); // 叶惠美
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('遇见'), findsNothing);

      await tearDownTree(tester);
    });
  });

  group('风格：无标签时如实说明（需求「一、3」）', () {
    testWidgets('曲库没有风格标签 → 显示空态，绝不把全部歌曲塞进「未知风格」',
        (WidgetTester tester) async {
      await pumpHost(
        tester,
        kind: OverviewKind.genre,
        emptyHint: '暂无风格标签\n\n飞牛曲目的 genres 字段在当前曲库里是空的。',
        catalogue: artistCatalogue, // 三首歌的 genres 都是空数组
      );

      expect(find.textContaining('暂无风格标签'), findsOneWidget);
      // 不能出现「未知风格」这种凭空造出来的分类
      expect(find.textContaining('未知风格'), findsNothing);
      // 也不能退化成把全部曲目列出来
      expect(find.text('遇见'), findsNothing);
      expect(find.text('晴天'), findsNothing);

      await tearDownTree(tester);
    });
  });

  group('概览页的焦点链', () {
    testWidgets('歌手行之间可以遥控器上下移动', (WidgetTester tester) async {
      await pumpHost(tester, kind: OverviewKind.artist, catalogue: artistCatalogue);

      await focusLabel(tester, 'ov.artist.a:ar_syz');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'ov.artist.a:ar_jl', reason: '↓ 应到下一位歌手');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'ov.artist.a:ar_syz', reason: '↑ 应回到上一位歌手');

      await tearDownTree(tester);
    });
  });
}
