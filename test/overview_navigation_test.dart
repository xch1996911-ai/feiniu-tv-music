import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/pages/overview_page.dart';
import 'package:feiniu_tv_music/ui/pages/song_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 导航页串内容的回归（实机现象：先进「风格」再点「歌手/专辑」，
/// 页面仍显示风格筛选出的内容；重新进「音乐库」才恢复）。
///
/// ## 根因（代码证据，非推测）
///
/// 1. `app_shell.dart` 的 `_buildStage()` 在**同一个槽位**
///    （`Expanded(child: _buildStage())`）里按 `_stage` 返回页面，
///    而「歌手 / 专辑 / 风格」三页是**同一个 Widget 类型** `OverviewPage`
///    —— 不带 key 时 Flutter 复用同一个 `_OverviewPageState`；
/// 2. `OverviewPage._compute()` 用 `identical(曲库实例)` 做缓存键，
///    而 `library.tracks` 对三个分类是**同一份**只读索引
///    ⇒ 风格页算出的分组被歌手/专辑页原样命中；
/// 3. 重新进「音乐库」会换成 `SongListPage`（**不同类型**）→
///    `OverviewPage` 的 State 被销毁，回来时重建（缓存为空）→ 恢复。
///    这正是用户看到的「打开音乐库就正常」。
///
/// ## 修法（本测试同时是回归断言）
///
/// - 外壳给每个分类不同的 `ValueKey` ⇒ 每个分类自己的 State，互不串；
/// - `OverviewPage.didUpdateWidget` 在 `kind` 变化时整体重置派生结果
///   （防御性兜底：组件是公开的，别的调用方仍可能同槽位换 kind）。
///
/// ⚠️ 概览页是**纯本地推导**（不发起任何网络请求），
///    因此「异步请求晚返回覆盖别的页」这条通路在本组件里不存在；
///    曲库同步发生在 `LibraryRepository` 内部，更新同一份只读索引，
///    页面在下一帧自动重算 —— 对应的断言在「后台刷新期间快速切页」用例里。
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

  /// 造一首歌（局部函数必须**先声明后使用** —— Dart 对局部函数
  /// 不做提升，先在 `catalogue()` 里引用再声明会直接编译错）。
  Track makeTrack(
    String guid,
    String title,
    String artist,
    String artistGuid,
    String album,
    String albumGuid,
    String genre,
  ) =>
      Track(
        guid: guid,
        title: title,
        durationMs: 180000,
        album: AlbumRef(guid: albumGuid, name: album),
        artists: <ArtistRef>[ArtistRef(guid: artistGuid, name: artist)],
        genres: <String>[genre],
        audioSpec: const AudioSpec(
          format: 'flac',
          sampleRate: 44100,
          bitDepth: 16,
        ),
      );

  /// 3 位歌手 / 4 张专辑 / 4 种风格 / 7 首歌（满足 ≥3 / ≥4 / ≥3 的验收下限）。
  List<Track> catalogue() => <Track>[
        makeTrack('a1', '歌一', '歌手A', 'arA', '专辑一', 'al1', '流行'),
        makeTrack('a2', '歌二', '歌手A', 'arA', '专辑一', 'al1', '流行'),
        makeTrack('a3', '歌三', '歌手A', 'arA', '专辑二', 'al2', '摇滚'),
        makeTrack('b1', '歌四', '歌手B', 'arB', '专辑三', 'al3', '摇滚'),
        makeTrack('b2', '歌五', '歌手B', 'arB', '专辑三', 'al3', '电子'),
        makeTrack('c1', '歌六', '歌手C', 'arC', '专辑四', 'al4', '电子'),
        makeTrack('c2', '歌七', '歌手C', 'arC', '专辑四', 'al4', '爵士'),
      ];

  group('导航页内容与分类数据源', () {
    testWidgets('冷启动直接进歌手 → 完整歌手分组（3 位）',
        (WidgetTester tester) async {
      music.catalogue = catalogue();
      await _pump(tester, music: music, engine: engine, playback: playback,
          library: library, local: local, stage: ShellStage.artists);

      expect(find.text('歌手'), findsOneWidget, reason: '页面标题必须一致');
      expect(find.text('歌手A'), findsOneWidget);
      expect(find.text('歌手B'), findsOneWidget);
      expect(find.text('歌手C'), findsOneWidget);
      // 不能出现别的分类的内容
      expect(find.text('专辑一'), findsNothing,
          reason: '歌手页不该显示专辑分组');
      expect(find.text('流行'), findsNothing, reason: '歌手页不该显示风格分组');
    });

    testWidgets('风格 → 歌手：不串内容（实机回归用例）',
        (WidgetTester tester) async {
      music.catalogue = catalogue();
      final _HostHandle handle = await _pump(
        tester,
        music: music,
        engine: engine,
        playback: playback,
        library: library,
        local: local,
        stage: ShellStage.genres,
      );

      expect(find.text('风格'), findsOneWidget);
      expect(find.text('流行'), findsOneWidget);
      expect(find.text('摇滚'), findsOneWidget);
      expect(find.text('电子'), findsOneWidget);
      expect(find.text('爵士'), findsOneWidget);

      // 切到歌手（同一个槽位）
      handle.go(ShellStage.artists);
      await tester.pump();
      await tester.pump();

      expect(find.text('歌手'), findsOneWidget, reason: '标题必须跟着导航变');
      expect(find.text('歌手A'), findsOneWidget, reason: '必须显示完整歌手分组');
      expect(find.text('歌手B'), findsOneWidget);
      expect(find.text('歌手C'), findsOneWidget);
      expect(find.text('流行'), findsNothing,
          reason: '风格分组不得残留在歌手页 —— 这就是实机报的串内容');
      expect(find.text('摇滚'), findsNothing);
    });

    testWidgets('风格 → 专辑：完整专辑分组（4 张）',
        (WidgetTester tester) async {
      music.catalogue = catalogue();
      final _HostHandle handle = await _pump(
        tester,
        music: music,
        engine: engine,
        playback: playback,
        library: library,
        local: local,
        stage: ShellStage.genres,
      );

      handle.go(ShellStage.albums);
      await tester.pump();
      await tester.pump();

      expect(find.text('专辑'), findsOneWidget);
      expect(find.text('专辑一'), findsOneWidget);
      expect(find.text('专辑二'), findsOneWidget);
      expect(find.text('专辑三'), findsOneWidget);
      expect(find.text('专辑四'), findsOneWidget);
      expect(find.text('流行'), findsNothing, reason: '不得残留风格分组');
    });

    testWidgets('风格详情 → 歌手：详情关闭 + 完整歌手分组',
        (WidgetTester tester) async {
      music.catalogue = catalogue();
      final _HostHandle handle = await _pump(
        tester,
        music: music,
        engine: engine,
        playback: playback,
        library: library,
        local: local,
        stage: ShellStage.genres,
      );

      // 进入某个风格详情（与外壳一致：外壳持有 detail 并传给页面）
      handle.openDetail();
      await tester.pump();
      expect(handle.hasDetail, isTrue, reason: '应能进入风格详情');

      // 切走：外壳的 `_goStage` 会把 detail 置空
      handle.go(ShellStage.artists);
      await tester.pump();
      await tester.pump();

      expect(handle.hasDetail, isFalse, reason: '换页必须离开原详情路由');
      expect(find.text('歌手A'), findsOneWidget, reason: '歌手页必须显示完整歌手分组');
      expect(find.text('摇滚'), findsNothing,
          reason: '风格详情的歌曲列表不得串到歌手页');
    });

    testWidgets('歌手 → 风格 → 专辑 → 音乐库 → 歌手：每页都是自己的数据',
        (WidgetTester tester) async {
      music.catalogue = catalogue();
      final _HostHandle handle = await _pump(
        tester,
        music: music,
        engine: engine,
        playback: playback,
        library: library,
        local: local,
        stage: ShellStage.artists,
      );

      Future<void> go(ShellStage s) async {
        handle.go(s);
        await tester.pump();
        await tester.pump();
      }

      await go(ShellStage.genres);
      expect(find.text('流行'), findsOneWidget);
      await go(ShellStage.albums);
      expect(find.text('专辑三'), findsOneWidget);
      await go(ShellStage.library); // 音乐库（SongListPage，不同类型）
      expect(find.text('音乐库'), findsOneWidget);
      await go(ShellStage.artists);
      expect(find.text('歌手A'), findsOneWidget,
          reason: '绕一圈回来仍必须是完整歌手分组');
      expect(find.text('流行'), findsNothing);
    });

    testWidgets('打开/筛选风格页前后：曲库 IDs、歌手数、专辑数、播放队列都不变',
        (WidgetTester tester) async {
      music.catalogue = catalogue();
      final _HostHandle handle = await _pump(
        tester,
        music: music,
        engine: engine,
        playback: playback,
        library: library,
        local: local,
        stage: ShellStage.artists,
      );

      // 先播放 3 首（模拟用户正在听的队列）
      await tester.runAsync(() async {
        playback.setQueue(catalogue().take(3).toList(), startIndex: 0);
        await playback.pendingLoads;
      });
      final List<String> queueBefore = playback.queue
          .map((Track t) => t.guid)
          .toList(growable: false);

      final List<String> idsBefore = library.tracks
          .map((Track t) => t.guid)
          .toList(growable: false);
      final int artistCountBefore =
          LocalLibraryRepository.artistOverviews(library.tracks).length;
      final int albumCountBefore =
          LocalLibraryRepository.albumOverviews(library.tracks).length;

      // 打开风格页（以及它的详情路由）
      handle.go(ShellStage.genres);
      await tester.pump();
      await tester.pump();
      handle.openDetail();
      await tester.pump();

      expect(library.tracks.map((Track t) => t.guid).toList(growable: false),
          idsBefore, reason: '浏览/筛选风格不得改动完整曲库');
      expect(LocalLibraryRepository.artistOverviews(library.tracks).length,
          artistCountBefore, reason: '歌手分组不得受风格筛选影响');
      expect(LocalLibraryRepository.albumOverviews(library.tracks).length,
          albumCountBefore, reason: '专辑分组不得受风格筛选影响');
      expect(playback.queue.map((Track t) => t.guid).toList(growable: false),
          queueBefore, reason: '导航筛选不得改动播放队列');
      expect(playback.current?.guid, 'a1', reason: '当前播放不得被打断');
    });

    testWidgets('大于 50 首的分页曲库：分类统计与完整索引一致，切页不串',
        (WidgetTester tester) async {
      // 60 首：3 位歌手 × 20 首，4 张专辑轮转，4 种风格轮转
      music.catalogue = <Track>[
        for (int i = 0; i < 60; i++)
          makeTrack(
            'g$i',
            '曲$i',
            '歌手${i % 3}',
            'ar${i % 3}',
            '专辑${i % 4}',
            'al${i % 4}',
            <String>['流行', '摇滚', '电子', '爵士'][i % 4],
          ),
      ];

      await tester.runAsync(() async {
        await library.loadFirst();          // 首屏 50 首
        await library.startSync('test@host#user'); // 全量索引（后台整理的等价路径）
      });
      expect(library.tracks.length, 60, reason: '全量索引必须完整');

      final _HostHandle handle = await _pump(
        tester,
        music: music,
        engine: engine,
        playback: playback,
        library: library,
        local: local,
        stage: ShellStage.artists,
      );
      expect(find.text('歌手0'), findsOneWidget);
      expect(find.text('歌手2'), findsOneWidget);

      handle.go(ShellStage.albums);
      await tester.pump();
      expect(find.text('专辑0'), findsOneWidget);
      expect(find.text('专辑3'), findsOneWidget);
      expect(find.text('歌手0'), findsNothing, reason: '切页不得残留上一个分类');

      handle.go(ShellStage.genres);
      await tester.pump();
      expect(find.text('流行'), findsOneWidget);
      expect(find.text('爵士'), findsOneWidget);
      expect(find.text('专辑0'), findsNothing);
    });
  });
}

