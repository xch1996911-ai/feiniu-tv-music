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

/// 播放页**遥控器焦点链**的回归测试（对应 V4 验收「四、播放页布局改动」）。
///
/// ## 为什么必须写成 widget 测试
/// 「上一首 / 播放暂停 / 下一首 选不中」「进了进度区出不来」「打开队列后焦点丢了」
/// 这类故障全部发生在**焦点树**这一层，纯 Dart 单测（只测 `PlaybackRepository`）
/// 永远抓不到。这里真实构建 [PlayerPage]，用 `sendKeyEvent` 模拟遥控器
/// 方向键与 OK 键，再断言 `FocusManager.instance.primaryFocus.debugLabel` ——
/// 也就是「焦点此刻到底停在哪一个控件上」。
///
/// ## V4 的焦点拓扑（与屏幕上的左右顺序**完全一致**）
/// ```
/// [返回] ↔ [布局] ↔ [模式] ↔ [收藏] ↔ [上一首] ↔ [播放/暂停] ↔ [下一首] ↔ [队列]
///    ↖──────────────────────（队列按 → 环回「返回」）────────────────────┘
/// ```
/// 从「播放/暂停」出发，**按 → 依次**是：
/// `下一首 → 队列 → 返回 → 布局 → 模式 → 收藏 → 上一首 → 播放`（8 步一循环）。
/// 每个控件 `↓` → 进度区；进度区 `↑` → 播放/暂停、`↓` → 原地不动。
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

  /// 从「播放/暂停」往右走 [steps] 步。
  ///
  /// 调用方必须确认此刻焦点就在「播放/暂停」上 —— 每个测试体都从那里起跑。
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

  group('播放页底部操作栏焦点链', () {
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

    testWidgets('底部栏是一条 8 节点的显式闭环：→ 顺序 == 屏幕上的左右顺序',
        (WidgetTester tester) async {
      await ready(tester);

      // 从「播放/暂停」向→依次经过的 8 个控件（第 8 步回到起点）
      const List<String> forward = <String>[
        'player.next',
        'player.queue',
        'player.back',
        'player.layout',
        'player.mode',
        'player.fav',
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
        'player.fav',
        'player.mode',
        'player.layout',
        'player.back',
        'player.queue',
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

    testWidgets('底部栏 8 个控件 ↑ 都进进度区，↓ 都回播放/暂停',
        (WidgetTester tester) async {
      // ⚠️ V5 版式改动后，操作条被移到了**进度区下方**（需求：
      //    「正文 → 进度/队列状态区 → 最底部操作条」）。
      //    方向键必须跟着控件位置改：从操作条往上才是进度区。
      //    只挪控件不改方向键，遥控器在这个区域就会「走不出去」。
      await ready(tester);

      // (需要按几次 →, 期望落点) —— 从「播放/暂停」起跑
      const List<List<Object>> cases = <List<Object>>[
        <Object>[0, 'player.play'],
        <Object>[1, 'player.next'],
        <Object>[2, 'player.queue'],
        <Object>[3, 'player.back'],
        <Object>[4, 'player.layout'],
        <Object>[5, 'player.mode'],
        <Object>[6, 'player.fav'],
        <Object>[7, 'player.prev'],
      ];

      for (final List<Object> c in cases) {
        final int steps = c[0] as int;
        final String label = c[1] as String;
        await right(tester, steps);
        expect(focusedLabel(), label);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(focusedLabel(), 'player.seek', reason: '$label 向上应进进度区');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        expect(focusedLabel(), 'player.play',
            reason: '进度区向下必须优先回播放/暂停（不是回刚才那个控件）');

        // 循环结束焦点已在「播放/暂停」，下一次 right() 的起点正确
        expectAtPlay();
      }

      await tearDownTree(tester);
    });

    testWidgets('D 从播放/暂停 ↑ 进进度区，↓ 回播放/暂停；连续 10 次不卡死',
        (WidgetTester tester) async {
      await ready(tester);

      for (int i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(focusedLabel(), 'player.seek', reason: '第 ${i + 1} 次向上应进入进度区');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        expect(focusedLabel(), 'player.play',
            reason: '第 ${i + 1} 次向下应回到播放/暂停（优先回该按钮）');
      }

      await tearDownTree(tester);
    });

    testWidgets('歌词区不参与焦点链（方向键不会被歌词吃掉）',
        (WidgetTester tester) async {
      await ready(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.seek');

      // 进度区已经是**最上一层**（它上方只有不可聚焦的正文：封面 / 歌词）：
      // 再按 ↑ 必须是「待在原地」，不能把焦点丢进歌词区（歌词只读）或干脆弄丢。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.seek',
          reason: '进度区上方只有不可聚焦的正文，↑ 应原地不动而不是把焦点弄丢');

      // 而且随时能回去（↓ 就是操作条）
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expectAtPlay();

      await tearDownTree(tester);
    });

    testWidgets('「返回」按 ↑ 不会把焦点甩丢（顶部控件已全部下沉到底部栏）',
        (WidgetTester tester) async {
      await ready(tester);

      await left(tester, 5); // play ← prev ← fav ← mode ← layout ← back
      expect(focusedLabel(), 'player.back');

      // 操作条在进度区**下方** ⇒ 「返回」按 ↑ 应当进进度区（而不是甩丢）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.seek',
          reason: '操作条在进度区下方，「返回」按 ↑ 必须进进度区，不能把焦点甩丢');

      // 到底了：操作条按 ↓ 必须原地不动 —— 留空会让框架的空间搜索把焦点甩走。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.play');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'player.play',
          reason: '操作条是最底部，↓ 必须原地不动');

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

      // 关键：操作进度之后仍然能按 ↓ 出去（操作条就在进度区下方）
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expectAtPlay();

      await tearDownTree(tester);
    });
  });

  group('播放页布局切换（需求「四、3」）', () {
    testWidgets('OK 切换布局：模式改变、焦点不丢、偏好被持久化',
        (WidgetTester tester) async {
      await ready(tester);
      expect(local.playerLayout, PlayerLayout.stage, reason: '默认是标准布局');

      await left(tester, 4); // play ← prev ← fav ← mode ← layout
      expect(focusedLabel(), 'player.layout');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(local.playerLayout, PlayerLayout.cover,
          reason: '选中的模式必须立刻生效');
      expect(focusedLabel(), 'player.layout',
          reason: '切换布局后焦点不能丢（这是最容易退化的点）');
      expect(store.prefs['playerLayout'], 'cover',
          reason: '偏好必须真的落盘 —— 重新打开播放器要保留上次选择');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(local.playerLayout, PlayerLayout.stage, reason: '两个模式可来回切');
      expect(store.prefs['playerLayout'], 'stage');
      expect(focusedLabel(), 'player.layout');

      await tearDownTree(tester);
    });

    testWidgets('切换布局后进度区与播放控制仍然可达',
        (WidgetTester tester) async {
      await ready(tester);

      await left(tester, 4);
      expect(focusedLabel(), 'player.layout');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // 切到「大封面」
      await tester.pump();
      expect(local.playerLayout, PlayerLayout.cover);

      // 布局变了以后，↑ 仍然要进进度区、↓ 仍然要回播放/暂停
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'player.seek');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expectAtPlay();

      // 播放控制三个键也还在链上
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'player.prev');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'player.next');

      await tearDownTree(tester);
    });
  });

  group('播放队列面板（需求「四、4」）', () {
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
