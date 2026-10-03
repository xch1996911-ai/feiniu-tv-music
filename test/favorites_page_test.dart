import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/pages/favorites_page.dart';
import 'package:feiniu_tv_music/ui/widgets/track_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 曲目构造糖（可指定服务端 `isFavorite`）。
Track favTrack(String guid, {required bool serverFavorite}) => Track(
      guid: guid,
      title: '曲目 $guid',
      durationMs: 180000,
      isFavorite: serverFavorite,
      album: AlbumRef(guid: 'album_$guid', name: '专辑 $guid'),
      artists: <ArtistRef>[ArtistRef(guid: 'ar_$guid', name: '歌手 $guid')],
      audioSpec: const AudioSpec(format: 'flac', sampleRate: 44100, bitDepth: 16),
    );

/// 收藏页（对应 V4 验收「二、收藏页」）。
///
/// 核心断言：**收藏页只包含用户明确收藏过的歌**，
/// 而不是「全曲库」「最近播放」或「服务端默认标记的」。
void main() {
  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late PlaybackRepository playback;
  late LibraryRepository library;
  late LocalLibraryRepository local;
  late FakeSecureStore store;

  var openPlayerCalls = 0;
  var openLibraryCalls = 0;

  setUp(() {
    music = FakeMusicRepository();
    engine = FakePlaybackEngine();
    playback = PlaybackRepository(music: music, handler: engine);
    library = LibraryRepository(music);
    store = FakeSecureStore();
    local = LocalLibraryRepository(store: store);
    openPlayerCalls = 0;
    openLibraryCalls = 0;
  });

  tearDown(() async {
    library.dispose();
    playback.dispose();
    local.dispose();
    await engine.close();
  });

  String? focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  FocusNode? nodeForLabel(WidgetTester tester, String label) {
    for (final Focus f in tester.widgetList<Focus>(find.byType(Focus))) {
      if (f.focusNode?.debugLabel == label) return f.focusNode;
    }
    return null;
  }

  Future<void> pumpFavorites(
    WidgetTester tester, {
    List<Track> catalogue = const <Track>[],
    bool seed = true,
  }) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    music.catalogue = catalogue;
    await tester.runAsync(() async {
      await library.loadFirst();
      if (seed) {
        // Shell 的 bootstrap 就是这么做的：首次把服务端 isFavorite 播种进来。
        await local.seedFavoritesIfNeeded(library.tracks);
      }
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
            body: FavoritesPage(
              onOpenPlayer: () => openPlayerCalls++,
              onOpenLibrary: () => openLibraryCalls++,
            ),
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

  group('空收藏', () {
    testWidgets('显示明确空态 + 「去音乐库」入口，而不是显示全曲库',
        (WidgetTester tester) async {
      await pumpFavorites(
        tester,
        catalogue: <Track>[
          favTrack('a', serverFavorite: false),
          favTrack('b', serverFavorite: false),
        ],
      );

      // 标题区
      expect(find.text('还没有收藏的歌曲'), findsOneWidget);
      // 空态说明（引导用户怎么收藏）
      expect(find.textContaining('把焦点移到歌曲行上'), findsOneWidget);
      // 明确的操作出口
      expect(find.text('去音乐库'), findsOneWidget);

      // 曲库里有 2 首，但收藏是空的 → 一行都不该出现
      expect(find.byType(TrackRow), findsNothing,
          reason: '收藏为空时绝不能退化成显示全曲库');
      // 播放 / 随机 也不该出现（没有东西可播）
      expect(find.text('随机'), findsNothing);

      await tearDownTree(tester);
    });

    testWidgets('「去音乐库」可聚焦并能触发回调', (WidgetTester tester) async {
      await pumpFavorites(tester);

      final FocusNode? n = nodeForLabel(tester, 'fav.去音乐库');
      expect(n, isNotNull, reason: '空态的出口必须在焦点树上');
      n!.requestFocus();
      await tester.pump();
      expect(focusedLabel(), 'fav.去音乐库');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(openLibraryCalls, 1);

      await tearDownTree(tester);
    });
  });

  group('只包含用户明确收藏的歌', () {
    testWidgets('服务端 isFavorite 播种进来的歌会显示（首次迁移）',
        (WidgetTester tester) async {
      await pumpFavorites(
        tester,
        catalogue: <Track>[
          favTrack('a', serverFavorite: false),
          favTrack('b', serverFavorite: true),
          favTrack('c', serverFavorite: true),
        ],
      );

      expect(find.text('共 2 首收藏的歌曲'), findsOneWidget);
      expect(find.byType(TrackRow), findsNWidgets(2));

      // 未收藏的 'a' 绝不能出现在收藏页
      expect(find.text('曲目 a'), findsNothing);
      expect(find.text('曲目 b'), findsOneWidget);
      expect(find.text('曲目 c'), findsOneWidget);

      expect(find.text('随机'), findsOneWidget, reason: '有收藏时提供播放/随机');

      await tearDownTree(tester);
    });

    testWidgets('没有播种过的歌**不会**因为服务端标记而进收藏页',
        (WidgetTester tester) async {
      // seed: false → 本机集合为空，即使服务端说 isFavorite 也不显示
      await pumpFavorites(
        tester,
        catalogue: <Track>[
          favTrack('b', serverFavorite: true),
          favTrack('c', serverFavorite: true),
        ],
        seed: false,
      );

      expect(
        find.byType(TrackRow),
        findsNothing,
        reason: '唯一数据源是本机收藏集合，不是服务端 Track.isFavorite',
      );
      expect(find.text('还没有收藏的歌曲'), findsOneWidget);

      await tearDownTree(tester);
    });

    testWidgets('在别处收藏一首歌 → 收藏页立即出现（无需重启）',
        (WidgetTester tester) async {
      await pumpFavorites(
        tester,
        catalogue: <Track>[
          favTrack('a', serverFavorite: false),
          favTrack('b', serverFavorite: false),
        ],
      );
      expect(find.byType(TrackRow), findsNothing);
      expect(find.text('还没有收藏的歌曲'), findsOneWidget);

      // 模拟「在音乐库列表里按下 ♡」
      await local.toggleFavorite('a');
      await tester.pump();

      expect(find.text('共 1 首收藏的歌曲'), findsOneWidget);
      expect(find.byType(TrackRow), findsOneWidget);
      expect(find.text('曲目 a'), findsOneWidget);

      await tearDownTree(tester);
    });

    testWidgets('取消收藏 → 立即从列表移除；全部取消 → 回到空态',
        (WidgetTester tester) async {
      await pumpFavorites(
        tester,
        catalogue: <Track>[
          favTrack('a', serverFavorite: true),
          favTrack('b', serverFavorite: true),
        ],
      );
      expect(find.byType(TrackRow), findsNWidgets(2));

      await local.toggleFavorite('a');
      await tester.pump();
      expect(find.byType(TrackRow), findsOneWidget);
      expect(find.text('曲目 a'), findsNothing, reason: '取消后必须立刻消失');

      await local.toggleFavorite('b');
      await tester.pump();
      expect(find.byType(TrackRow), findsNothing);
      expect(find.text('还没有收藏的歌曲'), findsOneWidget);
      expect(find.text('去音乐库'), findsOneWidget);
      // 取消收藏也要落盘，否则重启后会「复活」
      expect(store.prefs['favGuids'] ?? '', isNot(contains('b')));

      await tearDownTree(tester);
    });

    testWidgets('收藏是持久的：新实例 restore 后仍能读出同一份',
        (WidgetTester tester) async {
      await pumpFavorites(
        tester,
        catalogue: <Track>[favTrack('a', serverFavorite: false)],
      );
      await local.toggleFavorite('a');
      await tester.pump();

      // 用同一个存储造一个新实例，等价于「退出 App 重新打开」
      final LocalLibraryRepository reopened =
          LocalLibraryRepository(store: store);
      addTearDown(reopened.dispose);
      await reopened.restore();

      expect(reopened.isFavorite('a'), isTrue);
      expect(reopened.favoriteCount, 1);
      expect(
        reopened.favoriteTracks(<Track>[favTrack('a', serverFavorite: false)]),
        hasLength(1),
      );

      await tearDownTree(tester);
    });
  });

  group('焦点链', () {
    testWidgets('播放 →(→) 随机（两个入口都能走到）', (WidgetTester tester) async {
      await pumpFavorites(
        tester,
        catalogue: <Track>[favTrack('a', serverFavorite: true)],
      );

      final FocusNode? playNode = nodeForLabel(tester, 'fav.播放');
      expect(playNode, isNotNull);
      playNode!.requestFocus();
      await tester.pump();
      expect(focusedLabel(), 'fav.播放');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'fav.随机');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'fav.播放');

      // 队列必须从**收藏列表**建起（这里只断言入口被触发）
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(openPlayerCalls, 1);
      expect(playback.queue.length, 1, reason: '播放队列只能由收藏歌曲组成');
      expect(playback.current?.guid, 'a');

      await tearDownTree(tester);
    });
  });
}