// ───────────────────────── 测试装置 ─────────────────────────

/// 侧栏的四个 stage（与 `app_shell` 的导航项一致），测试只用到其中几个。
enum ShellStage { artists, albums, genres, library }

/// 复刻 `app_shell._buildStage()` 的**单槽位**结构：
/// `_stage` 变化时在同一个 `Expanded` 槽位里换页面。
///
/// - [useKeys] = true 时带 `ValueKey`（本轮修复后的外壳行为）；
///   false 时与修复前的外壳一致 —— 用于验证「不带 key 必然串内容」。
class _Host extends StatefulWidget {
  const _Host({required this.useKeys, required this.onReady});

  final bool useKeys;
  final ValueChanged<_HostHandle> onReady;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  ShellStage _stage = ShellStage.artists;
  LibraryOverview? _openOverview;

  void go(ShellStage s) {
    if (_stage == s) return;
    setState(() {
      _stage = s;
      _openOverview = null; // 与外壳 `_goStage` 一致：换页离开详情
    });
  }

  void openDetail() {
    final List<LibraryOverview> items = _currentItems();
    if (items.isEmpty) return;
    setState(() => _openOverview = items.first);
  }

  bool get hasDetail => _openOverview != null;

  /// 从当前分类取一个「详情」对象（仅用于测试进入详情路由）。
  List<LibraryOverview> _currentItems() {
    final LibraryRepository library = context.read<LibraryRepository>();
    final LocalLibraryRepository local = context.read<LocalLibraryRepository>();
    return switch (_stage) {
      ShellStage.artists =>
        LocalLibraryRepository.artistOverviews(library.tracks),
      ShellStage.albums => LocalLibraryRepository.albumOverviews(library.tracks),
      ShellStage.genres =>
        local.genreOverviewsOf(library.tracks, inference: library.genreInference),
      ShellStage.library => const <LibraryOverview>[],
    };
  }

