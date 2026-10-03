import 'dart:math';

import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/playback/playback_control.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 【V5】四种播放模式的真实行为回归。
///
/// 对应需求「播放模式的补充要求」§（补充六）～（补充八）：
/// 顺序播放 / 列表循环 / 随机播放 / 单曲循环 必须**真实生效**，
/// 不接受「只改按钮文案、只补占位 UI 或仅宣称支持循环」。
///
/// ## 为什么全部用 `FakePlaybackEngine`
/// 真实 `PlaybackHandler` 内部 `AudioPlayer()` 依赖 ExoPlayer，
/// 纯 Dart 无法实例化。本文件断言的是**队列语义**，恰好全部落在
/// `PlaybackRepository` 里，因此可以完全离线验证
/// 「实际下发了几次加载、加载的是哪一首」。
///
/// ## 随机的可重复性
/// 需求要求「用可控的随机种子验证随机序列，但实际使用不固定种子」。
/// 因此这里通过 `PlaybackRepository(random: Random(seed))` 注入固定种子；
/// 生产路径（不传 `random`）仍是系统随机源。
void main() {
  late FakePlaybackEngine engine;
  late FakeMusicRepository music;
  late FakeSecureStore store;
  late PlaybackRepository repo;
  var repoDisposed = false;
  var engineClosed = false;

  /// 等待串行加载链与微任务全部结束（与 `playback_queue_test.dart` 同款）。
  Future<void> settle() async {
    await repo.pendingLoads;
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 建仓储。不传 [seed] 时用系统随机源（与生产一致）。
  void build({int? seed}) {
    engine = FakePlaybackEngine();
    music = FakeMusicRepository();
    store = FakeSecureStore();
    repo = PlaybackRepository(
      music: music,
      handler: engine,
      store: store,
      random: seed == null ? null : Random(seed),
    );
    repoDisposed = false;
    engineClosed = false;
  }

  /// 关掉当前这一对（仓储 + 引擎），供同一个用例里换新种子重跑。
  Future<void> recycle() async {
    if (!repoDisposed) {
      repo.dispose();
      repoDisposed = true;
    }
    if (!engineClosed) {
      await engine.close();
      engineClosed = true;
    }
  }

  Future<void> givenQueue(List<Track> tracks, {int startIndex = 0}) async {
    repo.setQueue(tracks, startIndex: startIndex);
    await settle();
  }

  /// 编号曲目 g0..g(n-1)。
  List<Track> tracksOf(int n) =>
      <Track>[for (int i = 0; i < n; i++) makeTrack('g$i', title: '曲目$i')];

  /// 引擎侧实际在播的 guid（而不是仓储自报）—— 用于抓「界面与实际不一致」。
  String? playing() => engine.playingId;

  /// 模拟「自然播完」。
  Future<void> complete() async {
    await engine.simulateTrackCompleted();
    await settle();
  }

  /// 随机模式下一轮的覆盖集合（从当前曲开始走完 plan 里的每一项）。
  ///
  /// ⚠️ 一轮的边界由**计划是否被用尽**决定：`_rebuildPlan` 会排除「当前这首」
  /// （它属于上一轮），所以 N 首队列的一轮 = 首曲 + (N-1) 项计划。
  Future<List<String>> walkOneRound(int n) async {
    final List<String> visited = <String>[playing()!];
    for (var i = 0; i < n - 1; i++) {
      await repo.next();
      await settle();
      visited.add(playing()!);
    }
    return visited;
  }

  setUp(build);

  tearDown(() async {
    if (!repoDisposed) repo.dispose();
    if (!engineClosed) await engine.close();
  });

  // ══════════════════════════════════════════════════════════════════
  // 模式循环顺序
  // ══════════════════════════════════════════════════════════════════
  group('播放模式循环顺序', () {
    test('顺序 → 列表循环 → 随机 → 单曲 → 顺序（与按钮文案一致）', () {
      const List<PlayMode> expected = <PlayMode>[
        PlayMode.sequence,
        PlayMode.repeatAll,
        PlayMode.shuffle,
        PlayMode.repeatOne,
      ];
      // `PlayMode.values` 的顺序**就是**按钮顺序（见 playback_control.dart 注释）。
      expect(PlayMode.values, expected);

      PlayMode m = PlayMode.sequence;
      final List<PlayMode> cycle = <PlayMode>[];
      for (var i = 0; i < 4; i++) {
        cycle.add(m);
        m = m.next;
      }
      expect(cycle, expected, reason: '四次点击应正好走完一圈');
      expect(m, PlayMode.sequence, reason: '第 5 次点击应回到起点');
    });

    test('模式持久化用显式字符串，包含全部四种且损坏值安全降级', () {
      expect(
        <String>{for (final m in PlayMode.values) m.storageKey},
        <String>{'sequence', 'repeat_all', 'shuffle', 'repeat_one'},
      );
      expect(PlayModeX.fromStorage('repeat_one'), PlayMode.repeatOne);
      expect(PlayModeX.fromStorage('乱码'), PlayMode.sequence);
      expect(PlayModeX.fromStorage(null), PlayMode.sequence);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 顺序播放
  // ══════════════════════════════════════════════════════════════════
  group('顺序播放', () {
    test('自然播放依次前进 A→B→C，最后一首结束后停止且不回第一首', () async {
      await givenQueue(tracksOf(3));
      expect(playing(), 'g0');

      await complete();
      expect(playing(), 'g1');
      await complete();
      expect(playing(), 'g2');

      final int loadsBefore = engine.loads.length;
      await complete();

      expect(repo.currentIndex, 2, reason: '应停在最后一首');
      expect(engine.loads.length, loadsBefore, reason: '不得回绕重新播放 g0');
      expect(engine.isPlaying, isFalse, reason: '顺序播放到队尾应停止');
    });

    test('最后一首手动「下一首」不重新开始整个队列', () async {
      await givenQueue(tracksOf(3), startIndex: 2);
      final int loadsBefore = engine.loads.length;

      await repo.next();
      await settle();

      expect(repo.currentIndex, 2);
      expect(engine.loads.length, loadsBefore, reason: '不得重新下发 g0');
    });

    test('第一首手动「上一首」无操作（不回绕），且按钮应置灰', () async {
      await givenQueue(tracksOf(3));
      final int loadsBefore = engine.loads.length;

      await repo.previous();
      await settle();

      expect(repo.currentIndex, 0);
      expect(engine.loads.length, loadsBefore);
      expect(repo.state.hasPrevious, isFalse, reason: '按钮应置灰而不是按了没反应');
    });

    test('只有一首时「下一首」无操作（顺序播放 ≠ 循环）', () async {
      await givenQueue(tracksOf(1));
      final int loadsBefore = engine.loads.length;

      await repo.next();
      await settle();

      expect(repo.currentIndex, 0);
      expect(engine.loads.length, loadsBefore);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 列表循环
  // ══════════════════════════════════════════════════════════════════
  group('列表循环', () {
    test('A→B→C→A→B→C→A 连续跑两轮（自然结束驱动）', () async {
      await repo.setMode(PlayMode.repeatAll);
      await givenQueue(tracksOf(3));

      final List<String?> seq = <String?>[playing()];
      for (var i = 0; i < 6; i++) {
        await complete();
        seq.add(playing());
      }

      expect(
        seq,
        <String>['g0', 'g1', 'g2', 'g0', 'g1', 'g2', 'g0'],
        reason: '两轮之后应回到 g0',
      );
    });

    test('第一首处「上一首」回到最后一首', () async {
      await repo.setMode(PlayMode.repeatAll);
      await givenQueue(tracksOf(3));

      await repo.previous();
      await settle();

      expect(playing(), 'g2', reason: '列表循环的首曲上一首应回绕到队尾');
      expect(repo.currentIndex, 2);
    });

    test('只有一首时循环该首', () async {
      await repo.setMode(PlayMode.repeatAll);
      await givenQueue(tracksOf(1));

      await complete();
      expect(playing(), 'g0', reason: '单曲队列在列表循环下应重播');
      await complete();
      expect(playing(), 'g0');
    });

    test('最后一首手动「下一首」回绕到第一首', () async {
      await repo.setMode(PlayMode.repeatAll);
      await givenQueue(tracksOf(3), startIndex: 2);

      await repo.next();
      await settle();

      expect(repo.currentIndex, 0);
      expect(playing(), 'g0');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 随机播放
  // ══════════════════════════════════════════════════════════════════
  group('随机播放', () {
    test('一轮内每首恰好一次（不重复、不遗漏）', () async {
      build(seed: 20261003);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(10));

      final List<String> visited = await walkOneRound(10);

      expect(visited.toSet().length, 10, reason: '一轮 10 首里出现重复：$visited');
      expect(
        visited.toSet(),
        <String>{for (int i = 0; i < 10; i++) 'g$i'},
        reason: '一轮必须覆盖队列里每一首',
      );
    });

    test('确实被打乱：多个种子给出的顺序不止一种', () async {
      // ⚠️ 需求明确：「随机序列偶尔恰好与列表顺序相同，不能作为随机不正确的判据」。
      // 因此这里不判断某一具体序列是否等于列表顺序，而是验证
      // **不同种子给出不同顺序**（同一固定种子下结果完全可复现）。
      final Set<String> orders = <String>{};
      for (final int seed in <int>[1, 2, 3, 4, 5]) {
        build(seed: seed);
        await repo.setMode(PlayMode.shuffle);
        await givenQueue(tracksOf(9));
        orders.add((await walkOneRound(9)).join(','));
        await recycle();
      }

      expect(
        orders.length,
        greaterThanOrEqualTo(3),
        reason: '5 个种子只产生了 ${orders.length} 种顺序，'
            '说明随机序列几乎是固定的',
      );
    });

    test('手动「下一首」与自然结束使用同一份随机计划', () async {
      const int seed = 42;
      // 仓储 A：只用 completed（自然结束）驱动。
      build(seed: seed);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(6));
      final List<String?> byAuto = <String?>[playing()];
      for (var i = 0; i < 5; i++) {
        await complete();
        byAuto.add(playing());
      }
      await recycle();

      // 仓储 B：只用 next()（手动切歌）驱动，同一种子。
      build(seed: seed);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(6));
      final List<String?> byManual = <String?>[playing()];
      for (var i = 0; i < 5; i++) {
        await repo.next();
        await settle();
        byManual.add(playing());
      }

      expect(
        byAuto,
        byManual,
        reason: '自然结束与手动下一首必须共用同一份随机遍历计划',
      );
    });

    test('一轮走完后重新洗牌，跨轮不立即重复上一轮最后一首', () async {
      build(seed: 7);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(5));

      final List<String> round1 = await walkOneRound(5);
      expect(round1.toSet().length, 5, reason: '第一轮应覆盖 5 首：$round1');

      // 第二轮 = 上一轮的最后一首（作为新的"当前"）+ 新计划的 4 项。
      await repo.next();
      await settle();
      final String firstOfRound2 = playing()!;
      expect(
        firstOfRound2,
        isNot(round1.last),
        reason: '跨轮不得立即重复上一轮最后一首',
      );

      final List<String> round2 = <String>[round1.last, firstOfRound2];
      for (var i = 0; i < 3; i++) {
        await repo.next();
        await settle();
        round2.add(playing()!);
      }
      expect(round2.toSet().length, 5, reason: '第二轮应覆盖 5 首：$round2');
    });

    test('上一首回到**实际播放历史**，而不是队列列表里前一首', () async {
      build(seed: 99);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(8));

      final List<String> played = <String>[playing()!];
      for (var i = 0; i < 3; i++) {
        await repo.next();
        await settle();
        played.add(playing()!);
      }
      expect(played.toSet().length, 4, reason: '一轮内不该重复：$played');

      await repo.previous();
      await settle();

      expect(
        playing(),
        played[played.length - 2],
        reason: '随机的「上一首」必须是本次播放中此前那一首（顺序：$played）',
      );
    });

    test('没有播放历史时不跳到队列里前一首', () async {
      build(seed: 5);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(5), startIndex: 3);

      final int loadsBefore = engine.loads.length;
      await repo.previous();
      await settle();

      expect(engine.loads.length, loadsBefore, reason: '随机模式下应无操作');
      expect(repo.currentIndex, 3, reason: '绝不能跳到列表里前一首 g2');
    });

    test('只有一首时随机播放循环该首', () async {
      build(seed: 3);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(1));

      await complete();
      expect(playing(), 'g0', reason: '一轮就等于这一首 → 应循环');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 单曲循环
  // ══════════════════════════════════════════════════════════════════
  group('单曲循环', () {
    test('B 连续两次自然结束都重播 B（不跳下一首）', () async {
      await repo.setMode(PlayMode.repeatOne);
      await givenQueue(tracksOf(3), startIndex: 1);
      expect(playing(), 'g1');

      await complete();
      expect(playing(), 'g1', reason: '单曲循环第一次自然结束应重播 B');
      expect(repo.currentIndex, 1);

      await complete();
      expect(playing(), 'g1', reason: '第二次也必须还是 B');
      expect(repo.currentIndex, 1);
    });

    test('单曲循环是「重新下发加载」而不是 seek(0)+play()', () async {
      // completed 状态下 seek(0) 之后 play() 在部分 ROM 上不起播，
      // 会紧接着被「自然结束」推进到下一首 —— 这正是「单曲循环跳下一首」的根因。
      await repo.setMode(PlayMode.repeatOne);
      await givenQueue(tracksOf(3), startIndex: 1);

      final int loadsBefore = engine.loads.length;
      await complete();

      expect(
        engine.loads.length,
        loadsBefore + 1,
        reason: '单曲循环必须真的重新下发一次加载',
      );
      expect(engine.loads.last.item.id, 'g1');
      expect(engine.seeks, isEmpty, reason: '不应走 seek(0) 这条不可靠路径');
    });

    test('单曲循环中手动下一首 → B→C，C 结束后仍循环 C；模式不变', () async {
      await repo.setMode(PlayMode.repeatOne);
      await givenQueue(tracksOf(3), startIndex: 1);

      await repo.next();
      await settle();
      expect(playing(), 'g2', reason: '手动下一首应切到队列顺序的下一首');
      expect(repo.mode, PlayMode.repeatOne, reason: '手动切歌不得改变模式');

      await complete();
      expect(playing(), 'g2', reason: 'C 结束后应继续循环 C');
      await complete();
      expect(playing(), 'g2');
    });

    test('单曲循环中手动上一首同样可切，且模式与当前曲一致', () async {
      await repo.setMode(PlayMode.repeatOne);
      await givenQueue(tracksOf(3), startIndex: 1);

      await repo.previous();
      await settle();
      expect(playing(), 'g0');
      expect(repo.mode, PlayMode.repeatOne);

      await complete();
      expect(playing(), 'g0', reason: '切到 A 之后同样要循环 A');
    });

    test('单曲循环在队尾手动下一首允许回绕到队首', () async {
      await repo.setMode(PlayMode.repeatOne);
      await givenQueue(tracksOf(3), startIndex: 2);

      await repo.next();
      await settle();

      expect(repo.currentIndex, 0, reason: '需求：单曲循环下队列边界允许回绕');
      expect(repo.mode, PlayMode.repeatOne);
    });

    test('只有一首时手动切歌从头播放', () async {
      await repo.setMode(PlayMode.repeatOne);
      await givenQueue(tracksOf(1));

      final int loadsBefore = engine.loads.length;
      await repo.next();
      await settle();

      expect(repo.currentIndex, 0);
      expect(engine.loads.length, loadsBefore + 1, reason: '应从头重播这一首');
    });

    test('循环重播不会无限堆历史（同一首不算"去过新地方"）', () async {
      await repo.setMode(PlayMode.repeatOne);
      await givenQueue(tracksOf(3), startIndex: 1);

      final int before = repo.playHistory.length;
      await complete();
      await complete();
      await complete();

      expect(repo.playHistory.length, before);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 模式切换与生命周期
  // ══════════════════════════════════════════════════════════════════
  group('切换模式不重启、不丢进度、不重建音源', () {
    test('播放中依次切换四种模式', () async {
      await givenQueue(tracksOf(4));
      await repo.next();
      await settle();
      expect(playing(), 'g1');

      engine.setPosition(const Duration(seconds: 42));
      final int loadsBefore = engine.loads.length;
      final int seeksBefore = engine.seekCalls;

      for (final PlayMode m in <PlayMode>[
        PlayMode.repeatAll,
        PlayMode.shuffle,
        PlayMode.repeatOne,
        PlayMode.sequence,
      ]) {
        await repo.setMode(m);
      }

      expect(engine.loads.length, loadsBefore, reason: '切模式不得重新加载音源');
      expect(engine.seekCalls, seeksBefore, reason: '切模式不得 seek');
      expect(engine.position, const Duration(seconds: 42), reason: '进度不得丢失');
      expect(repo.current?.guid, 'g1', reason: '切模式不得换曲');
      expect(engine.isPlaying, isTrue);
    });

    test('暂停时切换模式保持暂停（不得自动开始播放）', () async {
      await givenQueue(tracksOf(3));
      await repo.pause();
      expect(engine.isPlaying, isFalse);
      final int pauseCallsBefore = engine.pauseCalls;

      await repo.setMode(PlayMode.repeatAll);
      await repo.setMode(PlayMode.shuffle);
      await repo.setMode(PlayMode.repeatOne);

      expect(engine.isPlaying, isFalse, reason: '暂停 + 切模式必须仍是暂停');
      expect(engine.pauseCalls, pauseCallsBefore, reason: '不应重复下发 pause');
      expect(engine.playCalls, 0);
    });

    test('切回顺序播放不把队列洗乱', () async {
      await givenQueue(tracksOf(5));
      final List<String> before = <String>[for (final t in repo.queue) t.guid];

      await repo.setMode(PlayMode.shuffle);
      await repo.setMode(PlayMode.sequence);

      expect(<String>[for (final t in repo.queue) t.guid], before);
      expect(repo.currentIndex, 0, reason: '队列顺序不动 → 当前下标也不该动');
    });
  });

  group('并发与重入：不会一次跳过多首', () {
    test('两次 completed 并发只推进一首', () async {
      await givenQueue(tracksOf(5));

      final Future<void> f1 = engine.simulateTrackCompleted();
      final Future<void> f2 = engine.simulateTrackCompleted();
      await Future.wait(<Future<void>>[f1, f2]);
      await settle();

      expect(repo.currentIndex, 1, reason: '应只前进一首');
      expect(playing(), 'g1');
    });

    test('自然结束与手动下一首同时发生：界面与实际播放仍一致', () async {
      await givenQueue(tracksOf(5));

      final Future<void> auto = engine.simulateTrackCompleted();
      final Future<void> manual = repo.next();
      await Future.wait(<Future<void>>[auto, manual]);
      await settle();

      expect(playing(), repo.current?.guid, reason: '界面与实际播放必须一致');
      expect(repo.currentIndex, lessThanOrEqualTo(2));
    });

    test('单曲循环下切歌后再自然结束，不会被推走', () async {
      await repo.setMode(PlayMode.repeatOne);
      await givenQueue(tracksOf(4));

      await repo.next();
      await settle();
      expect(playing(), 'g1');

      await complete();
      expect(playing(), 'g1');
      expect(repo.currentIndex, 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 边界与规模
  // ══════════════════════════════════════════════════════════════════
  group('边界与规模', () {
    test('空队列：不崩溃、停止旧音源、current 为 null', () async {
      await givenQueue(tracksOf(2));
      expect(playing(), 'g0');

      repo.setQueue(const <Track>[]);
      await settle();

      expect(repo.current, isNull);
      expect(repo.currentIndex, -1);
      expect(engine.stopCalls, greaterThanOrEqualTo(1), reason: '空队列必须停掉旧音源');

      // 四种模式下的推进都不能崩。
      for (final PlayMode m in PlayMode.values) {
        await repo.setMode(m);
        await repo.next();
        await repo.previous();
        await complete();
      }
      expect(repo.queue, isEmpty);
    });

    test('重复条目按 guid 去重（避免随机计划重复命中同一首）', () async {
      final Track a = makeTrack('g0');
      repo.setQueue(<Track>[a, a, makeTrack('g1')]);
      await settle();

      expect(repo.queue.length, 2, reason: '同一 guid 只保留首次出现');
    });

    test('137 首（每页 50 的分页场景）：第 51 首与最后一首都能被随机计划覆盖', () async {
      build(seed: 2026);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(137));

      final Set<String> visited = <String>{playing()!};
      for (var i = 0; i < 136; i++) {
        await repo.next();
        await settle();
        visited.add(playing()!);
      }

      expect(visited.length, 137, reason: '一轮必须覆盖全部 137 首，不被分页截断');
      expect(visited.contains('g50'), isTrue, reason: '第 51 首必须可达');
      expect(visited.contains('g136'), isTrue, reason: '最后一首必须可达');
    });

    test('队列追加后新增曲目本轮就能随机到（不必等下一轮）', () async {
      build(seed: 11);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(4));

      final int before = repo.shuffleRemaining;
      repo.appendToQueue(<Track>[makeTrack('new1'), makeTrack('new2')]);
      expect(repo.shuffleRemaining, before + 2, reason: '新曲目应并入本轮计划');

      final Set<String> visited = <String>{playing()!};
      for (var i = 0; i < 5; i++) {
        await repo.next();
        await settle();
        visited.add(playing()!);
      }
      expect(visited.length, 6, reason: '一轮内应恰好覆盖 6 首（含新增）：$visited');
    });

    test('移除队列中的曲子后随机计划自动跳过它（不重复、不停住）', () async {
      build(seed: 13);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(5), startIndex: 4);

      expect(await repo.removeFromQueue(0), isTrue);
      expect(repo.queue.length, 4);

      final Set<String> visited = <String>{playing()!};
      for (var i = 0; i < 3; i++) {
        await repo.next();
        await settle();
        visited.add(playing()!);
      }
      expect(visited.length, 4, reason: '一轮应恰好覆盖剩余 4 首：$visited');
    });

    test('2 首队列：一轮就是这两首，来回不重复', () async {
      build(seed: 17);
      await repo.setMode(PlayMode.shuffle);
      await givenQueue(tracksOf(2));

      final List<String> visited = await walkOneRound(2);
      expect(visited.toSet().length, 2, reason: '两首都要播到：$visited');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 统一入口与偏好记忆
  // ══════════════════════════════════════════════════════════════════
  group('统一入口：媒体键 / 页面按钮落在同一份状态', () {
    test('媒体键与页面按钮叠加在同一索引上', () async {
      await givenQueue(tracksOf(4));

      await repo.next();
      await settle();
      final int afterManual = repo.currentIndex;

      await engine.mediaKeyNext();
      await settle();

      expect(repo.currentIndex, afterManual + 1);
      expect(engine.skipNextCalls, 1);
    });

    test('媒体键「上一首」同样走播放历史', () async {
      await givenQueue(tracksOf(4), startIndex: 2);

      await engine.mediaKeyPrevious();
      await settle();

      expect(repo.currentIndex, 1);
      expect(engine.skipPreviousCalls, 1);
    });

    test('模式偏好被持久化，重启后不会无提示变成顺序播放', () async {
      await repo.setMode(PlayMode.shuffle);
      expect(store.prefs['playMode'], 'shuffle');

      // 新仓储复用同一份存储 → 恢复后仍是随机。
      repo.dispose();
      repoDisposed = true;
      await engine.close();
      engineClosed = true;

      engine = FakePlaybackEngine();
      repo = PlaybackRepository(music: music, handler: engine, store: store);
      repoDisposed = false;
      engineClosed = false;

      await repo.restoreMode();
      expect(repo.mode, PlayMode.shuffle);
    });
  });
}
