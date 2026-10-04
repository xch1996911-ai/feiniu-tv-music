import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/player_layout.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/repositories/lyric_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/pages/player_page.dart';
import 'package:feiniu_tv_music/ui/widgets/queue_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_lyric_source.dart';
import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 播放页**遥控器焦点链**的回归测试（V6 融合版式）。
///
/// ## V6 的焦点拓扑（与屏幕位置**完全一致**，全部显式链接）
/// ```
///   横向A：back ↔ fav ↔ more                 （页面左列，两端不环回）
///   横向B：mode ↔ prev ↔ play ↔ next ↔ queue（底部控制行，两端环回）
///   纵向：back/fav/more ↓→ seek；seek ↓→ mode；控制键 ↑→ seek、↓→ 自身
///   seek：←/→ = 快退/快进 5 秒，OK = 播放/暂停，↑→ fav（大封面布局=原地）
/// ```
/// 进入播放页焦点直接落在「播放/暂停」。
/// 从「播放/暂停」出发 **按 → 依次**：
/// `下一首 → 队列 → 模式 → 上一首 → 播放`（5 步一循环）。
/// 「返回 / 收藏 / 更多」通过 `seek ↑ → fav` 进入。
///
/// ⚠️ 两条踩过的坑：
/// 1. **不要在 testWidgets 里 await `Future.delayed` / `pumpEventQueue()`**：
///    测试体跑在 FakeAsync 假时钟里，await 定时器会**死等到 10 分钟超时**。
/// 2. **结尾要 `pumpWidget(SizedBox())` 把树拆掉**：本页有 `Timer.periodic`
///    （进度刷新）与多个 `FocusNode`，不拆树会留下未取消的定时器。
void main() {
  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late PlaybackRepository playback;
  late LyricRepository lyrics;
  late LocalLibraryRepository local;
  late FakeSecureStore store;

  setUp(() {
    music = FakeMusicRepository();
    engine = FakePlaybackEngine();
    playback = PlaybackRepository(music: music, handler: engine);
    lyrics = LyricRepository(FakeLyricSource.sample());
    // ⚠️ 必须注入 FakeSecureStore：真实 SecureStore 会打到
    //    flutter_secure_storage 的平台通道上（测试环境没有插件）。
    store = FakeSecureStore();
    local = LocalLibraryRepository(store: store);
  });

  tearDown(() async {
    lyrics.dispose();
    playback.dispose();
    local.dispose();
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
          ChangeNotifierProvider<LocalLibraryRepository>.value(value: local),
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

  /// 准备 5 首歌并进到播放页（当前曲目下标 = 2）。
  ///
  /// ⚠️ **建立队列这一步必须放进 [WidgetTester.runAsync]。**
  /// （root Zone 微任务问题，详见 tv_focus_test 历史版本注释 ——
  /// `PlaybackRepository` 的加载链挂在构造期的 `Future.value()` 上，
  /// FakeAsync 清不到；`runAsync` 放回真实事件循环。）
  Future<void> ready(WidgetTester tester) async {
    music.catalogue = <Track>[for (int i = 0; i < 5; i++) makeTrack('g$i')];
    await tester.runAsync(() async {
      playback.setQueue(music.catalogue, startIndex: 2);
      await playback.pendingLoads;
    });
    await pumpPlayer(tester);
  }

  /// 从「播放/暂停」往右走 [steps] 步。
  Future<void> right(WidgetTester tester, int steps) async {
    for (int i = 0; i < steps; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
  }

  /// 从「播放/暂停」往左走 [steps] 步。
  Future<void> left(WidgetTester tester, int steps) async {
    for (int i = 0; i < steps; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    }
  }

  /// 当前焦点必须落在「播放/暂停」上（每个用例的起跑位置）。
  void expectAtPlay() => expect(focusedLabel(), 'player.play');

  group('播放页焦点链（V6 融合版式）', () {
    testWidgets('打开播放页后焦点直接落在「播放/暂停」上', (WidgetTester tester) async {
      await ready(tester);
      expectAtPlay();
      await tearDownTree(tester);
    });

    testWidgets('播放/暂停 ←→ 上一首 / 下一首；左键原路返回',
        (WidgetTester tester) async {
      await ready(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.prev', reason: '播放/暂停 ← 应到上一首');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expectAtPlay();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.next', reason: '播放/暂停 → 应到下一首');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expectAtPlay();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.prev');

      await tearDownTree(tester);
    });

    testWidgets('底部控制行是 5 节点显式环：→ 顺序 == 屏幕上的左右顺序',
        (WidgetTester tester) async {
      await ready(tester);

      // 从「播放/暂停」向→依次经过的 5 个控件（第 5 步回到起点）
      const List<String> forward = <String>[
        'player.next',
        'player.queue',
        'player.mode', // queue 右端环回 mode
        'player.prev',
        'player.play',
      ];
      for (int i = 0; i < forward.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        expect(focusedLabel(), forward[i],
            reason: '第 ${i + 1} 次 → 应该到 ${forward[i]}'
                '（逻辑顺序必须等于视觉顺序，否则用户会觉得焦点乱跳）');
      }

      // 反向也必须是同一环
      const List<String> backward = <String>[
        'player.prev',
        'player.mode',
        'player.queue', // mode 左端环回 queue
        'player.next',
        'player.play',
      ];
      for (int i = 0; i < backward.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        expect(focusedLabel(), backward[i],
            reason: '第 ${i + 1} 次 ← 应该到 ${backward[i]}');
      }

      await tearDownTree(tester);
    });

    testWidgets('底部 5 键 ↑ 都进进度区，↓ 回到控制行最左（模式键）',
        (WidgetTester tester) async {
      await ready(tester);

      // (需要按几次 →, 期望落点) —— 从「播放/暂停」起跑
      const List<List<Object>> cases = <List<Object>>[
        <Object>[0, 'player.play'],
        <Object>[1, 'player.next'],
        <Object>[2, 'player.queue'],
        <Object>[3, 'player.mode'],
        <Object>[4, 'player.prev'],
      ];

      for (final List<Object> c in cases) {
        final int steps = c[0] as int;
        final String label = c[1] as String;
        await right(tester, steps);
        expect(focusedLabel(), label);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(focusedLabel(), 'player.seek', reason: '$label 向上应进进度区');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        expect(focusedLabel(), 'player.mode',
            reason: '进度区向下应到控制行最左（视觉一致），不能把焦点甩丢');

        // 循环结束焦点在「模式」，往右走回「播放/暂停」重置起点
        await right(tester, 2);
        expectAtPlay();
      }

      await tearDownTree(tester);
    });

    testWidgets('D 播放/暂停 ↑ 进进度区、↓ 回控制行；连续 10 次不卡死',
        (WidgetTester tester) async {
      await ready(tester);

      for (int i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(focusedLabel(), 'player.seek', reason: '第 ${i + 1} 次向上应进入进度区');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        expect(focusedLabel(), 'player.mode',
            reason: '第 ${i + 1} 次向下应回控制行');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        expectAtPlay();
      }

      await tearDownTree(tester);
    });

    testWidgets('进度区 ↑ 到收藏键，收藏 ↔ 返回/更多；歌词区绝不获焦',
        (WidgetTester tester) async {
      await ready(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.seek');

      // 进度区再 ↑ → 信息行的收藏键（正上方）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.fav');

      // 收藏 ↑ 已经是信息行（上方只有封面，不可聚焦）→ 原地不动，
      // 不能把焦点甩进歌词区或弄丢。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.fav',
          reason: '收藏上方只有不可聚焦的封面，↑ 应原地不动');

      // 收藏 ←→ 返回（左上角）；收藏 → 更多。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.back');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.fav');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.more');

      // 返回键 ↓ 同样进进度区（纵向链）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.fav');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.back');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.seek');

      // 随时能回控制区。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.mode');

      await tearDownTree(tester);
    });
  });

  group('核心播放控制按钮可激活', () {
    testWidgets('OK 激活播放/暂停，且焦点留在原按钮上',
        (WidgetTester tester) async {
      await ready(tester);
      expect(engine.playing, isTrue, reason: 'setQueue 后应在播放');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(engine.pauseCalls, 1, reason: 'OK 应触发暂停');
      expectAtPlay(); // 暂停后焦点不能跳走

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(engine.playCalls, 1, reason: '再按 OK 应恢复播放');
      expectAtPlay();

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

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
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

      // 关键：操作进度之后仍然能按 ↓ 出去。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.mode');

      await tearDownTree(tester);
    });
  });

  group('「更多」菜单（布局切换 / 歌词操作）', () {
    /// 走到「更多」按钮：播放/暂停 →↑ seek →↑ fav →→ more。
    Future<void> gotoMore(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.seek');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.fav');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.more');
    }

    testWidgets('OK 打开菜单：出现布局/歌词项，焦点落在第一项',
        (WidgetTester tester) async {
      await ready(tester);
      await gotoMore(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(find.text('切换布局（当前：标准）'), findsOneWidget);
      expect(find.text('重新加载歌词'), findsOneWidget);
      expect(focusedLabel(), 'more.layout',
          reason: '菜单打开后焦点必须落在第一项（autofocus 不可靠，显式请求）');

      await tearDownTree(tester);
    });

    testWidgets('OK 切换布局：模式改变、菜单关闭、焦点回到「更多」、偏好落盘',
        (WidgetTester tester) async {
      await ready(tester);
      expect(local.playerLayout, PlayerLayout.stage,
          reason: '默认是标准（融合）布局');

      await gotoMore(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(local.playerLayout, PlayerLayout.cover,
          reason: '选中的布局必须立刻生效');
      expect(find.text('切换布局（当前：大封面）'), findsNothing,
          reason: '菜单应已关闭');
      expect(focusedLabel(), 'player.more',
          reason: '菜单关闭后焦点必须回到「更多」按钮');
      expect(store.prefs['playerLayout'], 'cover',
          reason: '偏好必须真的落盘 —— 重新打开播放器要保留上次选择');

      // 再切一次回到 stage。
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(local.playerLayout, PlayerLayout.stage, reason: '两个模式可来回切');
      expect(store.prefs['playerLayout'], 'stage');
      expect(focusedLabel(), 'player.more');

      await tearDownTree(tester);
    });

    testWidgets('切换到「大封面」布局后，进度区与播放控制仍然可达',
        (WidgetTester tester) async {
      await ready(tester);

      await gotoMore(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(local.playerLayout, PlayerLayout.cover);

      // 大封面布局：↓ 进进度区（「更多」上方无信息行，↑ 原地不动），
      // 再 ↓ 回控制行。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.seek');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.mode');

      // 播放控制三个键也还在链上。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.play');

      await tearDownTree(tester);
    });
  });

  group('播放队列面板', () {
    /// 走到「队列」按钮：播放/暂停 →(→) 下一首 →(→) 队列。
    Future<void> gotoQueue(WidgetTester tester) async {
      await right(tester, 2);
      expect(focusedLabel(), 'player.queue');
    }

    testWidgets('OK 打开队列：显示当前队列，焦点落在正在播放的那一行',
        (WidgetTester tester) async {
      await ready(tester);
      await gotoQueue(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(find.byType(QueueSheet), findsOneWidget);
      expect(find.text('播放队列'), findsOneWidget);
      expect(focusedLabel(), 'queue.2',
          reason: '打开队列时焦点应落在当前播放行（currentIndex=2），'
              '用户一睁眼就知道自己在队列的哪儿');

      await tearDownTree(tester);
    });

    testWidgets('队列里 ↓ 选择下一首，OK 播放它并关闭；焦点回到队列按钮',
        (WidgetTester tester) async {
      await ready(tester);
      await gotoQueue(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(focusedLabel(), 'queue.2');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'queue.3', reason: '队列里可以遥控器上下选歌');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      // 第一帧：_playAt 的 await 恢复 → onClose()
      await tester.pump();
      // 第二帧：postFrameCallback 把焦点还给队列按钮
      await tester.pump();

      expect(find.byType(QueueSheet), findsNothing, reason: 'OK 之后面板应关闭');
      expect(playback.currentIndex, 3, reason: 'OK 应播放所选那一首');
      expect(focusedLabel(), 'player.queue',
          reason: '返回后焦点必须回到打开队列的那个按钮上，不能丢');

      await tearDownTree(tester);
    });

    testWidgets('队列面板打开时，底下的播放页被排除出焦点树',
        (WidgetTester tester) async {
      await ready(tester);
      await gotoQueue(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      // 面板里再按 ↓↑ 只在队列行之间走，不会跑到被遮住的播放控制上
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'queue.3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'queue.2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'queue.1');
      expect((focusedLabel() ?? '').startsWith('queue.'), isTrue,
          reason: '焦点必须一直待在面板内');

      await tearDownTree(tester);
    });
  });
}
