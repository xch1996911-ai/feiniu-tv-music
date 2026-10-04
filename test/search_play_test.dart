import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/playback/playback_control.dart';
import 'package:feiniu_tv_music/repositories/auth_repository.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/pages/search_page.dart';
import 'package:feiniu_tv_music/ui/widgets/track_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 「从搜索结果点一首歌 → 真的开始播放这首歌」的端到端回归。
///
/// ## 为什么必须断言到引擎层
/// 断言「进没进播放页」「有没有调回调」都抓不到真实故障：用户实测的现场是
/// **播放页已经换成 B，耳朵里还是 A**。因此这里的判据一律落在
/// `FakePlaybackEngine`（真实 `PlaybackEngine` 接口的替身）上：
/// - 最后一次 `loadAndPlay` 的**媒体项 id**（= 被点那首的 guid）
/// - `loadAndPlay` 的** URL**（= `buildStreamUrl(该 guid)`）
/// - `playing == true`（确实在放）
/// - 失败/无法交付时 `playing == false`（旧音源必须被压掉，不得继续出声）
///
/// ## 顺带钉住的三条产品要求
/// 1. 只触发一次明确的播放操作（搜索结果建独立队列，不另建播放器状态）；
/// 2. 快速连点「后点的那首」赢（串行链 + generation 令牌）；
/// 3. 任何「新请求交付不出去」的路径都**不能静默保留旧音源**。
void main() {
  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late LibraryRepository library;
  late PlaybackRepository playback;

  setUp(() {
    music = FakeMusicRepository();
    engine = FakePlaybackEngine();
    library = LibraryRepository(music);
    playback = PlaybackRepository(music: music, handler: engine);
  });

  tearDown(() async {
    library.dispose();
    playback.dispose();
    await engine.close();
  });

  /// 搜索结果的 Track 列表（就是搜索索引里的真实 Track 对象）。
  List<Track> searchResultOf(List<String> guids) =>
      <Track>[for (final String g in guids) makeTrack(g)];

  group('搜索结果 → 全局播放控制器（仓储层）', () {
    test('A 点搜索结果：引擎加载的就是被点那首，并立即开始播放', () async {
      playback.playQueue(
        searchResultOf(<String>['s1', 's2', 's3']),
        source: QueueSource.search,
        startIndex: 1,
      );
      await playback.pendingLoads;

      expect(playback.current?.guid, 's2', reason: '当前曲目必须是被点那首');
      expect(playback.source, QueueSource.search);
      expect(playback.queue.map((Track t) => t.guid).toList(),
          <String>['s1', 's2', 's3'],
          reason: '队列 = 搜索结果本身，不另建一套');
      expect(engine.loads, isNotEmpty, reason: '必须真的下发过一次加载');
      expect(engine.loads.last.item.id, 's2',
          reason: '最后一次加载的媒体项必须是被点那首（而不是上一首）');
      expect(engine.loads.last.url, music.buildStreamUrl('s2'),
          reason: '音频源 URL 必须由被点那首的 guid 生成');
      expect(engine.playing, isTrue, reason: '必须自动开始播放');
      expect(engine.position, Duration.zero, reason: '进度必须从新歌 0 开始');
    });

    test('B 正在播 A 时点搜索结果里的 B：切到 B，A 不再出声', () async {
      playback.setQueue(searchResultOf(<String>['a1', 'a2']), startIndex: 0);
      await playback.pendingLoads;
      expect(engine.currentItem?.id, 'a1');
      expect(engine.playing, isTrue);

      playback.playQueue(
        searchResultOf(<String>['b1', 'b2']),
        source: QueueSource.search,
        startIndex: 1,
      );
      await playback.pendingLoads;

      expect(playback.current?.guid, 'b2');
      expect(engine.loads.last.item.id, 'b2');
      expect(engine.currentItem?.id, 'b2',
          reason: '引擎里当前媒体项必须已经换成 B（不是 A）');
      expect(engine.playing, isTrue, reason: 'B 必须自动开播');
      expect(engine.position, Duration.zero);
      // A 已不在队列里 → 上一首/下一首只会走 B 所在的搜索队列
      expect(playback.playHistory, isNot(contains('a1')),
          reason: '新队列必须清掉上一条队列的历史');
    });

    test('C 快速连点 B（慢）再点 C（快）：最终播放最后点的 C', () async {
      engine.loadDelays['b1'] = const Duration(milliseconds: 60);
      playback.playQueue(searchResultOf(<String>['b1']),
          source: QueueSource.search, startIndex: 0);
      playback.playQueue(searchResultOf(<String>['c1']),
          source: QueueSource.search, startIndex: 0);
      await playback.pendingLoads;

      expect(playback.current?.guid, 'c1', reason: '最后点的那首必须赢');
      expect(engine.currentItem?.id, 'c1');
      expect(engine.playing, isTrue);
      expect(engine.loads.map((RecordedLoad l) => l.item.id), isNot(contains('b1')),
          reason: '过期请求不得下发（否则会先响 B 再响 C）');
    });

    test('D 加载失败：旧音源必须被压掉，并给出明确错误（不得静默放旧歌）',
        () async {
      playback.setQueue(searchResultOf(<String>['a1']), startIndex: 0);
      await playback.pendingLoads;
      expect(engine.playing, isTrue);

      engine.failLoad = true;
      playback.playQueue(searchResultOf(<String>['b1']),
          source: QueueSource.search, startIndex: 0);
      await playback.pendingLoads;

      expect(engine.pauseCalls, greaterThanOrEqualTo(1),
          reason: '新歌加载失败时必须压掉旧音源，否则用户听到的还是上一首');
      expect(engine.playing, isFalse, reason: '失败后不得继续出声');
      expect(playback.state.error, isNotNull, reason: '必须给出明确错误提示');
    });

    test('E 点到的条目缺少有效标识：明确报错并压掉旧音源，绝不静默继续放旧歌',
        () async {
      playback.setQueue(searchResultOf(<String>['a1']), startIndex: 0);
      await playback.pendingLoads;
      expect(engine.playing, isTrue);

      // 第二个条目 guid 为空（无法建立身份，仓库层会丢弃它）
      final List<Track> mixed = <Track>[
        makeTrack('a1'),
        makeTrack('', title: '无标识条目'),
      ];
      playback.playQueue(mixed, source: QueueSource.search, startIndex: 1);
      await playback.pendingLoads;

      expect(engine.pauseCalls, greaterThanOrEqualTo(1),
          reason: '交付不出去时必须压掉旧音源');
      expect(engine.playing, isFalse);
      expect(playback.state.error, contains('无法播放'));
    });

    test('G 会话失效（buildStreamUrl 抛 StateError）：不得静默，报错并压掉旧音源',
        () async {
      // ⚠️ 这条是「点了搜索结果的歌，播放页出来了却还在放原来那首」的
      //    **根因场景**：真实 `MusicRepository.buildStreamUrl` 在
      //    `_auth.provider == null`（未登录 / 会话失效）时抛 StateError，
      //    而老实现让它穿出 `playQueue` —— 调用方是即发即忘的，
      //    异常被丢弃，于是页面照跳、歌不换、旧音源继续响。
      playback.setQueue(searchResultOf(<String>['a1']), startIndex: 0);
      await playback.pendingLoads;
      expect(engine.playing, isTrue, reason: '前提：A 正在播');

      music.failStreamUrl = true;
      playback.playQueue(searchResultOf(<String>['b1', 'b2']),
          source: QueueSource.search, startIndex: 1);
      // 必须**不抛**（内部兜住），否则测试会以未处理异常失败
      await playback.pendingLoads;

      expect(engine.pauseCalls, greaterThanOrEqualTo(1),
          reason: '会话失效时必须压掉旧音源，不能让 A 继续响');
      expect(engine.playing, isFalse);
      expect(playback.state.error, isNotNull,
          reason: '必须给出明确错误，而不是静默什么都不做');
    });
  });

  group('搜索结果 → 播放器页面（widget 级）', () {
    testWidgets('F 搜索页 OK 点结果：全局状态/音频源/播放页显示同一首',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      music.catalogue = <Track>[
        makeTrack('g1', title: '晴天'),
        makeTrack('g2', title: '稻香'),
        makeTrack('g3', title: '七里香'),
      ];
      await tester.runAsync(() async {
        await library.loadFirst();
      });

      int opened = 0;
      final LocalLibraryRepository local =
          LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: <SingleChildWidget>[
            ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
            ChangeNotifierProvider<LibraryRepository>.value(value: library),
            ChangeNotifierProvider<LocalLibraryRepository>.value(value: local),
            ChangeNotifierProvider<AuthRepository>.value(
              value: AuthRepository(store: FakeSecureStore()),
            ),
            ChangeNotifierProvider<MusicRepository>.value(value: music),
          ],
          child: MaterialApp(
            theme: buildTvTheme(),
            home: Scaffold(
              body: SearchPage(
                onBack: () {},
                onOpenPlayer: () => opened++,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 输入查询 → 防抖 220ms → 出结果
      await tester.enterText(find.byType(TextField), '稻香');
      await tester.pump(const Duration(milliseconds: 300));
      // 搜索本身是异步的（内部有一拍 await）→ 多泵几帧直到结果渲染出来
      for (int i = 0; i < 6; i++) {
        await tester.pump();
      }

      expect(find.byType(TrackRow), findsWidgets,
          reason: '搜索结果必须渲染出行（否则后面按 OK 无从触发）');
      expect(find.text('稻香'), findsWidgets, reason: '搜索结果里应出现这首歌');

      // 遥控器：输入框 ↓ 进结果列表，OK 播放（真实按键事件，不直接调回调）
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      final String? focused = FocusManager.instance.primaryFocus?.debugLabel;
      expect(focused, isNotNull);
      expect(focused!.startsWith('track.'), isTrue,
          reason: '输入框按 ↓ 必须进入搜索结果行，实际焦点：$focused');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      // ⚠️ 两种 zone 都要放行一次，缺一不可：
      //   · `pump()`：排空**假时钟 zone** 的微任务（键事件处理挂在假 zone 上）；
      //   · `runAsync`：排空**真实 zone** 的微任务 —— `_loadChain` 的初值是在
      //     构造期（setUp，root zone）创建的，`.then` 回调排在 root zone 队列，
      //     `pump()` 永远清不到它（这就是「setQueue 后引擎收不到加载请求」的坑）。
      //   反过来，只 `await pendingLoads` 放进 runAsync 也会卡死：链上还有
      //   假 zone 的任务要排空 —— CI 上第一次就是这么 45 秒超时的。
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();

      expect(playback.current?.guid, 'g2',
          reason: '全局播放状态必须切到被点那首');
      expect(engine.loads, isNotEmpty, reason: '必须真的下发加载');
      expect(engine.loads.last.item.id, 'g2');
      expect(engine.loads.last.url, music.buildStreamUrl('g2'));
      expect(engine.playing, isTrue, reason: '必须自动开始播放');
      expect(opened, 1, reason: '只打开一次播放页（点击只触发一次播放操作）');

      // 收尾：把 TvFocus 的按下态复位定时器等假时钟定时器走完，再拆树。
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}
