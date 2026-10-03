import 'dart:async';

import 'package:feiniu_tv_music/core/result.dart';
import 'package:feiniu_tv_music/domain/lyric.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/playback/playback_control.dart';
import 'package:feiniu_tv_music/repositories/auth_repository.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/lyric_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_lyric_source.dart';
import 'support/fake_secure_store.dart';

/// 把逐行歌词包成 [LyricDoc]（`LyricDoc.parseLrc` 返回的是 `List<LyricLine>`）。
LyricDoc docOf(List<LyricLine> lines) => LyricDoc(lines: lines);

/// V2：歌词高亮 / 播放控制层契约 / 队列管理 的回归测试。
void main() {
  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late PlaybackRepository playback;
  late LibraryRepository library;

  Future<void> settle() async {
    await playback.pendingLoads;
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    music = FakeMusicRepository();
    engine = FakePlaybackEngine();
    playback = PlaybackRepository(music: music, handler: engine);
    library = LibraryRepository(music);
  });

  tearDown(() async {
    library.dispose();
    playback.dispose();
    await engine.close();
  });

  // ── 播放控制层（手机互联预留） ─────────────────────────────
  group('PlaybackControl 统一控制层', () {
    test('控制层暴露的状态与 Repository 一致（单一数据源）', () async {
      music.catalogue = [for (var i = 0; i < 5; i++) makeTrack('g$i')];
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 2);
      await settle();

      final s = playback.state;
      expect(s.currentIndex, 2);
      expect(s.currentSong?.guid, 'g2');
      expect(s.queue.length, 5);
      expect(s.hasSong, isTrue);
      // UI 读 state 就能拿到全部所需，不需要碰引擎
      expect(s.sourceLabel, '全部歌曲');
    });

    test('addToQueue 追加到末尾且不移动 currentIndex', () async {
      music.catalogue = [for (var i = 0; i < 3; i++) makeTrack('g$i')];
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 1);
      await settle();

      final len = await playback.addToQueue(makeTrack('extra'));
      expect(len, 4);
      expect(playback.currentIndex, 1, reason: '追加不能动当前曲');
    });

    test('addToQueue 相同 guid 不重复入队', () async {
      music.catalogue = [makeTrack('a'), makeTrack('b')];
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 0);
      await settle();

      await playback.addToQueue(makeTrack('a')); // 已存在
      expect(playback.queue.length, 2);
    });

    test('removeFromQueue 拒绝移除正在播放的曲目', () async {
      music.catalogue = [for (var i = 0; i < 3; i++) makeTrack('g$i')];
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 1);
      await settle();

      final ok = await playback.removeFromQueue(1);
      expect(ok, isFalse, reason: '正在播放的曲目不能移除，否则 index 会错位');
      expect(playback.queue.length, 3);
    });

    test('removeFromQueue 移除前面的元素时 index 同步前移', () async {
      music.catalogue = [for (var i = 0; i < 4; i++) makeTrack('g$i')];
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 2);
      await settle();
      expect(playback.current?.guid, 'g2');

      // 移除 index 0（当前曲之前的一个）
      final ok = await playback.removeFromQueue(0);
      expect(ok, isTrue);
      expect(playback.queue.length, 3);
      expect(playback.currentIndex, 1, reason: 'index 应同步前移，仍指向同一首');
      expect(playback.current?.guid, 'g2', reason: '当前播放的歌不能变');
    });

    test('removeFromQueue 移除越界索引返回 false', () async {
      music.catalogue = [makeTrack('a')];
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 0);
      await settle();
      expect(await playback.removeFromQueue(99), isFalse);
      expect(await playback.removeFromQueue(-1), isFalse);
    });

    test('状态流会发出新快照（供未来 WebSocket 推送）', () async {
      music.catalogue = [makeTrack('a'), makeTrack('b')];
      await library.loadFirst();
      playback.setQueue(library.tracks, startIndex: 0);
      await settle();

      final seen = <int>[];
      final sub = playback.states.listen((PlaybackSnapshot? s) => seen.add(s?.currentIndex ?? -1));
      addTearDown(sub.cancel);

      await playback.next();
      await settle();
      await Future<void>.delayed(Duration.zero);

      expect(seen, contains(1), reason: '切歌后应发出新状态快照');
    });
  });

  // ── 状态恢复（V2 §14）────────────────────────────────────
  group('APP 重启状态恢复', () {
    /// 用同一份 [FakeSecureStore] 造两个仓储实例，模拟「退出 APP → 重启」。
    ///
    /// 关键：必须走**真实的持久化往返**（写 → 另一个实例读），
    /// 而不是给两个实例塞同一个内存字段 —— 那样测不到 SecureStore 接线对不对。
    (PlaybackRepository, FakePlaybackEngine) reboot(FakeSecureStore store) {
      final e = FakePlaybackEngine();
      final p = PlaybackRepository(
        music: music,
        handler: e,
        store: store,
      );
      addTearDown(() async {
        p.dispose();
        await e.close();
      });
      return (p, e);
    }

    test('Z 保存当前曲目与进度后，新实例能读回并定位（不自动播放）', () async {
      music.catalogue = [for (var i = 0; i < 5; i++) makeTrack('g$i')];
      await library.loadFirst();

      final store = FakeSecureStore();
      // 第一次启动：放到第 2 首并产生进度
      final (p1, _) = reboot(store);
      p1.setQueue(library.tracks, startIndex: 2);
      await settle();
      await p1.saveRestorePoint();

      // 第二次启动：读回并定位
      final (p2, e2) = reboot(store);
      await p2.loadRestorePoint();
      final hit = p2.restoreToTrack(library.tracks);

      expect(hit, isTrue, reason: '应能定位到 g2');
      expect(p2.current?.guid, 'g2');
      expect(p2.currentIndex, 2);
      expect(
        e2.loads,
        isEmpty,
        reason: '⚠️ 恢复绝不能自动播放（否则电视开机突然放歌）',
      );
      expect(e2.isPlaying, isFalse, reason: '不应自动开始播放');
    });

    test('Z 恢复的曲库里已不存在该曲 → 返回 false，不崩溃', () async {
      music.catalogue = [makeTrack('a'), makeTrack('b')];
      await library.loadFirst();

      final store = FakeSecureStore();
      await store.writeLastTrackGuid('已删除的歌');
      await store.writeLastPositionMs(0);

      final (p2, _) = reboot(store);
      await p2.loadRestorePoint();

      expect(p2.restoreToTrack(library.tracks), isFalse);
      expect(p2.current, isNull);
    });

    test('Z 播放模式能跨实例恢复（持久化生效）', () async {
      final store = FakeSecureStore();
      final (p1, _) = reboot(store);
      await p1.setMode(PlayMode.repeatAll);

      final (p2, _) = reboot(store);
      await p2.restoreMode();
      expect(p2.mode, PlayMode.repeatAll, reason: '重启后应恢复上次播放模式');
    });

    test('没有上次记录时恢复不报错', () async {
      final (p2, _) = reboot(FakeSecureStore());
      await p2.loadRestorePoint();
      expect(p2.pendingRestoreGuid, isNull);
      expect(p2.restoreToTrack(const <Track>[]), isFalse);
    });
  });

  // ── 歌词 ────────────────────────────────────────────────
  group('歌词', () {
    late LyricRepository lyrics;

    setUp(() {
      lyrics = LyricRepository(FakeLyricSource.sample());
    });

    tearDown(() => lyrics.dispose());

    test('L 加载当前歌曲歌词并能定位高亮行', () async {
      final doc = docOf(LyricDoc.parseLrc(
        '[00:00.00]第一行\n[00:05.00]第二行\n[00:10.00]第三行',
      ));
      lyrics.applyForTest('g1', doc);

      expect(lyrics.doc.lines.length, 3);
      expect(lyrics.activeLineIndex(Duration.zero), 0);
      expect(lyrics.activeLineIndex(const Duration(seconds: 6)), 1);
      expect(lyrics.activeLineIndex(const Duration(seconds: 12)), 2);
    });

    test('L seek 后高亮行同步跳转', () async {
      lyrics.applyForTest('g1', docOf(const <LyricLine>[
        LyricLine(text: 'A', time: Duration.zero),
        LyricLine(text: 'B', time: Duration(seconds: 30)),
        LyricLine(text: 'C', time: Duration(minutes: 1)),
      ]));

      // 模拟 seek 到 1:05
      expect(lyrics.activeLineIndex(const Duration(minutes: 1, seconds: 5)), 2);
      // 回退到 0:10
      expect(lyrics.activeLineIndex(const Duration(seconds: 10)), 0);
    });

    test('N 换歌时旧歌词被清空（不残留上一首）', () async {
      lyrics.applyForTest('g1', docOf(const <LyricLine>[
        LyricLine(text: 'A', time: Duration.zero),
      ]));
      expect(lyrics.doc.isNotEmpty, isTrue);

      lyrics.clear();
      expect(lyrics.doc.isEmpty, isTrue);
      expect(lyrics.activeLineIndex(Duration.zero), -1);
    });

    test('O 无歌词时返回 -1，不抛异常', () {
      expect(lyrics.activeLineIndex(const Duration(seconds: 30)), -1);
      expect(lyrics.doc.isEmpty, isTrue);
    });

    test('M 同一行内高亮不变（不会每 500ms 抖一次）', () async {
      lyrics.applyForTest('g1', docOf(const <LyricLine>[
        LyricLine(text: '第一行', time: Duration.zero),
        LyricLine(text: '第二行', time: Duration(seconds: 30)),
      ]));
      // 同一行内不同时间点应得到同一行号
      expect(lyrics.activeLineIndex(const Duration(seconds: 1)),
          lyrics.activeLineIndex(const Duration(seconds: 2)));
    });

    test('歌词请求失败 → 显示暂无歌词但不影响播放', () async {
      final failing = LyricRepository(FakeLyricSource(fail: true));
      addTearDown(failing.dispose);

      await failing.load(makeTrack('g1'));
      // 失败后 doc 为空，UI 会显示「暂无歌词」；播放完全不受影响
      expect(failing.doc.isEmpty, isTrue);
      expect(failing.error, isNotNull);
    });

    test('P 歌词源直接抛异常时 load 不抛出（只标记暂无歌词）', () async {
      final repo = LyricRepository(_ThrowingLyricSource());
      addTearDown(repo.dispose);

      // 「不返回也不抛异常」和「抛异常」是两条路径，都必须兜住 ——
      // 构造/加载阶段漏出的异常在电视上的表现就是「黑屏」。
      await repo.load(makeTrack('g1'));

      expect(repo.doc.isEmpty, isTrue);
      expect(repo.error, isNotNull);
      expect(repo.isLoading, isFalse, reason: '必须在结束态，否则歌词区永远转圈');
    });

    test('P 歌词请求有硬超时（Dio 的 receiveTimeout 只约束包间隔）', () {
      // 服务端持续吐字节但永不结束时，Dio 的 receiveTimeout 不会触发，
      // 只能靠显式 timeout。这条约束一旦被删，表现为「极少数电视上歌词永远转圈」，
      // 属最难复现的故障，必须钉住。
      expect(LyricRepository.requestTimeout, const Duration(seconds: 12));
    });

    test('P 换歌加载时，请求发出前就已清空上一首歌词', () async {
      final gated = _GatedLyricSource();
      final repo = LyricRepository(gated);
      addTearDown(repo.dispose);

      repo.applyForTest('old', docOf(const <LyricLine>[
        LyricLine(text: '上一首的歌词', time: Duration.zero),
      ]));
      expect(repo.doc.isNotEmpty, isTrue);

      final pending = repo.load(makeTrack('new'));
      await Future<void>.delayed(Duration.zero);

      expect(gated.requestedGuids, <String>['new']);
      expect(repo.isLoading, isTrue);
      expect(
        repo.doc.isEmpty,
        isTrue,
        reason: '新歌词回来之前，界面绝不能继续显示上一首的歌词（真实故障：文不对题）',
      );
      expect(repo.loadedGuid, 'new');

      gated.complete('new', lrc: '[00:00.00]新歌词');
      await pending;
      expect(repo.doc.lines.single.text, '新歌词');
    });

    test('P 快速连续切歌：过期请求的结果被丢弃，不覆盖当前首', () async {
      final gated = _GatedLyricSource();
      final repo = LyricRepository(gated);
      addTearDown(repo.dispose);

      final f1 = repo.load(makeTrack('g1'));
      await Future<void>.delayed(Duration.zero);
      final f2 = repo.load(makeTrack('g2'));
      await Future<void>.delayed(Duration.zero);
      expect(gated.requestedGuids, <String>['g1', 'g2']);

      // 慢的那个先回来
      gated.complete('g1', lrc: '[00:00.00]g1 的歌词');
      await f1;
      expect(repo.doc.isEmpty, isTrue, reason: 'g1 已被 g2 取代，结果必须整份丢弃');
      expect(repo.loadedGuid, 'g2');

      gated.complete('g2', lrc: '[00:00.00]g2 的歌词');
      await f2;
      expect(repo.loadedGuid, 'g2');
      expect(repo.doc.lines.single.text, 'g2 的歌词');
    });

    test('P docEpoch 在内容被替换时自增（UI 靠它决定是否把歌词弹回顶部）', () async {
      final gated = _GatedLyricSource();
      final repo = LyricRepository(gated);
      addTearDown(repo.dispose);

      final before = repo.docEpoch;

      final pending = repo.load(makeTrack('g1'));
      await Future<void>.delayed(Duration.zero);
      final onStart = repo.docEpoch;
      expect(onStart, greaterThan(before), reason: '开始加载新歌就要换一次代号');

      gated.complete('g1', lrc: '[00:00.00]A\n[00:05.00]B');
      await pending;
      final onDone = repo.docEpoch;
      expect(onDone, greaterThan(onStart), reason: '加载完成又是一次内容替换');

      repo.clear();
      expect(repo.docEpoch, greaterThan(onDone), reason: '清空也算一次替换');
    });

    test('P 同一首切回来命中缓存，不再发第二次请求', () async {
      final src = FakeLyricSource.sample();
      final repo = LyricRepository(src);
      addTearDown(repo.dispose);

      await repo.load(makeTrack('g1'));
      await repo.load(makeTrack('g2'));
      await repo.load(makeTrack('g1')); // 切回来

      expect(
        src.requestedGuids,
        <String>['g1', 'g2'],
        reason: 'g1 第二次应命中缓存；来回切歌不该反复打服务端',
      );
      expect(repo.doc.lines.length, 3);
    });

    test('P force=true 时忽略缓存重新请求（用于手动重试）', () async {
      final src = FakeLyricSource.sample();
      final repo = LyricRepository(src);
      addTearDown(repo.dispose);

      await repo.load(makeTrack('g1'));
      await repo.load(makeTrack('g1'), force: true);
      expect(src.requestedGuids, <String>['g1', 'g1']);
    });
  });

  // ── 播放模式持久化（V2 §11）──────────────────────────────
  group('播放模式', () {
    test('T 模式可切换并写回状态快照', () async {
      for (final m in PlayMode.values) {
        await playback.setMode(m);
        expect(playback.mode, m);
        expect(playback.state.mode, m);
      }
    });

    test('PlayMode 持久化键稳定（不依赖 enum 顺序）', () {
      // 键必须显式稳定，将来调整枚举顺序不能让已存设置错位
      expect(PlayMode.sequence.storageKey, 'sequence');
      expect(PlayMode.repeatAll.storageKey, 'repeat_all');
      expect(PlayMode.repeatOne.storageKey, 'repeat_one');
      expect(PlayMode.shuffle.storageKey, 'shuffle');
    });

    test('未知持久化值降级为顺序播放（不抛异常）', () {
      expect(PlayModeX.fromStorage('不存在的值'), PlayMode.sequence);
      expect(PlayModeX.fromStorage(null), PlayMode.sequence);
    });
  });
}

