import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';

/// 【播放稳定性 V1】队列语义回归测试。
///
/// 覆盖任务书要求的 A–J 全部场景：
/// A 自然结束自动下一首 / B·C MediaSession 上一首下一首 /
/// D 失效歌曲自动跳过 / E 整队失效不死循环 / F 快速切歌竞态 /
/// G·H 队列边界不越界 / I 队尾自然结束不循环 /
/// J 播放页卸载不停止全局播放器。
///
/// 这些测试**不联网、不碰平台通道**：用 [FakePlaybackEngine] 替代
/// 依赖 ExoPlayer 的真实 `PlaybackHandler`。
void main() {
  late FakePlaybackEngine engine;
  late FakeMusicRepository music;
  late PlaybackRepository repo;

  /// 标记仓储是否已被用例自己 dispose（ChangeNotifier 不允许重复 dispose）。
  var repoDisposed = false;

  /// 等待串行加载链与微任务全部结束。
  ///
  /// ⚠️ 必须 `await repo.pendingLoads`：`next()` 只把加载任务**排进链**就返回，
  /// 自身不等加载完成，因此 `await next()` 之后引擎侧可能什么都还没发生。
  /// 只用零延时 `Future.delayed` 是不够的 —— 慢加载（几十毫秒）期间
  /// 零延时会全部立刻返回，导致断言跑在加载完成之前（真实踩过：
  /// 断言 `ids.last == 'guid_c'` 实际拿到 `'guid_a'`）。
  Future<void> settle() async {
    await repo.pendingLoads;
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 建立一个带 [tracks] 队列、当前位于 [startIndex] 的仓储。
  Future<void> givenQueue(List<Track> tracks, {int startIndex = 0}) async {
    repo.setQueue(tracks, startIndex: startIndex);
    // 让串行链上的首次加载真正完成。
    await settle();
  }

  setUp(() {
    engine = FakePlaybackEngine();
    music = FakeMusicRepository();
    repo = PlaybackRepository(music: music, handler: engine);
    repoDisposed = false;
  });

  tearDown(() async {
    // ChangeNotifier 被重复 dispose 会触发断言，单独用过的仓储不能在这里再关一次。
    if (!repoDisposed) {
      repo.dispose();
    }
    await engine.close();
  });

  // ── A：自然播放结束 → 自动下一首 ────────────────────────────────────
  group('A 歌曲自然结束后自动播放下一首', () {
    test('A 曲结束 → 自动切到 B 曲并开始播放', () async {
      final a = makeTrack('guid_a');
      final b = makeTrack('guid_b');
      await givenQueue(<Track>[a, b]);

      expect(repo.currentIndex, 0);
      expect(engine.playingId, 'guid_a', reason: '初始应播放 A');

      await engine.simulateTrackCompleted();
      await settle();

      expect(repo.currentIndex, 1, reason: 'A 结束后索引应前进到 B');
      expect(engine.playingId, 'guid_b', reason: 'B 应已开始播放');
      expect(engine.isPlaying, isTrue);
    });

    test('A 自动切歌不要求用户手动按下一首', () async {
      final a = makeTrack('guid_a');
      final b = makeTrack('guid_b');
      await givenQueue(<Track>[a, b]);

      // 不调用 repo.next()，仅靠 completed 事件。
      await engine.simulateTrackCompleted();
      await settle();

      expect(engine.loads.length, 2, reason: '应下发过两次加载：A 与 B');
      expect(engine.loads.last.item.id, 'guid_b');
    });
  });

  // ── B·C：MediaSession 上一首 / 下一首 → Repository ──────────────────
  group('B/C MediaSession 传输键接到 Repository 队列', () {
    test('B 桥接已装配：Repository 把自身注册为 commandListener', () {
      expect(engine.listener, isNotNull, reason: 'MediaSession 回调必须装上');
      expect(engine.listener, same(repo));
    });

    test('B MediaSession skipToNext → currentIndex 前进', () async {
      await givenQueue(<Track>[makeTrack('guid_a'), makeTrack('guid_b')]);

      await engine.mediaKeyNext();
      await settle();

      expect(engine.skipNextCalls, 1);
      expect(repo.currentIndex, 1, reason: '媒体键下一曲应与页面按钮同一套逻辑');
      expect(engine.playingId, 'guid_b');
    });

    test('C MediaSession skipToPrevious → currentIndex 后退', () async {
      await givenQueue(
        <Track>[makeTrack('guid_a'), makeTrack('guid_b')],
        startIndex: 1,
      );

      await engine.mediaKeyPrevious();
      await settle();

      expect(engine.skipPreviousCalls, 1);
      expect(repo.currentIndex, 0, reason: '媒体键上一曲应与页面按钮同一套逻辑');
      expect(engine.playingId, 'guid_a');
    });

    test('B/C 媒体键与页面按钮作用于同一个索引（无两套状态）', () async {
      final tracks = <Track>[
        makeTrack('guid_a'),
        makeTrack('guid_b'),
        makeTrack('guid_c'),
      ];
      await givenQueue(tracks);

      await repo.next();
      await settle();
      final afterPageButton = repo.currentIndex;

      await engine.mediaKeyNext();
      await settle();

      expect(
        repo.currentIndex,
        afterPageButton + 1,
        reason: '两条入口必须叠加在同一索引上，而不是各维护一份',
      );
    });
  });

  // ── D：失效歌曲自动跳过 ────────────────────────────────────────────
  group('D 失效歌曲自动跳到下一首可播歌曲', () {
    test('D 当前曲 accessStatus=3 → 自动跳到后面可播的曲目', () async {
      final bad = makeInvalidTrack('guid_bad');
      final good = makeTrack('guid_good');
      await givenQueue(<Track>[bad, good]);

      expect(repo.currentIndex, 1, reason: '应跳过失效的 index 0');
      expect(engine.playingId, 'guid_good', reason: '应播放后面那首可播的');
    });

    test('D 队首失效、其后可播 → 只跳到最近的可播曲目', () async {
      final tracks = <Track>[
        makeInvalidTrack('bad_1'),
        makeInvalidTrack('bad_2'),
        makeTrack('good_3'),
      ];
      await givenQueue(tracks);

      expect(repo.currentIndex, 2);
      expect(engine.playingId, 'good_3');
    });

    test('D 切歌落到失效曲目时同样自动跳过（不是只保护首播）', () async {
      final tracks = <Track>[
        makeTrack('guid_a'),
        makeInvalidTrack('guid_bad'),
        makeTrack('guid_c'),
      ];
      await givenQueue(tracks);
      expect(engine.playingId, 'guid_a');

      await repo.next();
      await settle();

      expect(repo.current?.guid, 'guid_c', reason: '应越过失效的 guid_bad');
      expect(engine.playingId, 'guid_c');
    });
  });

  // ── E：整队失效不死循环 ────────────────────────────────────────────
  group('E 整个队列都不可播放时不死循环、不崩溃', () {
    test('E 全队失效 → 不下发任何加载、不抛异常', () async {
      final tracks = <Track>[
        makeInvalidTrack('bad_1'),
        makeInvalidTrack('bad_2'),
        makeInvalidTrack('bad_3'),
      ];

      // 必须在有限时间内返回：若实现里存在递归/无界循环，这里会超时。
      repo.setQueue(tracks, startIndex: 0);
      await settle();

      expect(engine.loads, isEmpty, reason: '没有可播曲目就不应下发加载');
      expect(repo.current?.guid, 'bad_1', reason: '索引不应越界');
    });

    test('E 队尾失效且后面无可播曲目 → 停止而不是回绕', () async {
      final tracks = <Track>[makeTrack('good_1'), makeInvalidTrack('bad_2')];
      repo.setQueue(tracks, startIndex: 0);
      await settle();
      expect(engine.playingId, 'good_1');

      await repo.next();
      await settle();

      // index=1 是失效曲目，其后无歌可跳 → 保持原状，不回到 index 0。
      expect(repo.currentIndex, 1);
      expect(engine.loads.length, 1, reason: '不应重新下发 good_1');
    });

    test('E 连续触发 completed 也不会无限自动切歌', () async {
      await givenQueue(<Track>[makeTrack('guid_a'), makeTrack('guid_b')]);

      // 队尾后再连发 completed：应停在队尾，不发生回绕。
      await engine.simulateTrackCompleted();
      await settle();
      expect(repo.currentIndex, 1);

      final loadsBefore = engine.loads.length;
      await engine.simulateTrackCompleted();
      await engine.simulateTrackCompleted();
      await settle();

      expect(repo.currentIndex, 1, reason: '队尾不应回绕到 index 0');
      expect(engine.loads.length, loadsBefore, reason: '不应重复下发加载');
    });
  });

  // ── F：快速连续切歌的竞态 ──────────────────────────────────────────
  group('F 快速连续切歌时旧请求不得覆盖新请求', () {
    test('F 连按三次下一首 → 最终播放的是最后一次选择', () async {
      final tracks = <Track>[
        makeTrack('guid_a'),
        makeTrack('guid_b'),
        makeTrack('guid_c'),
        makeTrack('guid_d'),
      ];
      await givenQueue(tracks);

      // 三次 next() 都不等待完成 —— 复现遥控器连按。
      // 串行链会让 guid_b / guid_c 在真正下发前就已过期，只有 guid_d 会触达引擎。
      final f1 = repo.next();
      final f2 = repo.next();
      final f3 = repo.next();
      await Future.wait(<Future<void>>[f1, f2, f3]);
      await settle();

      expect(
        repo.currentIndex,
        3,
        reason: '索引应停在最后一次 next() 的目标',
      );
      expect(
        engine.playingId,
        'guid_d',
        reason: '实际播放的必须是最后一次选择的曲目，不能被旧请求覆盖',
      );
      expect(
        engine.loads.map((l) => l.item.id).toList(),
        <String>['guid_a', 'guid_d'],
        reason: '过期的 guid_b / guid_c 不应下发到引擎',
      );
    });

    test('F 旧的慢请求不得在新请求之后下发音源', () async {
      final tracks = <Track>[
        makeTrack('guid_a'),
        makeTrack('guid_b'),
        makeTrack('guid_c'),
      ];
      await givenQueue(tracks);

      // b 的加载很慢（60ms）。在它还在飞的时候请求 c。
      // 串行链保证 c 一定排在 b 之后下发 —— 这正是「旧请求不能覆盖新请求」的核心。
      engine.loadDelays['guid_b'] = const Duration(milliseconds: 60);

      final pendingNext = repo.next(); // → b（慢），已排进链
      // 不等 b 完成，立刻请求 c（复现「用户手快」）。
      final afterNext = repo.next(); // → c（快），排在 b 之后
      await Future.wait(<Future<void>>[pendingNext, afterNext]);
      // 关键：等整条串行链排空，b 与 c 都真正下发过。
      await settle();

      final ids = engine.loads.map((l) => l.item.id).toList();
      expect(
        ids.last,
        'guid_c',
        reason: '最后一次下发的必须是最新曲目，实际下发顺序: $ids',
      );
      expect(
        ids.indexOf('guid_b') < ids.indexOf('guid_c'),
        isTrue,
        reason: '慢的 guid_b 必须先于 guid_c 落地，'
            '若顺序反了说明旧请求覆盖了新请求（实际下发顺序: $ids）',
      );
      expect(repo.current?.guid, 'guid_c');
    });

    test('F 序号单调递增：每次播放请求都有独立代号', () async {
      final tracks = <Track>[
        makeTrack('guid_a'),
        makeTrack('guid_b'),
        makeTrack('guid_c'),
      ];
      await givenQueue(tracks);

      await repo.next();
      await settle();
      await repo.next();
      await settle();

      // 三次播放请求都真正下发过（未被误判为过期）。
      expect(
        engine.loads.map((l) => l.item.id).toList(),
        <String>['guid_a', 'guid_b', 'guid_c'],
      );
    });
  });

  // ── G·H：队列边界 ──────────────────────────────────────────────────
  group('G/H 队列边界不越界、不崩溃', () {
    test('G 第一首按上一首 → 保持第一首', () async {
      await givenQueue(<Track>[makeTrack('guid_a'), makeTrack('guid_b')]);
      engine.setPosition(Duration.zero); // 未超过 3 秒 → 走切歌语义

      await repo.previous();
      await settle();

      expect(repo.currentIndex, 0, reason: '已是第一首，不应越界到 -1');
      expect(repo.current?.guid, 'guid_a');
      expect(engine.playingId, 'guid_a', reason: '不应重新下发加载');
    });

    test('H 最后一首按下一首 → 保持最后一首', () async {
      await givenQueue(
        <Track>[makeTrack('guid_a'), makeTrack('guid_b')],
        startIndex: 1,
      );

      await repo.next();
      await settle();

      expect(repo.currentIndex, 1, reason: '已是最后一首，不应越界');
      expect(repo.current?.guid, 'guid_b');
    });

    test('G 播放超过 3 秒时上一首回到本曲开头（不切歌）', () async {
      await givenQueue(<Track>[makeTrack('guid_a'), makeTrack('guid_b')]);
      engine.setPosition(const Duration(seconds: 10));

      await repo.previous();
      await settle();

      expect(repo.currentIndex, 0, reason: '应保持在当前曲目');
      expect(engine.seeks, isNotEmpty, reason: '应执行 seek 到开头');
      expect(engine.seeks.last, Duration.zero);
    });
  });

  // ── I：最后一首自然结束 ────────────────────────────────────────────
  group('I 最后一首自然播放结束不无限循环', () {
    test('I 队尾 completed → 停在 completed，不回绕', () async {
      final tracks = <Track>[makeTrack('guid_a'), makeTrack('guid_b')];
      await givenQueue(tracks);

      await repo.next();
      await settle();
      expect(repo.currentIndex, 1);

      final loadsBefore = engine.loads.length;
      await engine.simulateTrackCompleted();
      await settle();

      expect(repo.currentIndex, 1, reason: '队尾不应回绕');
      expect(engine.loads.length, loadsBefore, reason: '不应再下发加载');
    });

    test('I 单曲队列自然结束后保持该曲', () async {
      await givenQueue(<Track>[makeTrack('only')]);

      await engine.simulateTrackCompleted();
      await settle();

      expect(repo.currentIndex, 0);
      expect(repo.current?.guid, 'only');
      expect(engine.isPlaying, isFalse, reason: '单曲结束后应为停止播放态');
    });
  });

  // ── J：播放页卸载不停止全局播放 ────────────────────────────────────
  group('J 返回歌曲列表后播放不中断', () {
    test('J 仓储不因「页面消失」而调用 stop', () async {
      await givenQueue(<Track>[makeTrack('guid_a'), makeTrack('guid_b')]);
      expect(engine.playingId, 'guid_a');

      // 播放页只是 Provider 下的一次 build，卸载页面不会触碰 Repository。
      // 这里直接验证：仓储生命周期内没有任何隐式 stop。
      expect(engine.stopCalls, 0, reason: '正常播放不应调用 stop');
    });

    test('J 曲目切换（模拟离开播放页再选歌）后仍在播放', () async {
      await givenQueue(<Track>[makeTrack('guid_a'), makeTrack('guid_b')]);

      // 模拟「回列表 → 选另一首」，播放状态应继续而非要重新初始化。
      await repo.next();
      await settle();

      expect(engine.stopCalls, 0, reason: '切歌不等于停止播放');
      expect(engine.isPlaying, isTrue);
      expect(engine.playingId, 'guid_b');
    });

    test('J Repository.dispose 只解绑监听，不停止播放器', () async {
      await givenQueue(<Track>[makeTrack('guid_a')]);

      repo.dispose();
      repoDisposed = true;

      expect(
        engine.stopCalls,
        0,
        reason: 'dispose 不应触发 stop：播放状态属于全局播放层，'
            '不绑定任何页面生命周期',
      );
    });

    test('J dispose 后迟到的加载回调不得抛异常', () async {
      // 构造「加载还在飞 → 仓储被销毁」的真实竞态窗口。
      engine.loadDelays['guid_a'] = const Duration(milliseconds: 40);
      repo.setQueue(<Track>[makeTrack('guid_a'), makeTrack('guid_b')], startIndex: 0);

      // 未等加载完成就 dispose。
      repo.dispose();
      repoDisposed = true;

      // 等待那个迟到的回调抵达：dispose 之后 notifyListeners 会抛异常，
      // 这里的 _safeNotify 必须把它挡掉。
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(engine.stopCalls, 0);
      expect(
        repo.current?.guid,
        'guid_a',
        reason: 'dispose 不应改变队列数据',
      );
    });
  });

  // ── 附加：加载失败不破坏队列状态 ────────────────────────────────────
  group('附加：加载失败与播放控制', () {
    test('加载抛异常时索引不越界，队列仍可继续操作', () async {
      final tracks = <Track>[makeTrack('guid_a'), makeTrack('guid_b')];
      engine.failLoad = true;

      repo.setQueue(tracks, startIndex: 0);
      await settle();

      // V2 起：加载失败会**自动跳过**这首（V2 §15「当前歌曲确认不可播放时，
      // 允许自动跳过并尝试下一首」）。两首都失败 → 达到上限后停止，
      // 索引停在最后一首且**不越界**、不崩溃。
      expect(repo.currentIndex, inInclusiveRange(0, 1));
      expect(repo.current, isNotNull);
    });

    test('网络恢复后按播放能重新加载并继续听（V2 §15）', () async {
      final tracks = <Track>[makeTrack('guid_a'), makeTrack('guid_b')];
      engine.failLoad = true;
      repo.setQueue(tracks, startIndex: 0);
      await settle();

      // 两首都加载失败 → 自动跳过到达上限后停止，队列停在最后一首。
      expect(repo.current?.guid, 'guid_b');
      expect(engine.playingId, isNull, reason: '失败时不应有音源在播');

      // 网络恢复：用户按「播放」。
      // ⚠️ 此时引擎里**没有音源**，若 play() 只是转发给引擎就会毫无反应，
      // 用户会以为按钮坏了 —— 这正是本用例要钉住的行为。
      engine.failLoad = false;
      await repo.play();
      await settle();

      expect(
        engine.playingId,
        'guid_b',
        reason: '网络恢复后按播放应重新加载当前曲目',
      );
      expect(repo.state.error, isNull, reason: '恢复后错误态应清除');
    });

    test('togglePlay 走引擎的 play/pause', () async {
      await givenQueue(<Track>[makeTrack('guid_a')]);

      await repo.togglePlay();
      expect(engine.pauseCalls, 1);

      await repo.togglePlay();
      expect(engine.playCalls, greaterThanOrEqualTo(1));
    });
  });
}