  @override
  Widget build(BuildContext context) {
    final Widget page = switch (_stage) {
      ShellStage.artists => OverviewPage(
          key: widget.useKeys
              ? const ValueKey<OverviewKind>(OverviewKind.artist)
              : null,
          kind: OverviewKind.artist,
          title: '歌手',
          emptyHint: '暂无歌手',
          detail: _openOverview,
          onOpenDetail: (LibraryOverview o) =>
              setState(() => _openOverview = o),
          onCloseDetail: () => setState(() => _openOverview = null),
          onOpenPlayer: () {},
        ),
      ShellStage.albums => OverviewPage(
          key: widget.useKeys
              ? const ValueKey<OverviewKind>(OverviewKind.album)
              : null,
          kind: OverviewKind.album,
          title: '专辑',
          emptyHint: '暂无专辑',
          detail: _openOverview,
          onOpenDetail: (LibraryOverview o) =>
              setState(() => _openOverview = o),
          onCloseDetail: () => setState(() => _openOverview = null),
          onOpenPlayer: () {},
        ),
      ShellStage.genres => OverviewPage(
          key: widget.useKeys
              ? const ValueKey<OverviewKind>(OverviewKind.genre)
              : null,
          kind: OverviewKind.genre,
          title: '风格',
          emptyHint: '暂无歌曲',
          detail: _openOverview,
          onOpenDetail: (LibraryOverview o) =>
              setState(() => _openOverview = o),
          onCloseDetail: () => setState(() => _openOverview = null),
          onOpenPlayer: () {},
        ),
      ShellStage.library => SongListPage(onOpenPlayer: () {}),
    };

    return Scaffold(
      body: Row(
        children: <Widget>[
          // 侧栏占位（概览页布局不依赖它的内容，只依赖宽度）
          const SizedBox(width: 206),
          Expanded(child: page),
        ],
      ),
    );
  }
}