/// 可控歌词源：`getLyrics` 返回一个**不会被自动完成**的 Future，
/// 由测试显式决定何时回包、以什么顺序回包。
///
/// 现有的 [FakeLyricSource] 会立刻返回，因此测不到「请求还在路上」时的
/// 两个关键分支：
/// ① 请求发出前是否已清空旧歌词（否则界面上是上一首的歌词）；
/// ② 慢的旧请求回来后会不会覆盖新歌（切歌太快时的经典竞态）。
class _GatedLyricSource extends MusicRepository {
  _GatedLyricSource() : super(AuthRepository());

  final Map<String, Completer<Result<LyricDoc>>> _gates =
      <String, Completer<Result<LyricDoc>>>{};

  final List<String> requestedGuids = <String>[];

  @override
  Future<Result<LyricDoc>> getLyrics(String trackGuid) {
    requestedGuids.add(trackGuid);
    final gate = Completer<Result<LyricDoc>>();
    _gates[trackGuid] = gate;
    return gate.future;
  }

  /// 手动回包（同一 guid 只回一次）。
  void complete(String guid, {String lrc = ''}) {
    _gates.remove(guid)!.complete(
          Result<LyricDoc>.ok(LyricDoc(lines: LyricDoc.parseLrc(lrc))),
        );
  }
}

/// 一调用就抛异常的歌词源（模拟传输层直接抛出，而不是返回 `Result.err`）。
class _ThrowingLyricSource extends MusicRepository {
  _ThrowingLyricSource() : super(AuthRepository());

  @override
  Future<Result<LyricDoc>> getLyrics(String trackGuid) async {
    throw StateError('模拟歌词接口在传输层直接抛异常');
  }
}
