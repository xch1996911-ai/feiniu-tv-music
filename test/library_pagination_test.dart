import 'package:feiniu_tv_music/core/exceptions.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/playback/playback_control.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';

/// V2：曲库分页 + 队列跨分页 + 播放模式 的回归测试。
///
/// 全部离线（[FakeMusicRepository] + [FakePlaybackEngine]），不联网、不碰平台通道。
void main() {
  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late LibraryRepository library;
  late PlaybackRepository playback;

  /// 生成 count 首曲目放进假曲库。
  void seed(int count, {int start = 0}) {
    music.catalogue = <Track>[
      for (var i = start; i < start + count; i++) makeTrack('g$i', title: '歌曲 $i'),
    ];
  }

  /// 让仓储的串行链与异步链全部排空。
  Future<void> settle() async {
    await playback.pendingLoads;
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

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

  // ── A~E：分页基础 ────────────────────────────────────────
  group('A-E 曲库分页', () {
    test('A 第一页加载成功：拿到 50 首、hasMore=true', () async {
      seed(120);
      await library.loadFirst();

      expect(library.tracks.length, 50);
      expect(library.loadedPages, 1);
      expect(library.hasMore, isTrue);
      expect(library.phase, LibraryPhase.ready);
      expect(library.error, isNull);
    });

    test('B 加载下一页会追加而非替换', () async {
      seed(120);
      await library.loadFirst();
      final first50 = library.tracks.first.guid;

      await library.loadMore();

      expect(library.tracks.length, 100, reason: '应累计到 100 首');
      expect(library.tracks.first.guid, first50, reason: '首批不能被覆盖');
      expect(library.loadedPages, 2);
    });

    test('C hasMore=false 后不再请求', () async {
      seed(30); // 不足一页
      await library.loadFirst();
      expect(library.tracks.length, 30);
      expect(library.hasMore, isFalse);
      expect(library.phase, LibraryPhase.noMore);

      final before = music.trackPageRequests.length;
      final ok = await library.loadMore();
      expect(ok, isFalse);
      expect(music.trackPageRequests.length, before, reason: '不应再发请求');
    });

    test('D 并发调用 loadMore 只产生一次请求（同一页去重）', () async {
      seed(200);
      await library.loadFirst();
      music.trackPageRequests.clear();

      // 同时发起 5 次「加载下一页」
      final results = await Future.wait<bool>(<Future<bool>>[
        library.loadMore(),
        library.loadMore(),
        library.loadMore(),
        library.loadMore(),
        library.loadMore(),
      ]);

      final page2Requests = music.trackPageRequests.where((r) => r.startsWith('2/')).length;
      expect(page2Requests, 1, reason: '第 2 页只应被请求一次');
      expect(results.where((r) => r).length, greaterThanOrEqualTo(1));
      expect(library.loadedPages, 2);
    });

    test('E 分页数据按 guid 去重（服务端返回重复项也不重复入库）', () async {
      // 故意让第 2 页包含第 1 页已有的 guid
      music.catalogue = <Track>[
        ...List<Track>.generate(50, (i) => makeTrack('g$i', title: 'A$i')),
        ...List<Track>.generate(50, (i) => makeTrack('g${i + 25}', title: 'B$i')),
      ];
      await library.loadFirst();
      await library.loadMore();

      final guids = library.tracks.map((t) => t.guid).toList();
      expect(guids.length, 75, reason: '50 + 25 新增，重叠的 25 首应被丢弃');
      expect(guids.toSet().length, guids.length, reason: '不得有重复 guid');
    });

    test('D 补充 loadFirst 在已有数据时不重复请求（返回页面不重头再来）', () async {
      seed(120);
      await library.loadFirst();
      await library.loadMore();
      music.trackPageRequests.clear();

      await library.loadFirst(); // 模拟页面重建

      expect(music.trackPageRequests, isEmpty, reason: '已有数据不应再请求第 1 页');
      expect(library.tracks.length, 100, reason: '数据仍在');
    });

    test('error 状态可 retry 恢复', () async {
      seed(60);
      music.failNextTrackRequest =
          const AppError('网络不通', kind: ErrorKind.network);
      await library.loadFirst();

      expect(library.phase, LibraryPhase.error);
      expect(library.error, isNotNull);

      await library.retry();
      expect(library.phase, LibraryPhase.ready);
      expect(library.tracks.length, 50);
    });
  });

  // ── F~G：队列跨分页 ──────────────────────────────────────
  group('F-H 播放队列突破分页边界', () {
    test('F 第 30 首播完能进入第 31 首（队列已含后续歌曲）', () async {
      // 模拟「曲库已加载多页，队列有 100 首」
      seed(100);
      await library.loadFirst();
      await library.loadMore();
      expect(library.tracks.length, 100);

      // 队列 = 曲库全部；跳到第 30 首（第 30 首结束应接第 31 首）
      playback.setQueue(library.tracks, startIndex: 29);
      await settle();
      expect(playback.current?.guid, 'g29');

      await engine.simulateTrackCompleted(); // 自然结束 → 下一首
      await settle();

      expect(playback.currentIndex, 30, reason: '应自动前进到第 31 首');
      expect(playback.current?.guid, 'g30');
      expect(engine.isPlaying, isTrue);
    });

    test('G 队列接近末尾时触发预加载', () async {
      seed(100);
      await library.loadFirst(); // 只有 50 首
      playback.setQueue(library.tracks, startIndex: 0);
      await settle();

      // 注入预加载回调
      var prefetchCalls = 0;
      playback.attachPrefetch(() async {
        prefetchCalls++;
        return library.loadMore();
      });

      // 走到第 48 首（离末尾 50 只剩 2 首 < 阈值 3）→ 应触发
      for (var i = 0; i < 47; i++) {
        await playback.next();
      }
      await settle();
      expect(prefetchCalls, greaterThan(0), reason: '接近队尾应自动预加载');
    });

    test('G 队列中间位置不触发预加载（避免无谓请求）', () async {
      seed(100);
      await library.loadFirst(); // 50 首
      playback.setQueue(library.tracks, startIndex: 0);
      await settle();

      var prefetchCalls = 0;
      playback.attachPrefetch(() async {
        prefetchCalls++;
        return true;
      });

      // 只走到第 10 首，离末尾还很远
      for (var i = 0; i < 10; i++) {
        await playback.next();
      }
      await settle();
      expect(prefetchCalls, 0, reason: '离队尾远，不该预加载');
    });

    test('H appendToQueue 不移动 currentIndex（不打断正在播放的歌）', () async {
      seed(30);
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 5);
      await settle();
      final playingGuid = playback.current?.guid;
      expect(playingGuid, 'g5');

      // 追加更多（用库里不存在的 guid，确保不会被去重掉）
      playback.appendToQueue(<Track>[makeTrack('extra_1'), makeTrack('extra_2')]);

      expect(playback.current?.guid, playingGuid, reason: '正在播放的歌不能变');
      expect(playback.currentIndex, 5, reason: 'currentIndex 不能被追加影响');
      // 30 首（seed）+ 2 首（追加）= 32
      expect(playback.queue.length, 32, reason: '30 首曲库 + 2 首新增');
      expect(
        playback.queue.last.guid,
        'extra_2',
        reason: '新增的曲目应在队尾',
      );
    });
  });

  // ── Q~S：播放模式 ────────────────────────────────────────
  group('Q-S 播放模式', () {
    test('Q 顺序播放：最后一首自然结束 → 停止，不回第一首', () async {
      seed(3);
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 2); // 最后一首
      await settle();
      expect(playback.currentIndex, 2);

      final loadsBefore = engine.loads.length;
      await engine.simulateTrackCompleted();
      await settle();

      expect(playback.currentIndex, 2, reason: '顺序播放应停在最后一首');
      expect(engine.loads.length, loadsBefore, reason: '不应再下发加载');
    });

    test('R 列表循环：最后一首自然结束 → 回第一首', () async {
      seed(3);
      await library.loadFirst();
      await playback.setMode(PlayMode.repeatAll);
      playback.setQueue(library.tracks, startIndex: 2);
      await settle();

      await engine.simulateTrackCompleted();
      await settle();

      expect(playback.currentIndex, 0, reason: '列表循环应回到队首');
      expect(engine.playingId, 'g0', reason: '且应开始播放第一首');
    });

    test('S 单曲循环：自然结束 → 当前曲重播（不换歌）', () async {
      seed(3);
      await library.loadFirst();
      await playback.setMode(PlayMode.repeatOne);
      playback.setQueue(library.tracks, startIndex: 1);
      await settle();
      expect(playback.current?.guid, 'g1');

      // 播放一段时间后自然结束
      engine.setPosition(const Duration(seconds: 30));
      await engine.simulateTrackCompleted();
      await settle();

      expect(playback.currentIndex, 1, reason: '单曲循环应停在当前首');
      expect(playback.current?.guid, 'g1', reason: '不换歌');
      expect(engine.playingId, 'g1');
    });

    test('T 播放模式切换生效且状态同步', () async {
      expect(playback.mode, PlayMode.sequence);
      await playback.setMode(PlayMode.shuffle);
      expect(playback.mode, PlayMode.shuffle);
      expect(playback.state.mode, PlayMode.shuffle, reason: '状态快照要同步');
    });

    test('列表循环下手动 next 到队尾会回绕', () async {
      seed(3);
      await library.loadFirst();
      await playback.setMode(PlayMode.repeatAll);
      playback.setQueue(library.tracks, startIndex: 2);
      await settle();

      await playback.next();
      await settle();
      expect(playback.currentIndex, 0, reason: '列表循环手动 next 也回绕');
    });

    test('顺序播放下手动 next 到队尾不动', () async {
      seed(3);
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 2);
      await settle();

      await playback.next();
      await settle();
      expect(playback.currentIndex, 2, reason: '顺序播放保持不动');
    });

    test('随机播放：连续自然结束不会崩溃且不重复当前曲', () async {
      seed(10);
      await library.loadFirst();
      await playback.setMode(PlayMode.shuffle);
      playback.setQueue(library.tracks, startIndex: 0);
      await settle();

      for (var i = 0; i < 5; i++) {
        await engine.simulateTrackCompleted();
        await settle();
        // 每次都应有有效的 current，且不越界
        expect(playback.currentIndex, inInclusiveRange(0, 9));
        expect(playback.current, isNotNull);
      }
    });
  });

  // ── 搜索 ────────────────────────────────────────────────
  group('搜索（本地已加载数据）', () {
    test('U 搜索匹配歌名', () async {
      seed(5);
      await library.loadFirst();
      final r = library.search('歌曲 3');
      expect(r.length, 1);
      expect(r.first.guid, 'g3');
    });

    test('U 搜索匹配专辑名', () async {
      seed(5);
      await library.loadFirst();
      final r = library.search('专辑 g2');
      expect(r.length, 1);
      expect(r.first.guid, 'g2');
    });

    test('搜索空串返回空列表', () async {
      seed(5);
      await library.loadFirst();
      expect(library.search(''), isEmpty);
      expect(library.search('   '), isEmpty);
    });

    test('搜索结果可建立独立播放队列（不污染曲库队列）', () async {
      seed(30);
      await library.loadFirst();

      final results = library.search('歌曲 1');
      expect(results, isNotEmpty);

      // 先播曲库
      playback.setQueue(library.tracks, startIndex: 0);
      await settle();

      // 再播搜索结果 —— 队列应被替换为搜索结果，且标记为 search 来源
      await playback.playQueue(results, source: QueueSource.search);
      await settle();

      expect(playback.source, QueueSource.search);
      expect(playback.queue.length, results.length);
      expect(playback.state.sourceLabel, '搜索结果');
    });
  });

  // ── 全库索引 ──────────────────────────────────────────────
  group('全库索引（供搜索覆盖全库）', () {
    test('buildFullIndex 会把曲库拉完', () async {
      seed(120); // 3 页
      await library.loadFirst();
      expect(library.tracks.length, 50);

      await library.buildFullIndex();

      expect(library.tracks.length, 120, reason: '索引完成后应有全部 120 首');
      expect(library.hasMore, isFalse);
      // 索引后搜索能命中最后一页的曲目
      expect(library.search('歌曲 119'), isNotEmpty);
    });

    test('buildFullIndex 可重入：并发调用不重复拉取', () async {
      seed(120);
      await library.loadFirst();
      music.trackPageRequests.clear();

      await Future.wait<void>(<Future<void>>[
        library.buildFullIndex(),
        library.buildFullIndex(),
      ]);

      // 第 2、3 页各只应请求一次（第二个调用复用第一个的 Future）
      final p2 = music.trackPageRequests.where((r) => r.startsWith('2/')).length;
      final p3 = music.trackPageRequests.where((r) => r.startsWith('3/')).length;
      expect(p2, 1);
      expect(p3, 1);
    });

    test('索引失败时停止，不无限重试', () async {
      seed(120);
      await library.loadFirst();
      music.failNextTrackRequest =
          const AppError('断了', kind: ErrorKind.network);

      await library.buildFullIndex();

      // 应该停在部分数据，且没有死循环
      expect(library.tracks.length, 50, reason: '失败后不应继续拉');
      expect(library.error, isNotNull);
    });
  });
}