/// 句柄：让测试像外壳一样驱动宿主。
class _HostHandle {
  _HostHandle(this._state);

  final _HostState _state;

  void go(ShellStage s) => _state.go(s);
  void openDetail() => _state.openDetail();
  bool get hasDetail => _state.hasDetail;
}

Future<_HostHandle> _pump(
  WidgetTester tester, {
  required FakeMusicRepository music,
  required FakePlaybackEngine engine,
  required PlaybackRepository playback,
  required LibraryRepository library,
  required LocalLibraryRepository local,
  required ShellStage stage,
  bool useKeys = true,
}) async {
  // ⚠️ `catalogue` 是 `main()` 里的**局部函数**，顶层函数看不到它 ——
  //    每个用例在调用 `_pump` 之前已经自己设好 `music.catalogue`，
  //    这里不能再赋值（曾写成 `music.catalogue = catalogue()`，直接编译错）。
  await tester.runAsync(() async {
    await library.loadFirst();
  });

  final _Host host = _Host(useKeys: useKeys, onReady: (_) {});
  await tester.pumpWidget(
    MultiProvider(
      providers: <SingleChildWidget>[
        ChangeNotifierProvider<LibraryRepository>.value(value: library),
        ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
        ChangeNotifierProvider<LocalLibraryRepository>.value(value: local),
        ChangeNotifierProvider<MusicRepository>.value(value: music),
      ],
      child: MaterialApp(theme: buildTvTheme(), home: host),
    ),
  );
  await tester.pump();
  await tester.pump();

  // 把初始 stage 切到位
  final _HostState state = tester.state<_HostState>(find.byType(_Host));
  if (state._stage != stage) state.go(stage);
  await tester.pump();
  await tester.pump();
  return _HostHandle(state);
}
