import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/lyric_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/pages/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_lyric_source.dart';
import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';

/// 播放页**遥控器焦点链**的回归测试（对应验收 C / D）。
///
/// ## 为什么必须写成 widget 测试
/// 「上一首 / 播放暂停 / 下一首 选不中」「进了进度区出不来」这类故障
/// 全部发生在**焦点树**这一层，纯 Dart 单测（只测 `PlaybackRepository`）
/// 永远抓不到。这里真实构建 [PlayerPage]，用 `sendKeyEvent` 模拟遥控器
/// 方向键与 OK 键，再断言 `FocusManager.instance.primaryFocus.debugLabel` ——
/// 也就是「焦点此刻到底停在哪一个控件上」。
///
/// ⚠️ 两条踩过的坑：
/// 1. **不要在 testWidgets 里 await `Future.delayed` / `pumpEventQueue()`**：
///    测试体跑在 FakeAsync 假时钟里，假时钟只由 `pump()` 推进，
///    await 定时器会**死等到 10 分钟超时**（不是快速失败），
///    足以让整条 CI 在产出任何 APK 之前被判死。
/// 2. **结尾要 `pumpWidget(SizedBox())` 把树拆掉**：本页有 `Timer.periodic`
///    （进度刷新）与多个 `FocusNode`，不拆树会留下未取消的定时器。
void main() {
  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late PlaybackRepository playback;
  late LyricRepository lyrics;

  setUp(() {
    music = FakeMusicRepository();
    engine = FakePlaybackEngine();
    playback = PlaybackRepository(music: music, handler: engine);
    lyrics = LyricRepository(FakeLyricSource.sample());
  });

  tearDown(() async {
    lyrics.dispose();
    playback.dispose();
    await engine.close();
  });

  /// 焦点此刻停在哪 —— 用 `FocusNode.debugLabel` 指认控件。
  String? focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  /// 构建播放页并让「初始焦点落在播放/暂停上」这一步真正生效。
  Future<void> pumpPlayer(WidgetTester tester) async {
    // 电视是 1920×1080；默认 800×600 的测试画布会把横版布局挤到溢出。
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
          ChangeNotifierProvider<LyricRepository>.value(value: lyrics),
          ChangeNotifierProvider<MusicRepository>.value(value: music),
        ],
        child: MaterialApp(
          theme: buildTvTheme(),
          home: Scaffold(
            body: PlayerPage(onBack: () {}),
          ),
        ),
      ),
    );
    // 第 1 帧建树 → postFrameCallback 请求焦点 → 焦点变更在下一帧生效。
    await tester.pump();
    await tester.pump();
  }

  Future<void> tearDownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// 准备 5 首歌并进到播放页。
  ///
  /// ⚠️ **建立队列这一步必须放进 [WidgetTester.runAsync]。**
  ///
  /// `PlaybackRepository` 的加载串行链挂在**构造期创建**的
  /// `Future<void>.value()` 上，而构造发生在 `setUp`（root Zone）。
  /// `_Future._addListener` 用 `this._zone` 调度微任务，因此 `.then` 的回调
  /// 被丢进 **root Zone 的微任务队列**；而 `testWidgets` 跑在 FakeAsync 里，
  /// `pump()` 的 `flushMicrotasks()` **只清 FakeAsync 自己的队列**，
  /// 碰不到 root Zone 的微任务。
  ///
  /// 结果：引擎永远收不到加载请求，`engine.playing` 恒为 false ——
  /// 真机上完全没有这个问题（那里只有一个真实的微任务队列）。
  /// `runAsync` 会把回调放回真实事件循环，从而正确复现运行时行为。
  Future<void> ready(WidgetTester tester) async {
    music.catalogue = <Track>[for (int i = 0; i < 5; i++) makeTrack('g$i')];
    await tester.runAsync(() async {
      playback.setQueue(music.catalogue, startIndex: 2);
      await playback.pendingLoads;
    });
    await pumpPlayer(tester);
  }

  group('播放页三层焦点链', () {
    testWidgets('打开播放页后焦点直接落在「播放/暂停」上', (WidgetTester tester) async {
      await ready(tester);
      expect(focusedLabel(), 'player.play');
      await tearDownTree(tester);
    });

    testWidgets('C 上一首 →右→ 播放/暂停 →右→ 下一首；左键原路返回',
        (WidgetTester tester) async {
      await ready(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.prev', reason: '播放/暂停 ← 应到上一首');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.play');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.next', reason: '播放/暂停 → 应到下一首');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.play');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.prev');

      await tearDownTree(tester);
    });

    testWidgets('三层之间上下贯通：顶部 ↔ 控制区 ↔ 进度区', (WidgetTester tester) async {
      await ready(tester);

      // 控制区 ↑ → 顶部功能区
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.back');

      // 顶部 ↓ → 控制区（左侧回上一首，右侧回下一首）
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.prev');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.back');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.mode', reason: '顶部内部应能左右移动');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.next');

      await tearDownTree(tester);
    });

    testWidgets('D 从播放/暂停 ↓ 进进度区，↑ 回播放/暂停；连续 10 次不卡死',
        (WidgetTester tester) async {
      await ready(tester);

      for (int i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        expect(focusedLabel(), 'player.seek', reason: '第 ${i + 1} 次向下应进入进度区');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(focusedLabel(), 'player.play',
            reason: '第 ${i + 1} 次向上应回到播放/暂停（优先回该按钮）');
      }

      await tearDownTree(tester);
    });

    testWidgets('从三个控制键向下都能进进度区，向上都能回控制区',
        (WidgetTester tester) async {
      await ready(tester);

      for (final String start in <String>['player.prev', 'player.play', 'player.next']) {
        // 先走到起点
        if (start == 'player.prev') {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        } else if (start == 'player.next') {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        }
        expect(focusedLabel(), start);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        expect(focusedLabel(), 'player.seek', reason: '$start 向下应进进度区');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(focusedLabel(), 'player.play', reason: '进度区向上优先回播放/暂停');

        // 复位到播放/暂停
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        expect(focusedLabel(), 'player.prev');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        expect(focusedLabel(), 'player.play');
      }

      await tearDownTree(tester);
    });

    testWidgets('歌词区不参与焦点链（方向键不会被歌词吃掉）',
        (WidgetTester tester) async {
      await ready(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.seek');

      // 进度区已经是最下一层：再按 ↓ 必须是「待在原地」，
      // 不能把焦点丢进歌词区（歌词只读）或干脆弄丢。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.seek',
          reason: '进度区是最下层，↓ 应原地不动而不是把焦点弄丢');

      // 而且随时能回去
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.play');

      await tearDownTree(tester);
    });
  });

  group('核心播放控制按钮可激活（验收 C）', () {
    testWidgets('OK 激活播放/暂停，且焦点留在原按钮上',
        (WidgetTester tester) async {
      await ready(tester);
      expect(engine.playing, isTrue, reason: 'setQueue 后应在播放');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(engine.pauseCalls, 1, reason: 'OK 应触发暂停');
      expect(focusedLabel(), 'player.play', reason: '暂停后焦点不能跳走');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(engine.playCalls, 1, reason: '再按 OK 应恢复播放');
      expect(focusedLabel(), 'player.play');

      await tearDownTree(tester);
    });

    testWidgets('OK 激活上一首 / 下一首，焦点不跳走',
        (WidgetTester tester) async {
      await ready(tester);
      expect(playback.currentIndex, 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.prev');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(playback.currentIndex, 1, reason: 'OK 应切到上一首');
      expect(focusedLabel(), 'player.prev', reason: '切歌后焦点不能莫名跳走');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.next');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(playback.currentIndex, 2, reason: 'OK 应切到下一首');
      expect(focusedLabel(), 'player.next');

      await tearDownTree(tester);
    });

    testWidgets('进度区左右键 = 快退/快进 5 秒（不是移动焦点）',
        (WidgetTester tester) async {
      await ready(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.seek');

      // 让播放位置前进到 40 秒
      engine.setPosition(const Duration(seconds: 40));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(engine.seeks.last, const Duration(seconds: 45),
          reason: '→ 应快进 5 秒');
      expect(focusedLabel(), 'player.seek', reason: '进度区左右键不移动焦点');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(engine.seeks.last, const Duration(seconds: 40),
          reason: '← 应快退 5 秒');

      // 关键：操作进度之后仍然能按 ↑ 出去
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.play');

      await tearDownTree(tester);
    });
  });
}
