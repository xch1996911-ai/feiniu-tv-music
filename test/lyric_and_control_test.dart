import 'package:feiniu_tv_music/domain/lyric.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/playback/playback_control.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/lyric_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_lyric_source.dart';

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
    test('Y 恢复只定位不自动播放（电视开机不该突然放歌）', () async {
      music.catalogue = [for (var i = 0; i < 5; i++) makeTrack('g$i')];
      await library.loadFirst();

      // 模拟「上次播放到 g2」
      playback.restoreToTrackForTest('g2', const Duration(seconds: 42));

      // 新的仓储实例模拟重启后恢复
      final engine2 = FakePlaybackEngine();
      final playback2 = PlaybackRepository(music: music, handler: engine2);
      addTearDown(() async {
        playback2.dispose();
        await engine2.close();
      });

      await playback2.loadRestorePoint();
      final hit = playback2.restoreToTrack(library.tracks);

      expect(hit, isTrue, reason: '应能定位到 g2');
      expect(playback2.current?.guid, 'g2');
      expect(playback2.currentIndex, 2);
      expect(
        engine2.loads,
        isEmpty,
        reason: '⚠️ 恢复绝不能自动播放（否则电视开机突然放歌）',
      );
      expect(engine2.isPlaying, isFalse);
    });

    test('Z 恢复的曲库里已不存在该曲 → 返回 false，不崩溃', () async {
      music.catalogue = [makeTrack('a'), makeTrack('b')];
      await library.loadFirst();

      final engine2 = FakePlaybackEngine();
      final playback2 = PlaybackRepository(music: music, handler: engine2);
      addTearDown(() async {
        playback2.dispose();
        await engine2.close();
      });

      playback.restoreToTrackForTest('已删除的歌', Duration.zero);
      await playback2.loadRestorePoint();

      expect(playback2.restoreToTrack(library.tracks), isFalse);
      expect(playback2.current, isNull);
    });

    test('没有上次记录时恢复不报错', () async {
      final engine2 = FakePlaybackEngine();
      final playback2 = PlaybackRepository(music: music, handler: engine2);
      addTearDown(() async {
        playback2.dispose();
        await engine2.close();
      });

      await playback2.loadRestorePoint();
      expect(playback2.restoreToTrack(const <Track>[]), isFalse);
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
