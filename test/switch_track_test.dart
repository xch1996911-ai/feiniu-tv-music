import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/playback/playback_control.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/pages/track_list_page.dart';
import 'package:feiniu_tv_music/ui/widgets/track_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 「切歌不换源」修复的回归测试。
///
/// ## 事故（本次代码审查确认的直接根因）
/// 引擎把「**开始播放**」当成「**整首播放完成**」来等待：
/// ```dart
/// await _player.play();   // just_audio：直到播完/暂停/停止才完成
/// ```
/// 于是 A 正在播放时点 B，B 的换源被排在 A 的 play() 后面 ——
/// 界面（仓储的 current）已经是 B，声音还是 A。
///
/// 测试分两层：
/// 1. **仓储层**：A 正在播放（其播放会话仍未结束）时选 B，
///    B 必须**立刻**成为引擎实际加载的媒体项；连续 A→B(慢)→C 时最终是 C；
/// 2. **页面层**：「最近添加」列表用**真实遥控器事件**（方向键 + OK）选中某一行，
///    断言交给全局播放层的是**这一行的 guid 与下标**，且只打开一次播放器。
///
/// ⚠️ 关于「引擎是否等待整首歌」这件事，本文件无法直接判别 ——
/// 因为假引擎替换掉了真实引擎。判别点在
/// `test/play_launcher_test.dart`（PlaybackLauncher 单元测试 + 源码守卫）。
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

  /// 排空串行加载链与异步链。
  Future<void> settle() async {
    await playback.pendingLoads;
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  // ── 仓储层 ────────────────────────────────────────────────

  group('仓储层：切歌不被「上一首的播放生命周期」占住', () {
    test('A 正在播放（会话未结束）时选 B → B 立刻成为引擎当前项', () async {
      playback.setQueue(<Track>[makeTrack('a')], startIndex: 0);
      await settle();
      expect(engine.playingId, 'a');
      expect(engine.playbackSessions, contains('a'),
          reason: '前提：A 的播放会话仍挂在引擎里（真实场景就是「歌还在放」）');

      playback.playQueue(
        <Track>[makeTrack('b')],
        source: QueueSource.local,
        startIndex: 0,
      );
      await settle();

      expect(engine.loads.last.item.id, 'b',
          reason: 'B 的换源不能被 A 的未完成播放会话挡住');
      expect(engine.playingId, 'b', reason: '真正在响的必须是 B');
      expect(playback.current?.guid, 'b',
          reason: '界面显示的歌与实际加载的歌必须一致');
      expect(playback.position, Duration.zero, reason: '新歌进度从 0 开始');
      expect(engine.playbackSessions, contains('a'),
          reason: '换源全程**没有**要求 A 的播放会话先结束 —— 这正是修复的核心语义');
    });

    test('A→B(慢 300ms)→C：最终生效的是 C，迟到的 B 不覆盖', () async {
      playback.setQueue(<Track>[makeTrack('a')], startIndex: 0);
      await settle();

      engine.loadDelays['b'] = const Duration(milliseconds: 300);

      playback.playQueue(<Track>[makeTrack('b')],
          source: QueueSource.local, startIndex: 0);
      // 不等 B 加载完，立刻改选 C（模拟快速连点）
      playback.playQueue(<Track>[makeTrack('c')],
          source: QueueSource.local, startIndex: 0);
      await settle();

      expect(engine.playingId, 'c', reason: '最后一次选择必须赢');
      expect(playback.current?.guid, 'c');
      expect(playback.state.currentIndex, 0);
    });

    test('播放期间异常（网络中断）→ 上报到界面，不静默', () async {
      playback.setQueue(<Track>[makeTrack('a')], startIndex: 0);
      await settle();

      // 真实链路：不被 await 的 play() Future 失败 → PlaybackLauncher 错误通道
      //          → PlaybackCommandListener.onPlaybackError → 仓储置错误态。
      engine.simulatePlaybackError(StateError('网络中断'));

      expect(playback.state.error, isNotNull,
          reason: '「没有声音也没有提示」是最糟的状态，错误必须可见');
      expect(playback.state.error, contains('播放中断'));
    });

    test('换源失败 → 压掉旧音源并报错（不得静默继续放旧歌）', () async {
      playback.setQueue(<Track>[makeTrack('a')], startIndex: 0);
      await settle();
      final int pauseBefore = engine.pauseCalls;

      engine.failLoad = true;
      playback.playQueue(<Track>[makeTrack('x')],
          source: QueueSource.local, startIndex: 0);
      await settle();

      expect(engine.pauseCalls, greaterThan(pauseBefore),
          reason: '交付不出去时必须停下旧音源，否则「界面新歌、耳朵旧歌」');
      expect(engine.playing, isFalse);
    });
  });

  // ── 页面层：「最近添加」+ 遥控器 OK ────────────────────────

  group('「最近添加」点击 → 全局播放状态（遥控器 OK 端到端）', () {
    /// 带入库时间的曲目（`recentlyAdded` 按 `createdAt` 倒序）。
    Track added(String guid, int secondsAgo) => Track(
          guid: guid,
          title: '曲目 $guid',
          durationMs: 180000,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            DateTime(2026, 1, 10).millisecondsSinceEpoch - secondsAgo * 1000,
            isUtc: true,
          ),
          album: AlbumRef(guid: 'album_$guid', name: '专辑 $guid'),
          artists: <ArtistRef>[ArtistRef(guid: 'ar_$guid', name: '歌手 $guid')],
          audioSpec:
              const AudioSpec(format: 'flac', sampleRate: 44100, bitDepth: 16),
        );

    FocusNode? nodeForLabel(WidgetTester tester, String label) {
      for (final Focus f in tester.widgetList<Focus>(find.byType(Focus))) {
        if (f.focusNode?.debugLabel == label) return f.focusNode;
      }
      return null;
    }

    Future<void> pumpRecentAdded(
      WidgetTester tester, {
      required List<Track> catalogue,
      required void Function() onOpenPlayer,
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
              body: TrackListPage(
                key: const ValueKey<TrackListSource>(TrackListSource.recentlyAdded),
                source: TrackListSource.recentlyAdded,
                title: '最近添加',
                emptyIcon: Icons.fiber_new,
                emptyText: '暂无最近添加',
                onOpenPlayer: onOpenPlayer,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> tearDownTree(WidgetTester tester) async {
      // 先把 TvFocus 的按下态复位定时器等假时钟定时器走完，再拆树。
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    /// widget 测试里的「排空加载链」。
    ///
    /// ⚠️ **绝不能在 `testWidgets` 里 `await Future.delayed`**（假时钟不推进 → 挂满超时）。
    /// 两种 zone 都要放行一次，缺一不可：
    ///   · `pump()`：排空**假时钟 zone** 的微任务（键事件处理挂在假 zone 上）；
    ///   · `runAsync`：放行一次**真实事件循环** —— `_loadChain` 的初值在构造期
    ///     （`setUp`，root zone）创建，`.then` 回调排在 root zone 队列。
    Future<void> settleWidget(WidgetTester tester) async {
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
    }

    testWidgets('按入库时间倒序展示（最新的在最上面）',,
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpRecentAdded(
        tester,
        catalogue: <Track>[
          added('old', 900),
          added('newest', 10),
          added('mid', 300),
        ],
        onOpenPlayer: () {},
      );

      final List<TrackRow> rows =
          tester.widgetList<TrackRow>(find.byType(TrackRow)).toList();
      expect(rows.length, 3);
      expect(rows[0].track.guid, 'newest');
      expect(rows[1].track.guid, 'mid');
      expect(rows[2].track.guid, 'old');

      await tearDownTree(tester);
    });

    testWidgets('方向键选中第二行 + OK → 交给全局播放层的 guid/下标正确，且只开一次播放器',,
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      var openCalls = 0;
      await pumpRecentAdded(
        tester,
        catalogue: <Track>[added('newest', 10), added('mid', 300)],
        onOpenPlayer: () => openCalls++,
      );

      // 遥控器：焦点移到第二行（mid），按 OK。
      FocusNode? row = nodeForLabel(tester, 'track.mid');
      expect(row, isNotNull, reason: '每一行都必须是可聚焦节点');
      row!.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'track.mid');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await settleWidget(tester);

      // ① 全局播放层的当前曲目 = 被点的那一首
      expect(playback.current?.guid, 'mid');
      expect(playback.state.currentIndex, 1,
          reason: 'startIndex 必须是被点行在该列表中的下标');
      // ② 引擎真正加载的媒体项 = 同一首（不是「界面换了、声音没换」）
      expect(engine.loads.last.item.id, 'mid');
      expect(engine.loads.last.url, contains('guid=mid'));
      expect(engine.playing, isTrue);
      // ③ 页面跳转只发生一次
      expect(openCalls, 1);

      await tearDownTree(tester);
    });

    testWidgets('先播 A，再回「最近添加」点 B：显示与音频都必须换成 B',,
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      var openCalls = 0;
      await pumpRecentAdded(
        tester,
        catalogue: <Track>[added('newest', 10), added('mid', 300)],
        onOpenPlayer: () => openCalls++,
      );

      // 先播「newest」（第一行）
      FocusNode? first = nodeForLabel(tester, 'track.newest');
      first!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await settleWidget(tester);
      expect(engine.playingId, 'newest');

      // 再点「mid」（第二行）
      FocusNode? second = nodeForLabel(tester, 'track.mid');
      second!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await settleWidget(tester);

      expect(playback.current?.guid, 'mid');
      expect(engine.playingId, 'mid',
          reason: '耳朵里必须是 mid —— 这就是本次事故要修的那一条');
      expect(playback.position, Duration.zero);
      expect(openCalls, 2);

      await tearDownTree(tester);
    });
  });
}
